import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:jtaxi_control/finance_page.dart';
import 'package:jtaxi_control/finance_repository.dart';
import 'package:jtaxi_control/repository.dart';

class NoClient extends Fake implements SupabaseClient {}

class SampleFinance extends FinanceRepository {
  SampleFinance() : super(NoClient());
  @override
  Future<DbRecord?> pending() async => null;
  @override
  Future<DbRecord> load(String month) async => {
    'summaries': [
      {
        'id': 'taxi1',
        'plate': 'SAMPLE-1',
        'income': 50000,
        'expenses': 100000,
        'fund': 10000,
        'owner_debt': 60000,
        'driver_debt': 40000,
      },
    ],
    'entries': [],
    'dues': [],
  };
}

class OpeningFinance extends SampleFinance {
  DbRecord? submitted;
  @override
  Future<DbRecord> load(String month) async => {
    'summaries': [
      {
        'id': 'taxi1',
        'plate': 'REAL-1',
        'income': 0,
        'expenses': 0,
        'fund': 0,
        'owner_debt': 0,
        'driver_debt': 0,
        'can_initialize': submitted == null,
        'opening_initialized': submitted != null,
        'opened_on': '2026-11-16',
        'opening_cash': submitted?['params']['p_cash'] ?? 0,
        'opening_owner_debt': submitted?['params']['p_owner_debt'] ?? 0,
      },
    ],
    'entries': [],
    'dues': [],
  };
  @override
  Future<void> submit(DbRecord request) async {
    submitted = request;
  }
}

void main() {
  testWidgets(
    'Opening setup defaults to zero and saves independent COP balances once',
    (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = OpeningFinance();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es', 'CO'),
          supportedLocales: const [Locale('es', 'CO')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: FinancePage(repository: repository),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Configurar saldos iniciales'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      expect(tester.widget<TextField>(fields.at(0)).controller!.text, '0');
      expect(tester.widget<TextField>(fields.at(1)).controller!.text, '0');
      await tester.enterText(fields.at(0), '50000');
      await tester.enterText(fields.at(1), '100000');
      await tester.tap(find.text('Confirmar saldos'));
      await tester.pumpAndSettle();
      expect(repository.submitted!['rpc'], 'initialize_taxi');
      expect(repository.submitted!['params']['p_cash'], 50000);
      expect(repository.submitted!['params']['p_owner_debt'], 100000);
      expect(find.text('Configurar saldos iniciales'), findsNothing);
      expect(find.textContaining('Inicio '), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Finance summary and expense form fit a phone without remote access',
    (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es', 'CO'),
          supportedLocales: const [Locale('es', 'CO')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: FinancePage(repository: SampleFinance()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Resultado operativo:'), findsOneWidget);
      expect(find.textContaining('Fondo disponible:'), findsOneWidget);
      expect(find.textContaining('Deuda con propietario:'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Movimientos'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gasto'));
      await tester.pumpAndSettle();
      expect(find.text('Registrar gasto'), findsOneWidget);
      expect(find.text('Categoría'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cerrar'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Vencimientos'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nueva obligación'));
      await tester.pumpAndSettle();
      expect(find.text('Repetición'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
