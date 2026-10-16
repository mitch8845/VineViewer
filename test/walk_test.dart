import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/walk_order.dart';
import 'package:vine_viewer/core/models/identifier_template.dart';
import 'package:vine_viewer/features/walk/walk_session.dart';

PlantIdentifier _id(String text, {bool retired = false}) =>
    PlantIdentifier(parts: text.split('.'), delimiter: '.', retired: retired);

void main() {
  group('defaultWalkOrder', () {
    test('block, then row, then plant -- each row back the other way', () {
      final order = defaultWalkOrder({
        'b2r1p1': _id('2.1.1'),
        'b1r2p2': _id('1.2.2'),
        'b1r1p1': _id('1.1.1'),
        'b1r2p1': _id('1.2.1'),
        'b1r1p2': _id('1.1.2'),
        'b2r1p2': _id('2.1.2'),
      });
      expect(order, [
        'b1r1p1', 'b1r1p2', // row 1 out
        'b1r2p2', 'b1r2p1', // row 2 back
        'b2r1p1', 'b2r1p2', // block 2 row 1 runs out again: it carries on
      ]);
    });

    test('row 2 comes before row 10', () {
      final order = defaultWalkOrder({
        'ten': _id('1.10.1'),
        'two': _id('1.2.1'),
        'one': _id('1.1.1'),
      });
      expect(order, ['one', 'two', 'ten']);
    });

    test('plant 9 comes before plant 10 within a row', () {
      final order = defaultWalkOrder({
        'p10': _id('1.1.10'),
        'p9': _id('1.1.9'),
      });
      expect(order, ['p9', 'p10']);
    });

    test('retired plants are not walked', () {
      final order = defaultWalkOrder({
        'alive': _id('1.1.1'),
        'gone': _id('1.1.2', retired: true),
      });
      expect(order, ['alive']);
    });

    test('a bare plant number is one long row', () {
      final order = defaultWalkOrder({
        'c': _id('3'),
        'a': _id('1'),
        'b': _id('2'),
      });
      expect(order, ['a', 'b', 'c']);
    });

    test('labels with letters sort the way they read', () {
      expect(compareNatural('A2', 'A10'), lessThan(0));
      expect(compareNatural('north', 'South'), lessThan(0));
      expect(compareNatural('12', '12'), 0);
    });
  });

  group('WalkSession', () {
    test('one field: one tap records and moves on', () {
      final walk = WalkSession(order: ['a', 'b', 'c'], fieldIds: ['health']);
      expect(walk.current, 'a');
      expect(walk.recorded('health'), isTrue);
      expect(walk.current, 'b');
    });

    test('two fields: waits for both, in any order', () {
      final walk = WalkSession(
        order: ['a', 'b'],
        fieldIds: ['health', 'vigour'],
      );
      expect(walk.recorded('vigour'), isFalse);
      expect(walk.current, 'a');
      expect(walk.enteredHere, {'vigour'});
      expect(walk.recorded('health'), isTrue);
      expect(walk.current, 'b');
      expect(walk.enteredHere, isEmpty);
    });

    test('undo goes back to the plant the last value was entered on', () {
      final walk = WalkSession(order: ['a', 'b', 'c'], fieldIds: ['health']);
      walk
        ..recorded('health')
        ..recorded('health');
      expect(walk.current, 'c');

      expect(walk.undo(), (index: 1, fieldId: 'health'));
      expect(walk.current, 'b');
      expect(walk.undo(), (index: 0, fieldId: 'health'));
      expect(walk.current, 'a');
      expect(walk.canUndo, isFalse);
      expect(walk.undo(), isNull);
    });

    test('undo with two fields keeps the other field marked done', () {
      final walk = WalkSession(order: ['a'], fieldIds: ['health', 'vigour'])
        ..recorded('health')
        ..recorded('vigour');
      expect(walk.finished, isTrue);
      walk.undo();
      expect(walk.current, 'a');
      expect(walk.enteredHere, {'health'});
    });

    test('undo after skipping ahead jumps back to where the tap was', () {
      final walk = WalkSession(order: ['a', 'b', 'c', 'd'], fieldIds: ['h'])
        ..recorded('h')
        ..next()
        ..next();
      expect(walk.current, 'd');
      walk.undo();
      expect(walk.current, 'a');
    });

    test('back and next stop at the ends', () {
      final walk = WalkSession(order: ['a', 'b'], fieldIds: ['h'])..back();
      expect(walk.current, 'a');
      walk
        ..next()
        ..next()
        ..next();
      expect(walk.finished, isTrue);
      expect(walk.current, isNull);
      expect(walk.recorded('h'), isFalse);
    });

    test('a start index past the end is clamped', () {
      expect(
        WalkSession(order: ['a'], fieldIds: ['h'], index: 9).finished,
        isTrue,
      );
    });
  });

  group('WalkBookmark', () {
    late Directory dir;
    late WalkBookmarks bookmarks;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('walk_test');
      bookmarks = WalkBookmarks(directory: () async => dir);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('saves, loads and clears per project', () async {
      const mark = WalkBookmark(
        fieldIds: ['health'],
        plantId: 'b',
        index: 1,
        subset: ['a', 'b'],
        orderId: 'terrace',
      );
      await bookmarks.save('p1', mark);
      final loaded = (await bookmarks.load('p1'))!;
      expect(loaded.fieldIds, ['health']);
      expect(loaded.plantId, 'b');
      expect(loaded.subset, ['a', 'b']);
      expect(loaded.orderId, 'terrace');
      expect(await bookmarks.load('p2'), isNull);

      await bookmarks.clear('p1');
      expect(await bookmarks.load('p1'), isNull);
    });

    test('the last walk order chosen is remembered', () async {
      expect(await bookmarks.lastOrder('p1'), isNull);
      await bookmarks.saveLastOrder('p1', 'terrace');
      expect(await bookmarks.lastOrder('p1'), 'terrace');
      // Finishing a walk clears the bookmark, not the choice.
      await bookmarks.clear('p1');
      expect(await bookmarks.lastOrder('p1'), 'terrace');
      await bookmarks.saveLastOrder('p1', null);
      expect(await bookmarks.lastOrder('p1'), '');
    });

    test('a corrupt file reads as no bookmark', () async {
      File('${dir.path}/walks/p1.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{not json');
      expect(await bookmarks.load('p1'), isNull);
    });

    test('resumes at the plant, or where it was if that plant is gone', () {
      const mark = WalkBookmark(fieldIds: ['h'], plantId: 'c', index: 2);
      expect(mark.resumeIndex(['a', 'c', 'd']), 1);
      expect(mark.resumeIndex(['a', 'b', 'd', 'e']), 2);
      expect(mark.resumeIndex(['a']), 1);
    });
  });
}
