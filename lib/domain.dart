// All monetary values are whole Colombian pesos, never floating point values.
DateTime bogotaToday([DateTime? instant]) {
  final local = (instant ?? DateTime.now()).toUtc().subtract(
    const Duration(hours: 5),
  );
  return DateTime(local.year, local.month, local.day);
}

String dateKey(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
int obligationBalance(
  Map<String, dynamic> obligation,
  Iterable<Map<String, dynamic>> allocations,
) {
  if (obligation['exempt_reason'] != null) return 0;
  return (obligation['amount'] as num).toInt() -
      allocations
          .where(
            (a) =>
                a['obligation_id'] == obligation['id'] &&
                a['reversed_at'] == null,
          )
          .fold<int>(0, (sum, a) => sum + (a['amount'] as num).toInt());
}

bool quotaApplies({
  required DateTime day,
  required DateTime start,
  DateTime? end,
  required bool fixed,
  required Set<int> weekdays,
  Set<String> exemptions = const {},
}) =>
    fixed &&
    !day.isBefore(start) &&
    (end == null || !day.isAfter(end)) &&
    weekdays.contains(day.weekday) &&
    !exemptions.contains(dateKey(day));
int assignmentDebt(
  String id,
  Iterable<Map<String, dynamic>> obligations,
  Iterable<Map<String, dynamic>> allocations,
) => obligations
    .where((o) => o['assignment_id'] == id)
    .fold(0, (sum, o) => sum + obligationBalance(o, allocations));
