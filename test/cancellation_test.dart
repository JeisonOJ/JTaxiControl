import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jtaxi_control/cancel_payment_button.dart';
import 'package:jtaxi_control/finance_repository.dart';
import 'package:jtaxi_control/repository.dart';
import 'package:jtaxi_control/domain.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class NoClient extends Fake implements SupabaseClient {}

class CancelRepository extends FinanceRepository {
  CancelRepository() : super(NoClient());
  DbRecord? saved;
  Object? error;
  @override
  Future<DbRecord?> pending() async => saved;
  @override
  Future<void> submit(DbRecord request) async {
    saved = request;
    if (error != null) throw error!;
  }
}

void main() {
  test(
    'Reversed allocations remain auditable but never reduce driver debt',
    () {
      expect(
        obligationBalance(
          {'id': 'one', 'amount': 90000, 'exempt_reason': null},
          [
            {
              'obligation_id': 'one',
              'amount': 30000,
              'reversed_at': '2026-11-16T00:00:00Z',
            },
            {'obligation_id': 'one', 'amount': 10000},
          ],
        ),
        80000,
      );
    },
  );
  testWidgets(
    'Cancellation requires explicit confirmation, preserves pending token on uncertain response',
    (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = CancelRepository()
        ..error = Exception('unknown response');
      int refreshes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CancelPaymentButton(
              payment: {
                'id': 'payment-one',
                'amount': 30000,
                'paid_on': '2026-11-16',
              },
              repository: repository,
              onChanged: () async {
                refreshes++;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Anular pago'));
      await tester.pumpAndSettle();
      expect(repository.saved, isNull);
      await tester.tap(find.text('Volver'));
      await tester.pumpAndSettle();
      expect(repository.saved, isNull);
      await tester.tap(find.text('Anular pago'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Error de registro');
      await tester.tap(find.text('Confirmar anulación'));
      await tester.pumpAndSettle();
      final token = repository.saved!['params']['p_id'];
      expect(repository.saved!['params']['p_reason'], 'Error de registro');
      expect(repository.saved!['params']['p_payment'], 'payment-one');
      repository.error = null;
      await tester.tap(find.text('Confirmar anulación'));
      await tester.pumpAndSettle();
      expect(repository.saved!['params']['p_id'], token);
      expect(refreshes, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
