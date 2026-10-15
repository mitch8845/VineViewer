// Renders the app's main screens to PNGs for design review.
//
// Not part of the suite -- `flutter test` only runs test/. Run with:
//
//   flutter test tool/screenshots_test.dart
//
// Output lands in build/screenshots/. Real Roboto and Material Icons are loaded
// from the Flutter SDK, so text renders as text rather than test boxes, and
// the real aerial is drawn under a seeded layout shaped like Five Sisters.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/app_theme.dart';
import 'package:vine_viewer/core/db/daos/field_defs_dao.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/geometry/polyline.dart';
import 'package:vine_viewer/core/geometry/shapes.dart';
import 'package:vine_viewer/core/models/enums.dart';
import 'package:vine_viewer/core/models/field_config.dart';
import 'package:vine_viewer/core/models/identifier_template.dart';
import 'package:vine_viewer/core/providers.dart';
import 'package:vine_viewer/features/canvas/canvas_controller.dart';
import 'package:vine_viewer/features/canvas/map_chrome.dart';
import 'package:vine_viewer/features/canvas/vineyard_canvas.dart';
import 'package:vine_viewer/features/canvas/vineyard_screen.dart';
import 'package:vine_viewer/features/canvas/tools/object_actions_sheet.dart';
import 'package:vine_viewer/features/data_entry/value_editor_sheet.dart';
import 'package:vine_viewer/core/import/table_reader.dart';
import 'package:vine_viewer/features/projects/import_screen.dart';
import 'package:vine_viewer/features/projects/project_list_screen.dart';
import 'package:vine_viewer/features/schema/field_editor_screen.dart';
import 'package:vine_viewer/features/schema/project_setup_wizard.dart';

const _logicalSize = Size(1500, 900); // Fire Max 11 landscape, ~1.33 dpr
const _dpr = 1.33;

Future<void> _loadFonts() async {
  final sdk = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
  final dir = '$sdk/bin/cache/artifacts/material_fonts';
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      final bytes = File('$dir/$f').readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
  }

  await load('Roboto', [
    'roboto-regular.ttf',
    'roboto-medium.ttf',
    'roboto-bold.ttf',
    'roboto-light.ttf',
  ]);
  await load('MaterialIcons', ['materialicons-regular.otf']);
}

class _Seed {
  late String projectId;
  late String healthField;
  late String varietyField;
  late List<String> plants;
  late String firstRowId;
}

Future<_Seed> _seed(AppDatabase db, ProviderContainer c) async {
  final seed = _Seed();
  final projects = c.read(projectsDaoProvider);
  final fields = c.read(fieldDefsDaoProvider);
  final layout = c.read(layoutDaoProvider);
  final events = c.read(fieldEventsDaoProvider);

  final aerial = File('assets/aerial/five_sisters_aerial.jpg').absolute.path;
  seed.projectId = await projects.create(name: 'Five Sisters');
  await projects.setImage(
    seed.projectId,
    imagePath: aerial,
    width: 874,
    height: 763,
  );
  await projects.create(name: 'North Slope Trial');

  Future<String> make(
    String name,
    FieldType type, {
    FieldRole role = FieldRole.attribute,
    DrawType? draw,
    bool container = false,
    bool isStatic = false,
    FieldConfig config = FieldConfig.empty,
  }) async =>
      ((await fields.create(
                projectId: seed.projectId,
                name: name,
                type: type,
                role: role,
                drawType: draw,
                isContainer: container,
                isStatic: isStatic,
                blankPlaceholder: container ? '0' : null,
                config: config,
              ))
              as FieldDefSaved)
          .id;

  final row = await make(
    'Row',
    FieldType.text,
    role: FieldRole.object,
    draw: DrawType.polyline,
    container: true,
  );
  final block = await make(
    'Block',
    FieldType.text,
    role: FieldRole.object,
    draw: DrawType.polygon,
    container: true,
  );
  seed.healthField = await make(
    'Health',
    FieldType.rating,
    config: const FieldConfig(
      scaleMin: 1,
      scaleMax: 5,
      labels: {'1': 'Dead', '3': 'Fair', '5': 'Excellent'},
    ),
  );
  seed.varietyField = await make(
    'Variety',
    FieldType.categorical,
    isStatic: true,
    config: const FieldConfig(
      options: ['Marquette', 'La Crescent', 'Frontenac'],
      optionColors: {
        'Marquette': '#6A1B9A',
        'La Crescent': '#FBC02D',
        'Frontenac': '#D32F2F',
      },
    ),
  );
  await make('Planted', FieldType.date, isStatic: true);
  await make('Notes', FieldType.text);

  await projects.setIdentifierTemplate(
    seed.projectId,
    IdentifierTemplate(
      delimiter: '.',
      parts: [FieldPart(block), FieldPart(row), const PlantPart()],
    ),
  );

  await layout.createObject(
    projectId: seed.projectId,
    fieldDefId: block,
    label: '1',
    geometry: PolygonShape(const [
      Offset(200, 160),
      Offset(696, 150),
      Offset(702, 446),
      Offset(204, 452),
    ]),
  );
  await layout.createObject(
    projectId: seed.projectId,
    fieldDefId: block,
    label: '2',
    geometry: PolygonShape(const [
      Offset(362, 456),
      Offset(722, 450),
      Offset(722, 694),
      Offset(368, 694),
    ]),
  );

  final random = math.Random(7);
  final allPlants = <String>[];
  var label = 1;
  for (var i = 0; i < 20; i++) {
    final y = 178.0 + i * 13.3;
    final id = await layout.createObject(
      projectId: seed.projectId,
      fieldDefId: row,
      label: '${label++}',
      geometry: PolylineShape(Polyline([Offset(216, y), Offset(686, y - 3)])),
    );
    if (i == 0) seed.firstRowId = id;
    allPlants.addAll(
      await layout.placePlantsAlongCarrier(
        carrierId: id,
        offsets: [for (var o = 0.0; o <= 468; o += 9) o],
      ),
    );
  }
  for (var i = 0; i < 26; i++) {
    final x = 378.0 + i * 13.0;
    final id = await layout.createObject(
      projectId: seed.projectId,
      fieldDefId: row,
      label: '${label++}',
      geometry: PolylineShape(Polyline([Offset(x, 464), Offset(x + 2, 686)])),
    );
    allPlants.addAll(
      await layout.placePlantsAlongCarrier(
        carrierId: id,
        offsets: [for (var o = 0.0; o <= 220; o += 9) o],
      ),
    );
  }
  seed.plants = allPlants;

  // A believable survey: mostly healthy, a weak patch, some unrecorded.
  for (final id in allPlants) {
    if (random.nextDouble() < 0.12) continue;
    final weak = random.nextDouble() < 0.15;
    await events.record(
      plantId: id,
      fieldDefId: seed.healthField,
      value: '${weak ? 1 + random.nextInt(2) : 3 + random.nextInt(3)}',
    );
  }
  await events.record(
    plantId: allPlants[5],
    fieldDefId: seed.varietyField,
    value: 'Marquette',
  );
  return seed;
}

Future<void> _capture(WidgetTester tester, String name) async {
  final boundary =
      tester.renderObject(find.byKey(const ValueKey('shot')))
          as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: _dpr);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/screenshots/$name.png');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

/// Lets real IO (image decode, drift) finish, then pumps the results in.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late _Seed seed;

  setUpAll(_loadFonts);

  testWidgets('screens', (tester) async {
    tester.view.physicalSize = _logicalSize * _dpr;
    tester.view.devicePixelRatio = _dpr;
    addTearDown(tester.view.reset);

    db = AppDatabase(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    seed = (await tester.runAsync(() => _seed(db, container)))!;

    Future<void> show(Widget home, {bool dark = false}) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: RepaintBoundary(
            key: const ValueKey('shot'),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: dark ? AppTheme.dark() : AppTheme.light(),
              home: home,
            ),
          ),
        ),
      );
      await _settle(tester);
      // Image.file decodes off the fake clock; precache for real, then pump.
      await tester.runAsync(() async {
        for (final e in find.byType(Image).evaluate()) {
          await precacheImage((e.widget as Image).image, e);
        }
      });
      await tester.pump();
    }

    await show(const ProjectListScreen());
    await _capture(tester, '01_projects');

    container.read(activeProjectIdProvider.notifier).state = seed.projectId;
    await show(const VineyardScreen());
    await _capture(tester, '02_map');

    container.read(selectionProvider.notifier).state = {seed.plants[30]};
    await _settle(tester);
    await _capture(tester, '03_plant_selected');

    container.read(selectionProvider.notifier).state = seed.plants
        .sublist(60, 160)
        .toSet();
    container.read(colorByFieldProvider.notifier).state = seed.healthField;
    await _settle(tester);
    await _capture(tester, '04_colour_and_bulk');

    container.read(selectionProvider.notifier).state = const {};
    container.read(colorByFieldProvider.notifier).state = null;
    container.read(selectedObjectProvider.notifier).state = seed.firstRowId;
    container.read(activeToolProvider.notifier).state = CanvasTool.reshape;
    await _settle(tester);
    await _capture(tester, '05_object_selected');

    // A sheet over the map: map layers.
    container.read(selectedObjectProvider.notifier).state = null;
    container.read(activeToolProvider.notifier).state = CanvasTool.select;
    await _settle(tester);
    final mapContext = tester.element(find.byType(VineyardScreen));
    showModalBottomSheet<void>(
      context: mapContext,
      isScrollControlled: true,
      builder: (_) => const LayersSheet(hasImage: true),
    );
    await _settle(tester);
    await _capture(tester, '06_layers_sheet');
    Navigator.of(mapContext).pop();
    await _settle(tester);

    // Dark theme, plant selected.
    container.read(selectionProvider.notifier).state = {seed.plants[400]};
    await show(const VineyardScreen(), dark: true);
    await _capture(tester, '07_dark');

    // Portrait.
    tester.view.physicalSize = const Size(900, 1500) * _dpr;
    await show(const VineyardScreen());
    await _capture(tester, '08_portrait');
    tester.view.physicalSize = _logicalSize * _dpr;

    container.read(selectionProvider.notifier).state = const {};
    await show(const FieldListScreen());
    await _capture(tester, '09_fields');

    await show(ProjectSetupWizard(projectId: seed.projectId));
    await _capture(tester, '10_wizard');

    await show(const VineyardScreen());
    final ctx = tester.element(find.byType(VineyardScreen));
    showModalBottomSheet<void>(
      context: ctx,
      isScrollControlled: true,
      builder: (_) => ObjectActionsSheet(
        objectId: seed.firstRowId,
        label: '1',
        fieldName: 'Row',
        isLine: true,
      ),
    );
    await _settle(tester);
    await _capture(tester, '11_object_actions');
    Navigator.of(ctx).pop();
    await _settle(tester);

    final health = await tester.runAsync(
      () => container.read(fieldDefsDaoProvider).byId(seed.healthField),
    );
    showValueEditor(
      ctx,
      field: health!,
      config: container.read(fieldDefsDaoProvider).configOf(health),
      current: '4',
    );
    await _settle(tester);
    await _capture(tester, '12_value_editor');
    Navigator.of(ctx).pop();
    await _settle(tester);

    // Import preview, from the real spreadsheet when it is present locally.
    final sheet = File('VineViewer_Data.xlsx');
    if (sheet.existsSync()) {
      await show(
        ImportScreen(
          projectId: seed.projectId,
          table: TableReader.read(sheet.readAsBytesSync()),
        ),
      );
      await _capture(tester, '13_import');
    }

    // Unmount and drain drift's stream-cancel timers before the test ends.
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      container.dispose();
      await db.close();
    });
    await tester.pump(const Duration(seconds: 1));
  });
}
