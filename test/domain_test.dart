import 'package:flutter_test/flutter_test.dart';
import 'package:jtaxi_control/domain.dart';
import 'package:jtaxi_control/main.dart';

void main() {
  test('Colombia date crosses UTC midnight without crossing local date', () {
    expect(dateKey(bogotaToday(DateTime.utc(2026, 11, 17, 2))), '2026-11-16');
  });
  test('Fixed schedule, Sunday off, exemptions and flexible contribution', () {
    bool due(
      DateTime day, {
      bool fixed = true,
      Set<int> days = const {1, 2, 3, 4, 5, 6},
      Set<String> exempt = const {},
    }) => quotaApplies(
      day: day,
      start: DateTime(2026, 11, 1),
      end: DateTime(2026, 11, 30),
      fixed: fixed,
      weekdays: days,
      exemptions: exempt,
    );
    expect(due(DateTime(2026, 11, 15)), false);
    expect(due(DateTime(2026, 11, 16)), true);
    expect(due(DateTime(2026, 11, 15), days: {7}), true);
    expect(due(DateTime(2026, 11, 16), exempt: {'2026-11-16'}), false);
    expect(due(DateTime(2026, 11, 16), fixed: false), false);
    expect(due(DateTime(2026, 12, 1)), false);
  });
  test(
    'Partial payments and replacement preserve debt under original assignment',
    () {
      final obligations = [
        {
          'id': 'o1',
          'assignment_id': 'old',
          'amount': 90000,
          'exempt_reason': null,
        },
        {
          'id': 'o2',
          'assignment_id': 'new',
          'amount': 100000,
          'exempt_reason': null,
        },
      ];
      final allocations = [
        {'obligation_id': 'o1', 'amount': 30000},
        {'obligation_id': 'o1', 'amount': 20000},
      ];
      expect(assignmentDebt('old', obligations, allocations), 40000);
      expect(assignmentDebt('new', obligations, allocations), 100000);
      expect(obligations.first['amount'], 90000);
      expect(
        obligationBalance({
          'id': 'exempt',
          'amount': 90000,
          'exempt_reason': 'Reparación',
        }, allocations),
        0,
      );
    },
  );
  testWidgets(
    'Missing configuration fails closed without financial demo data',
    (tester) async {
      await tester.pumpWidget(
        const TaxiApp(problem: 'Configuración pendiente'),
      );
      expect(find.text('Configuración pendiente'), findsOneWidget);
      expect(find.text('Pagos recibidos'), findsNothing);
    },
  );
}
