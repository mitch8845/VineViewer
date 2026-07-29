import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/db/daos/field_defs_dao.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/models/enums.dart';

/// Whether a field's role, type, draw type and container flag hang together.
///
/// These come back as problems rather than exceptions because the field editor
/// offers all four controls and a user can genuinely produce a nonsensical
/// combination -- unlike changing a type or a draw type, which the UI must
/// never offer at all and which therefore throw.
void main() {
  late AppDatabase db;
  late FieldDefsDao fields;
  late String projectId;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    fields = FieldDefsDao(db);
    projectId = await ProjectsDao(db).create(name: 'Five Sisters');
  });

  tearDown(() async => db.close());

  Future<FieldDefResult> make({
    String name = 'Thing',
    FieldType type = FieldType.text,
    FieldRole role = FieldRole.attribute,
    DrawType? drawType,
    bool isContainer = false,
  }) => fields.create(
    projectId: projectId,
    name: name,
    type: type,
    role: role,
    drawType: drawType,
    isContainer: isContainer,
  );

  group('objects', () {
    test('a line container is valid', () async {
      expect(
        await make(
          name: 'Row',
          role: FieldRole.object,
          drawType: DrawType.polyline,
          isContainer: true,
        ),
        isA<FieldDefSaved>(),
      );
    });

    test('an object must say how it is drawn', () async {
      final result = await make(name: 'Row', role: FieldRole.object);
      expect(result, isA<FieldDefInvalid>());
      expect(
        (result as FieldDefInvalid).problems,
        contains('Choose how this object is drawn.'),
      );
    });

    test('an object must be a text field', () async {
      // An object's value is its name, and names are text.
      final result = await make(
        name: 'Row',
        type: FieldType.integer,
        role: FieldRole.object,
        drawType: DrawType.polyline,
      );
      expect(result, isA<FieldDefInvalid>());
    });

    test('a point cannot contain plants', () async {
      // A point has no interior, so there is nothing for it to contain.
      final result = await make(
        name: 'Post',
        role: FieldRole.object,
        drawType: DrawType.point,
        isContainer: true,
      );
      expect(result, isA<FieldDefInvalid>());
      expect(
        (result as FieldDefInvalid).problems,
        contains('A point cannot contain plants.'),
      );
    });

    test('a point that contains nothing is fine', () async {
      expect(
        await make(
          name: 'Post',
          role: FieldRole.object,
          drawType: DrawType.point,
        ),
        isA<FieldDefSaved>(),
      );
    });

    test('a non-container line is fine -- a road, a fence', () async {
      expect(
        await make(
          name: 'Road',
          role: FieldRole.object,
          drawType: DrawType.polyline,
        ),
        isA<FieldDefSaved>(),
      );
    });
  });

  group('attributes', () {
    test('a plain attribute is valid', () async {
      expect(
        await make(name: 'Health', type: FieldType.rating),
        isA<FieldDefSaved>(),
      );
    });

    test('an attribute cannot have a shape', () async {
      final result = await make(name: 'Health', drawType: DrawType.polyline);
      expect(result, isA<FieldDefInvalid>());
    });

    test('an attribute cannot contain plants', () async {
      final result = await make(name: 'Health', isContainer: true);
      expect(result, isA<FieldDefInvalid>());
    });
  });

  group('immutability', () {
    test('draw type cannot be changed', () async {
      // Same reason type cannot: every shape already drawn against the field
      // would be invalid. Throws rather than returning a problem, because
      // reaching it means a bug -- the editor disables the control.
      final id =
          ((await make(
                    name: 'Row',
                    role: FieldRole.object,
                    drawType: DrawType.polyline,
                  ))
                  as FieldDefSaved)
              .id;

      expect(
        () => fields.update(id, drawType: DrawType.polygon),
        throwsStateError,
      );
    });

    test('setting the same draw type is not a change', () async {
      final id =
          ((await make(
                    name: 'Row',
                    role: FieldRole.object,
                    drawType: DrawType.polyline,
                  ))
                  as FieldDefSaved)
              .id;

      expect(
        await fields.update(id, drawType: DrawType.polyline),
        isA<FieldDefSaved>(),
      );
    });

    test('the container flag can be turned off later', () async {
      // Unlike the shape, this is reversible: the memberships it produced are
      // derived and simply stop being derived.
      final id =
          ((await make(
                    name: 'Row',
                    role: FieldRole.object,
                    drawType: DrawType.polyline,
                    isContainer: true,
                  ))
                  as FieldDefSaved)
              .id;

      expect(await fields.update(id, isContainer: false), isA<FieldDefSaved>());
      expect((await fields.byId(id))!.isContainer, isFalse);
    });
  });

  group('lookups', () {
    test('objectFieldsForProject finds only drawn things', () async {
      await make(name: 'Health', type: FieldType.rating);
      await make(
        name: 'Row',
        role: FieldRole.object,
        drawType: DrawType.polyline,
        isContainer: true,
      );
      await make(
        name: 'Road',
        role: FieldRole.object,
        drawType: DrawType.polyline,
      );

      final objects = await fields.objectFieldsForProject(projectId);
      expect(objects.map((f) => f.name), ['Row', 'Road']);
    });

    test('containerFieldsForProject excludes the road', () async {
      await make(
        name: 'Row',
        role: FieldRole.object,
        drawType: DrawType.polyline,
        isContainer: true,
      );
      await make(
        name: 'Road',
        role: FieldRole.object,
        drawType: DrawType.polyline,
      );

      final containers = await fields.containerFieldsForProject(projectId);
      expect(containers.map((f) => f.name), ['Row']);
    });
  });

  test('placeholder and tolerance round-trip', () async {
    final id =
        ((await fields.create(
                  projectId: projectId,
                  name: 'Row',
                  type: FieldType.text,
                  role: FieldRole.object,
                  drawType: DrawType.polyline,
                  isContainer: true,
                  blankPlaceholder: 'none',
                  tolerance: 12.5,
                ))
                as FieldDefSaved)
            .id;

    final field = (await fields.byId(id))!;
    expect(field.blankPlaceholder, 'none');
    expect(field.tolerance, 12.5);
  });
}
