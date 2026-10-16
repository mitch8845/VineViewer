import 'dart:convert';
import 'dart:io' show gzip;

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../db/database.dart';

/// One project's state, frozen, ready to start new vineyards from.
///
/// Built off-device by `tool/make_seed.py` from a database pulled from a
/// tablet, and bundled with the app. Rows carry the database's own column names
/// and values, so loading is insertion and nothing else -- there is no
/// translation layer to drift out of step with the schema.
class ProjectSeed {
  ProjectSeed._(this._json);

  /// Decodes gzipped seed JSON.
  ///
  /// Refuses a seed read from a newer schema than this build's: its rows may
  /// name columns that do not exist yet. An *older* one is fine -- every
  /// migration since v4 has been additive, so the missing columns take their
  /// defaults.
  factory ProjectSeed.decode(List<int> gzipped, {required int schemaVersion}) {
    final json =
        jsonDecode(utf8.decode(gzip.decode(gzipped))) as Map<String, dynamic>;
    if (json['version'] != formatVersion) {
      throw FormatException('Unknown seed format ${json['version']}.');
    }
    final from = json['schemaVersion'] as int;
    if (from > schemaVersion) {
      throw FormatException(
        'This seed needs a newer version of the app (database v$from).',
      );
    }
    return ProjectSeed._(json);
  }

  static const formatVersion = 1;

  final Map<String, dynamic> _json;

  /// The name of the vineyard it was taken from.
  String get name => _json['name'] as String;

  int get plantCount => _rows('plants').length;

  Map<String, dynamic> get _project => _json['project'] as Map<String, dynamic>;

  List<Map<String, dynamic>> _rows(String key) =>
      (_json[key] as List).cast<Map<String, dynamic>>();
}

/// Loads a [ProjectSeed] into a project.
///
/// **Every id is new.** The seed's own ids are the tablet's, and reusing them
/// would mean a seed could be loaded once per device and never again --
/// the second load would collide with the first on every primary key. Fresh
/// ids also keep two vineyards started from one seed apart for any future
/// sync, which matches rows by id.
class SeedService {
  SeedService(this._db, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final AppDatabase _db;
  final Uuid _uuid;

  /// Fills [projectId] -- which should be empty -- with everything in [seed].
  ///
  /// [imagePath] is the copy of the seed's aerial on this device. Its
  /// dimensions and placement come from the seed, since every coordinate in
  /// the seed is in that image's pixel space.
  ///
  /// Writes through ordinary SQL, so the capture triggers see every row: run
  /// inside the operation recorder and the whole load is one undo step.
  Future<void> load(
    String projectId,
    ProjectSeed seed, {
    String? imagePath,
    DateTime? now,
  }) async {
    final ids = <String, String>{};
    String? id(Object? old) =>
        old == null ? null : ids.putIfAbsent(old as String, _uuid.v4);

    // Assigned up front for the field ids, which the identifier template
    // refers to by value inside a JSON string.
    final fieldDefs = seed._rows('fieldDefs');
    for (final f in fieldDefs) {
      id(f['id']);
    }

    final project = seed._project;
    var template = project['identifier_template'] as String?;
    if (template != null) {
      for (final f in fieldDefs) {
        template = template!.replaceAll(f['id'] as String, id(f['id'])!);
      }
    }

    await _db.transaction(() async {
      await _db.customUpdate(
        'UPDATE projects SET image_path = ?, image_width = ?, image_height = ?, '
        'image_offset_x = ?, image_offset_y = ?, image_scale_x = ?, '
        'image_scale_y = ?, image_rotation = ?, scale_ref_px = ?, '
        'scale_ref_length = ?, scale_unit = ?, identifier_template = ?, '
        'updated_at = ? WHERE id = ?',
        variables: [
          for (final v in [
            imagePath,
            project['image_width'],
            project['image_height'],
            project['image_offset_x'],
            project['image_offset_y'],
            project['image_scale_x'],
            project['image_scale_y'],
            project['image_rotation'],
            project['scale_ref_px'],
            project['scale_ref_length'],
            project['scale_unit'],
            template,
            (now ?? DateTime.now()).millisecondsSinceEpoch,
            projectId,
          ])
            Variable(v),
        ],
        updates: {_db.projects},
      );

      // Parents before children, or the foreign keys refuse the first plant.
      await _db.batch((batch) {
        void insert(
          String table,
          List<Map<String, dynamic>> rows,
          Map<String, dynamic> Function(Map<String, dynamic>) remap,
        ) {
          for (final row in rows) {
            final values = {...row, ...remap(row)};
            final columns = values.keys.toList();
            batch.customStatement(
              'INSERT INTO $table (${columns.join(', ')}) '
              'VALUES (${List.filled(columns.length, '?').join(', ')})',
              [for (final c in columns) values[c]],
            );
          }
        }

        insert(
          'field_defs',
          fieldDefs,
          (r) => {'id': id(r['id']), 'project_id': projectId},
        );
        insert(
          'map_objects',
          seed._rows('mapObjects'),
          (r) => {
            'id': id(r['id']),
            'project_id': projectId,
            'field_def_id': id(r['field_def_id']),
          },
        );
        insert(
          'plants',
          seed._rows('plants'),
          (r) => {
            'id': id(r['id']),
            'project_id': projectId,
            'carrier_id': id(r['carrier_id']),
            'predecessor_id': id(r['predecessor_id']),
          },
        );
        insert(
          'plant_memberships',
          seed._rows('plantMemberships'),
          (r) => {
            'id': id(r['id']),
            'plant_id': id(r['plant_id']),
            'object_id': id(r['object_id']),
            'field_def_id': id(r['field_def_id']),
          },
        );
        insert(
          'field_events',
          seed._rows('fieldEvents'),
          (r) => {
            'id': id(r['id']),
            'plant_id': id(r['plant_id']),
            'field_def_id': id(r['field_def_id']),
            // Remapped like any id, so one import's values still roll back
            // together -- and never with the same import's on another
            // vineyard started from this seed.
            'batch_id': id(r['batch_id']),
          },
        );
      });
    });
  }
}
