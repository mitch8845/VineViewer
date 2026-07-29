import 'dart:ui' show Offset;

import 'package:drift/drift.dart';

import '../db/database.dart';
import 'label_service.dart';

/// Which way a selection is walked when numbering it.
enum NumberingOrder {
  leftToRight,
  rightToLeft,
  topToBottom,
  bottomToTop;

  String get description => switch (this) {
    NumberingOrder.leftToRight => 'left to right',
    NumberingOrder.rightToLeft => 'right to left',
    NumberingOrder.topToBottom => 'top to bottom',
    NumberingOrder.bottomToTop => 'bottom to top',
  };
}

/// What numbering a selection would do, before anything is written.
class NumberingPlan {
  const NumberingPlan({
    required this.assignments,
    required this.startAt,
    required this.order,
  });

  /// vine id -> new `position_idx`.
  final Map<String, int> assignments;

  final int startAt;
  final NumberingOrder order;

  bool get isEmpty => assignments.isEmpty;
}

sealed class NumberingResult {
  const NumberingResult();
}

class NumberingApplied extends NumberingResult {
  const NumberingApplied(this.count);
  final int count;
}

/// Nothing was written.
class NumberingRefused extends NumberingResult {
  const NumberingRefused(this.collisions);

  /// The identifiers that would have been held by more than one plant.
  final List<String> collisions;
}

/// Numbers a selection of plants.
///
/// Replaces v2's `renumberRow` and the never-built Reverse Row with one tool.
/// That is the payoff of separating numbering from structure: Reverse is this
/// with the opposite [NumberingOrder], and split and merge can move plants
/// between carriers without deciding anything about numbers at all.
class NumberingService {
  NumberingService(this._db, this._labels);

  final AppDatabase _db;
  final LabelService _labels;

  /// Works out the new numbers. Pure with respect to the database -- reads
  /// positions, writes nothing.
  Future<NumberingPlan> plan({
    required Set<String> vineIds,
    required int startAt,
    required NumberingOrder order,
  }) async {
    if (vineIds.isEmpty) {
      return NumberingPlan(
        assignments: const {},
        startAt: startAt,
        order: order,
      );
    }

    final rows = await _db
        .customSelect(
          'SELECT id, x, y FROM vines WHERE deleted_at IS NULL',
          readsFrom: {_db.vines},
        )
        .get();

    final plants = <({String id, Offset at})>[
      for (final r in rows)
        if (vineIds.contains(r.read<String>('id')))
          (
            id: r.read<String>('id'),
            at: Offset(
              r.readNullable<double>('x') ?? 0,
              r.readNullable<double>('y') ?? 0,
            ),
          ),
    ];

    plants.sort((a, b) => _compare(a, b, order));

    return NumberingPlan(
      assignments: {
        for (var i = 0; i < plants.length; i++) plants[i].id: startAt + i,
      },
      startAt: startAt,
      order: order,
    );
  }

  /// Sorts on the chosen axis, then the other one, then the id.
  ///
  /// The tie-breaks are what make re-running the same numbering give the same
  /// answer. A row drawn at a slight angle has plants whose y values differ by
  /// fractions of a pixel, and without a total order they would reshuffle
  /// between runs.
  int _compare(
    ({String id, Offset at}) a,
    ({String id, Offset at}) b,
    NumberingOrder order,
  ) {
    final primary = switch (order) {
      NumberingOrder.leftToRight => a.at.dx.compareTo(b.at.dx),
      NumberingOrder.rightToLeft => b.at.dx.compareTo(a.at.dx),
      NumberingOrder.topToBottom => a.at.dy.compareTo(b.at.dy),
      NumberingOrder.bottomToTop => b.at.dy.compareTo(a.at.dy),
    };
    if (primary != 0) return primary;

    final secondary = switch (order) {
      NumberingOrder.leftToRight ||
      NumberingOrder.rightToLeft => a.at.dy.compareTo(b.at.dy),
      NumberingOrder.topToBottom ||
      NumberingOrder.bottomToTop => a.at.dx.compareTo(b.at.dx),
    };
    if (secondary != 0) return secondary;

    return a.id.compareTo(b.id);
  }

  /// Writes the plan, or refuses it whole.
  ///
  /// **Duplicates are refused, not warned about.** Every identifier the plan
  /// would produce is rendered and checked against every plant in the project,
  /// and if any two collide nothing is written at all. A partial renumber would
  /// leave the vineyard in a state no one asked for and undo would have to
  /// unpick.
  ///
  /// The check renders *full identifiers*, not bare numbers: two plants sharing
  /// `position_idx` 7 is perfectly legal when they are on different rows.
  Future<NumberingResult> apply(
    NumberingPlan plan, {
    required String projectId,
    DateTime? now,
  }) async {
    if (plan.isEmpty) return const NumberingApplied(0);

    final data = await _labels.dataFor(projectId);
    final template = await _labels.templateFor(projectId);

    final after = LabelService.render(
      data.withNumbers(plan.assignments),
      template,
    );
    final change = LabelService.compare(
      LabelService.render(data, template),
      after,
    );
    if (!change.isSafe) return NumberingRefused(change.duplicates);

    final timestamp = now ?? DateTime.now();
    await _db.transaction(() async {
      for (final entry in plan.assignments.entries) {
        await (_db.update(
          _db.vines,
        )..where((v) => v.id.equals(entry.key))).write(
          VinesCompanion(
            positionIdx: Value(entry.value),
            updatedAt: Value(timestamp),
          ),
        );
      }
    });

    return NumberingApplied(plan.assignments.length);
  }
}
