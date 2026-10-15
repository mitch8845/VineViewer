import 'dart:convert';
import 'dart:io' show ZLibDecoder;
import 'dart:typed_data';

/// A spreadsheet reduced to what an import needs: a header row and cells.
///
/// Every cell is text or null. Numbers arrive as their shortest decimal form
/// (`667`, not `667.0`), because the fields they are headed for store text and
/// validate it themselves -- a clone called 667 and a rating of 4 both start
/// life as strings either way.
class TableData {
  const TableData({required this.headers, required this.rows});

  final List<String> headers;
  final List<List<String?>> rows;

  /// The cell under [column] in [row], or null when the row is short.
  String? cell(List<String?> row, int column) =>
      column < row.length ? row[column] : null;
}

class TableReadException implements Exception {
  const TableReadException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Reads the first sheet of an `.xlsx`, or a CSV.
///
/// Hand-rolled rather than a package, deliberately: plugins have broken this
/// app's Android build twice, and an `.xlsx` is only a zip of XML. Unzipping
/// uses `dart:io`'s inflater; the two XML parts that matter -- shared strings
/// and the sheet -- are flat enough to read without a parser. Formulas are
/// read as their cached values, which is what Excel saves alongside them.
abstract final class TableReader {
  static TableData read(Uint8List bytes) {
    if (bytes.length >= 4 &&
        bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        bytes[2] == 0x03 &&
        bytes[3] == 0x04) {
      return _xlsx(bytes);
    }
    if (bytes.length >= 8 && bytes[0] == 0xD0 && bytes[1] == 0xCF) {
      throw const TableReadException(
        'That is an old-style .xls file. Save it as .xlsx or .csv and try '
        'again.',
      );
    }
    return _csv(utf8.decode(bytes, allowMalformed: true));
  }

  // ------------------------------------------------------------------ xlsx

  static TableData _xlsx(Uint8List bytes) {
    final zip = _unzip(bytes);

    final shared = <String>[];
    final sst = zip['xl/sharedStrings.xml'];
    if (sst != null) {
      for (final si in RegExp(
        r'<si\b[^>]*>(.*?)</si>',
        dotAll: true,
      ).allMatches(sst)) {
        shared.add(_runs(si.group(1)!));
      }
    }

    final sheetPath = _firstSheetPath(zip);
    final sheet = zip[sheetPath];
    if (sheet == null) {
      throw const TableReadException('The workbook has no sheets.');
    }

    final cells = <int, Map<int, String>>{};
    var maxColumn = -1;
    var maxRow = -1;
    var nextRow = 0;
    for (final row in RegExp(
      r'<row\b([^>]*?)(?:/>|>(.*?)</row>)',
      dotAll: true,
    ).allMatches(sheet)) {
      final rowRef = _attr(row.group(1)!, 'r');
      final rowIndex = rowRef == null ? nextRow : int.parse(rowRef) - 1;
      nextRow = rowIndex + 1;
      var nextColumn = 0;
      for (final c in RegExp(
        r'<c\b([^>]*?)(?:/>|>(.*?)</c>)',
        dotAll: true,
      ).allMatches(row.group(2) ?? '')) {
        final attrs = c.group(1)!;
        final ref = _attr(attrs, 'r');
        final column = ref == null ? nextColumn : _columnOf(ref);
        nextColumn = column + 1;
        final value = _cellValue(attrs, c.group(2) ?? '', shared);
        if (value == null) continue;
        (cells[rowIndex] ??= {})[column] = value;
        if (column > maxColumn) maxColumn = column;
        if (rowIndex > maxRow) maxRow = rowIndex;
      }
    }

    final grid = [
      for (var r = 0; r <= maxRow; r++)
        [for (var c = 0; c <= maxColumn; c++) cells[r]?[c]],
    ];
    return _fromGrid(grid);
  }

  /// The path of the workbook's first sheet, by its order in the workbook --
  /// not `sheet1.xml`, which is only the first sheet until someone reorders.
  static String _firstSheetPath(Map<String, String> zip) {
    const fallback = 'xl/worksheets/sheet1.xml';
    final workbook = zip['xl/workbook.xml'];
    final rels = zip['xl/_rels/workbook.xml.rels'];
    if (workbook == null || rels == null) return fallback;

    final first = RegExp(r'<sheet\b([^>]*)/?>').firstMatch(workbook);
    final id = first == null ? null : _attr(first.group(1)!, 'r:id');
    if (id == null) return fallback;

    for (final rel in RegExp(r'<Relationship\b([^>]*)/?>').allMatches(rels)) {
      final attrs = rel.group(1)!;
      if (_attr(attrs, 'Id') != id) continue;
      final target = _attr(attrs, 'Target');
      if (target == null) return fallback;
      return target.startsWith('/')
          ? target.substring(1)
          : 'xl/${target.replaceFirst(RegExp(r'^\./'), '')}';
    }
    return fallback;
  }

  static String? _cellValue(String attrs, String body, List<String> shared) {
    final type = _attr(attrs, 't') ?? 'n';
    if (type == 'inlineStr') {
      final inline = RegExp(r'<is>(.*?)</is>', dotAll: true).firstMatch(body);
      return inline == null ? null : _blankToNull(_runs(inline.group(1)!));
    }
    final v = RegExp(r'<v>(.*?)</v>', dotAll: true).firstMatch(body)?.group(1);
    if (v == null) return null;
    switch (type) {
      case 's':
        final i = int.tryParse(v);
        return i == null || i >= shared.length ? null : _blankToNull(shared[i]);
      case 'b':
        return v == '1' ? 'TRUE' : 'FALSE';
      case 'str':
      case 'e':
        return _blankToNull(_unescape(v));
      default:
        return _number(v);
    }
  }

  /// `667.0` -> `667`, `4` -> `4`, `2.5` -> `2.5`.
  static String _number(String raw) {
    final n = num.tryParse(raw.trim());
    if (n == null) return raw.trim();
    if (n is int) return '$n';
    final d = n.toDouble();
    if (d == d.roundToDouble() && d.abs() < 1e15) return '${d.toInt()}';
    return '$d';
  }

  /// All the text runs in a shared or inline string, joined. Rich text splits
  /// one cell into several runs, each in its own `<t>`.
  static String _runs(String xml) => [
    for (final t in RegExp(
      r'<t\b[^>]*>(.*?)</t>',
      dotAll: true,
    ).allMatches(xml))
      _unescape(t.group(1)!),
  ].join();

  static String? _attr(String attrs, String name) {
    final m = RegExp(
      '(?:^|\\s)${RegExp.escape(name)}="([^"]*)"',
    ).firstMatch(attrs);
    return m == null ? null : _unescape(m.group(1)!);
  }

  /// "AB12" -> 27 (zero-based).
  static int _columnOf(String ref) {
    var n = 0;
    for (final unit in ref.codeUnits) {
      if (unit < 0x41 || unit > 0x5A) break;
      n = n * 26 + (unit - 0x40);
    }
    return n - 1;
  }

  static String _unescape(String s) => s
      .replaceAllMapped(
        RegExp(r'&#x([0-9a-fA-F]+);'),
        (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
      )
      .replaceAllMapped(
        RegExp(r'&#(\d+);'),
        (m) => String.fromCharCode(int.parse(m.group(1)!)),
      )
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');

  // ------------------------------------------------------------------- zip

  /// The text entries of a zip archive, by path.
  ///
  /// Reads the central directory rather than walking local headers: Excel
  /// writes sizes only into the central directory for streamed entries, so a
  /// local-header walk would not know where each one ends.
  static Map<String, String> _unzip(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    var end = -1;
    for (var i = bytes.length - 22; i >= 0 && i >= bytes.length - 65557; i--) {
      if (data.getUint32(i, Endian.little) == 0x06054b50) {
        end = i;
        break;
      }
    }
    if (end < 0) {
      throw const TableReadException(
        'That file looks like a spreadsheet but could not be opened. Is it '
        'complete?',
      );
    }

    final count = data.getUint16(end + 10, Endian.little);
    var at = data.getUint32(end + 16, Endian.little);
    final out = <String, String>{};
    for (var i = 0; i < count; i++) {
      if (data.getUint32(at, Endian.little) != 0x02014b50) break;
      final method = data.getUint16(at + 10, Endian.little);
      final size = data.getUint32(at + 20, Endian.little);
      final nameLength = data.getUint16(at + 28, Endian.little);
      final extraLength = data.getUint16(at + 30, Endian.little);
      final commentLength = data.getUint16(at + 32, Endian.little);
      final local = data.getUint32(at + 42, Endian.little);
      final name = utf8.decode(bytes.sublist(at + 46, at + 46 + nameLength));
      at += 46 + nameLength + extraLength + commentLength;

      if (!name.endsWith('.xml') && !name.endsWith('.rels')) continue;
      final start =
          local +
          30 +
          data.getUint16(local + 26, Endian.little) +
          data.getUint16(local + 28, Endian.little);
      final raw = bytes.sublist(start, start + size);
      final List<int> inflated = switch (method) {
        0 => raw,
        8 => ZLibDecoder(raw: true).convert(raw),
        _ => throw TableReadException(
          'The spreadsheet uses a compression this app cannot read '
          '(method $method).',
        ),
      };
      out[name] = utf8.decode(inflated, allowMalformed: true);
    }
    return out;
  }

  // ------------------------------------------------------------------- csv

  /// RFC 4180 CSV, with the delimiter sniffed from the header line -- a
  /// European Excel saves with semicolons.
  static TableData _csv(String text) {
    if (text.startsWith('﻿')) text = text.substring(1);
    final firstLine = text.split('\n').first;
    final delimiter = [',', ';', '\t'].reduce(
      (a, b) => firstLine.split(b).length > firstLine.split(a).length ? b : a,
    );

    final rows = <List<String?>>[];
    var row = <String?>[];
    final field = StringBuffer();
    var quoted = false;
    var fieldWasQuoted = false;

    void endField() {
      final value = fieldWasQuoted ? '$field' : '$field'.trim();
      row.add(value.isEmpty ? null : value);
      field.clear();
      fieldWasQuoted = false;
    }

    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (quoted) {
        if (ch == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            quoted = false;
          }
        } else {
          field.write(ch);
        }
      } else if (ch == '"') {
        quoted = true;
        fieldWasQuoted = true;
      } else if (ch == delimiter) {
        endField();
      } else if (ch == '\n' || ch == '\r') {
        if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
        endField();
        rows.add(row);
        row = <String?>[];
      } else {
        field.write(ch);
      }
    }
    if (field.isNotEmpty || row.isNotEmpty) {
      endField();
      rows.add(row);
    }
    return _fromGrid(rows);
  }

  // ---------------------------------------------------------------- common

  static TableData _fromGrid(List<List<String?>> grid) {
    final nonEmpty = [
      for (final r in grid)
        if (r.any((c) => c != null)) r,
    ];
    if (nonEmpty.isEmpty) {
      throw const TableReadException('The sheet is empty.');
    }
    final headers = [for (final h in nonEmpty.first) (h ?? '').trim()];
    return TableData(headers: headers, rows: nonEmpty.sublist(1));
  }

  static String? _blankToNull(String s) => s.trim().isEmpty ? null : s;
}
