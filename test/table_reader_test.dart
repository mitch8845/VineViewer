import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/import/table_reader.dart';

Uint8List _csv(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  group('xlsx', () {
    late TableData table;
    setUpAll(() {
      table = TableReader.read(
        File('test/fixtures/import_sample.xlsx').readAsBytesSync(),
      );
    });

    test('reads the header row and every data row of the first sheet', () {
      expect(table.headers, [
        'Block',
        'Row',
        'Plant',
        'ID',
        'Variety',
        'Clone',
        'Health',
        'Notes',
      ]);
      expect(table.rows, hasLength(3));
    });

    test('numbers come out in their shortest form', () {
      // Excel stores 667 as a number; the Clone option is the text "667".
      expect(table.rows[0][5], '667');
      expect(table.rows[0][6], '4');
      expect(table.rows[2][6], '2.5');
    });

    test('shared strings, escapes and rich text', () {
      expect(table.rows[0][4], 'Pinot Noir');
      expect(table.rows[0][7], 'R&D <trial>');
      // Bold "Tero" + plain "ldego" is one cell, two runs.
      expect(table.rows[2][4], 'Teroldego');
      expect(table.rows[1][6], 'Dead');
    });

    test('an empty cell is null, not an empty string', () {
      expect(table.cell(table.rows[1], 7), isNull);
    });
  });

  group('csv', () {
    test('quoted fields keep delimiters, quotes and line breaks', () {
      final t = TableReader.read(
        _csv(
          'ID,Notes\n1.1.1,"a, b"\n1.1.2,"say ""hi"""\n1.1.3,"two\nlines"\n',
        ),
      );
      expect(t.rows.map((r) => r[1]), ['a, b', 'say "hi"', 'two\nlines']);
    });

    test('semicolons, a byte-order mark and CRLF', () {
      final t = TableReader.read(_csv('﻿ID;Health\r\n1.1.1;4\r\n1.1.2;\r\n'));
      expect(t.headers, ['ID', 'Health']);
      expect(t.rows[0], ['1.1.1', '4']);
      expect(t.cell(t.rows[1], 1), isNull);
    });

    test('blank lines are skipped', () {
      final t = TableReader.read(_csv('ID,Health\n\n1.1.1,4\n,\n'));
      expect(t.rows, hasLength(1));
    });
  });

  test('an old .xls is refused with advice', () {
    final xls = Uint8List.fromList([0xD0, 0xCF, 0x11, 0xE0, 0, 0, 0, 0]);
    expect(
      () => TableReader.read(xls),
      throwsA(
        isA<TableReadException>().having(
          (e) => e.message,
          'message',
          contains('.xlsx'),
        ),
      ),
    );
  });

  test('an empty file says so', () {
    expect(
      () => TableReader.read(_csv('\n\n')),
      throwsA(isA<TableReadException>()),
    );
  });
}
