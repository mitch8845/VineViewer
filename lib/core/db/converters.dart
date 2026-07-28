import 'package:drift/drift.dart';

/// Stores a [DateTime] as epoch **milliseconds**.
///
/// drift's built-in `dateTime()` stores epoch *seconds*, which is too coarse
/// here. `field_events` resolves a current value by ordering on `observed_at`,
/// and a bulk edit or import can write many events inside the same second.
/// At second precision those events tie, and the "latest" one is whichever the
/// query planner happens to return -- a nondeterministic current value.
///
/// Always stored in UTC. Local-time storage would shift every historical
/// timestamp the first time the device crosses a DST boundary or the user
/// travels, quietly corrupting year-over-year comparisons -- which is the
/// entire point of the event log.
class DateTimeMsConverter extends TypeConverter<DateTime, int>
    with JsonTypeConverter<DateTime, int> {
  const DateTimeMsConverter();

  @override
  DateTime fromSql(int fromDb) =>
      DateTime.fromMillisecondsSinceEpoch(fromDb, isUtc: true);

  @override
  int toSql(DateTime value) => value.toUtc().millisecondsSinceEpoch;
}
