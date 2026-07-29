import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/label_service.dart';
import 'package:vine_viewer/core/db/daos/layout_dao.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/database.dart';

/// Row numbers restart in every block.
///
/// Taken from the vineyard's own records rather than assumed: block 1 has rows
/// 1-25, block 2 has 1-24, block 3 has 1-26. So `1.12` and `2.12` are different
/// physical rows, and a project-wide allocator -- which is what shipped -- would
/// number the first row drawn in block 2 as 26.
void main() {
  late AppDatabase db;
  late LabelService labels;
  late LayoutDao layout;
  late String projectId;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    labels = LabelService(db);
    layout = LayoutDao(db, labels);
    projectId = await ProjectsDao(db).create(name: 'Five Sisters');
  });

  tearDown(() async => db.close());

  Future<String> block(String label) =>
      layout.createBlock(projectId: projectId, label: label);

  Future<String> row(String label, {String? blockId}) =>
      layout.createRow(projectId: projectId, label: label, blockId: blockId);

  group('nextRowNumber', () {
    test('starts at 1 in an empty project', () async {
      expect(await labels.nextRowNumber(projectId: projectId), 1);
    });

    test('counts up within one block', () async {
      final b = await block('1');
      await row('1', blockId: b);
      await row('2', blockId: b);
      expect(await labels.nextRowNumber(projectId: projectId, blockId: b), 3);
    });

    test('restarts at 1 in a second block', () async {
      // The bug this file exists for. Block 1 having rows 1-25 must not push
      // block 2's first row to 26.
      final one = await block('1');
      final two = await block('2');
      for (var i = 1; i <= 25; i++) {
        await row('$i', blockId: one);
      }

      expect(
        await labels.nextRowNumber(projectId: projectId, blockId: one),
        26,
      );
      expect(await labels.nextRowNumber(projectId: projectId, blockId: two), 1);
    });

    test('the unassigned scope is its own', () async {
      // Rows are drawn before blocks are decided, so this is the normal path.
      final b = await block('1');
      await row('1', blockId: b);
      await row('2', blockId: b);

      expect(await labels.nextRowNumber(projectId: projectId), 1);
      await row('1');
      expect(await labels.nextRowNumber(projectId: projectId), 2);
    });

    test('fills a gap left by a deleted row', () async {
      final b = await block('1');
      await row('1', blockId: b);
      final second = await row('2', blockId: b);
      await row('3', blockId: b);

      await db.customStatement('DELETE FROM vine_rows WHERE id = ?', [second]);
      expect(await labels.nextRowNumber(projectId: projectId, blockId: b), 2);
    });

    test('a non-numeric row label occupies no number', () async {
      // Row labels are free text. "north" cannot collide with a number, so it
      // must not consume one either.
      final b = await block('1');
      await row('north', blockId: b);
      expect(await labels.nextRowNumber(projectId: projectId, blockId: b), 1);
    });

    test('another project does not interfere', () async {
      final other = await ProjectsDao(db).create(name: 'Elsewhere');
      await layout.createRow(projectId: other, label: '1');
      expect(await labels.nextRowNumber(projectId: projectId), 1);
    });
  });

  group('isRowNumberFree', () {
    test('a taken number in the same block is not free', () async {
      final b = await block('1');
      await row('12', blockId: b);
      expect(
        await labels.isRowNumberFree(
          projectId: projectId,
          blockId: b,
          number: '12',
        ),
        isFalse,
      );
    });

    test('the same number in a different block is free', () async {
      final one = await block('1');
      final two = await block('2');
      await row('12', blockId: one);
      expect(
        await labels.isRowNumberFree(
          projectId: projectId,
          blockId: two,
          number: '12',
        ),
        isTrue,
      );
    });

    test('a row does not collide with itself when renamed in place', () async {
      final b = await block('1');
      final r = await row('12', blockId: b);
      expect(
        await labels.isRowNumberFree(
          projectId: projectId,
          blockId: b,
          number: '12',
          ignoringRowId: r,
        ),
        isTrue,
      );
    });

    test('the unassigned scope is checked separately', () async {
      final b = await block('1');
      await row('12', blockId: b);
      expect(
        await labels.isRowNumberFree(projectId: projectId, number: '12'),
        isTrue,
      );

      await row('12');
      expect(
        await labels.isRowNumberFree(projectId: projectId, number: '12'),
        isFalse,
      );
    });

    test('whitespace around a typed number is ignored', () async {
      final b = await block('1');
      await row('12', blockId: b);
      expect(
        await labels.isRowNumberFree(
          projectId: projectId,
          blockId: b,
          number: '  12 ',
        ),
        isFalse,
      );
    });
  });
}
