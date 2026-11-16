import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:jtaxi_control/repository.dart';
import 'package:jtaxi_control/finance_repository.dart';

class TestAuth extends Fake implements GoTrueClient {
  @override
  User? get currentUser => const User(
    id: 'test-member',
    appMetadata: {},
    userMetadata: {},
    aud: 'authenticated',
    createdAt: '2026-11-16T00:00:00Z',
  );
}

class Response<T> extends Fake implements PostgrestFilterBuilder<T> {
  Response(this.result);
  final Future<T> result;
  @override
  Future<R> then<R>(FutureOr<R> Function(T) onValue, {Function? onError}) =>
      result.then(onValue, onError: onError);
}

class TestClient extends Fake implements SupabaseClient {
  Object? error;
  int calls = 0;
  Map<String, dynamic>? last;
  @override
  GoTrueClient get auth => TestAuth();
  @override
  PostgrestFilterBuilder<T> rpc<T>(
    String fn, {
    Map<String, dynamic>? params,
    dynamic get = false,
  }) {
    calls++;
    last = params;
    return Response<T>(
      Future<T>.sync(() {
        if (error != null) throw error!;
        return null as T;
      }),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'Membership rejection cannot discard an uncertain existing token',
    () async {
      final client = TestClient()..error = TimeoutException('unknown');
      final repo = TaxiRepository(client);
      final request = repo.payment('assignment', 30000, '2026-11-16', 'test');
      await expectLater(repo.pay(request), throwsA(isA<TimeoutException>()));
      client.error = const PostgrestException(
        message: 'Acceso no autorizado',
        code: 'P0001',
      );
      await expectLater(repo.pay(request), throwsA(isA<PostgrestException>()));
      expect(await repo.pending(), request);
    },
  );
  test('Definitive payment rejection releases token; corrected payment uses new ID', () async {
    final client = TestClient()
      ..error = const PostgrestException(
        message: 'El pago supera la deuda',
        code: 'P0001',
      );
    final repo = TaxiRepository(client);
    final request = repo.payment('assignment', 100000, '2026-11-16', 'test');
    await expectLater(repo.pay(request), throwsA(isA<PaymentRejected>()));
    expect(await repo.pending(), isNull);
    client.error = null;
    final corrected = repo.payment('assignment', 30000, '2026-11-16', 'test');
    expect(corrected['p_id'], isNot(request['p_id']));
    await repo.pay(corrected);
    expect(await repo.pending(), isNull);
  });
  test(
    'Ambiguous payment retains payload across restart and retries same ID',
    () async {
      final client = TestClient()..error = TimeoutException('unknown outcome');
      final repo = TaxiRepository(client);
      final request = repo.payment('assignment', 30000, '2026-11-16', 'test');
      await expectLater(repo.pay(request), throwsA(isA<TimeoutException>()));
      final restored = await TaxiRepository(client).pending();
      expect(restored, request);
      client.error = null;
      await repo.pay(restored!);
      expect(client.last!['p_id'], request['p_id']);
      expect(await repo.pending(), isNull);
    },
  );
  test('Finance attempt persists, cannot be replaced, and clears only on confirmation', () async {
    final client = TestClient()..error = TimeoutException('unknown');
    final repo = FinanceRepository(client);
    final request = repo.request('record_finance', {
      'p_taxi': 'one',
      'p_kind': 'expense',
      'p_amount': 100,
    });
    await expectLater(repo.submit(request), throwsA(isA<TimeoutException>()));
    expect(await FinanceRepository(client).pending(), request);
    await expectLater(
      repo.submit(repo.request('record_finance', {'p_amount': 200})),
      throwsStateError,
    );
    expect(client.calls, 1);
    client.error = null;
    await repo.submit(request);
    expect(client.calls, 2);
    expect(await repo.pending(), isNull);
  });
  test(
    'Definitive finance rejection releases the form for correction',
    () async {
      final client = TestClient()
        ..error = const PostgrestException(
          message: 'Fondos insuficientes',
          code: 'P0001',
        );
      final repo = FinanceRepository(client);
      await expectLater(
        repo.submit(repo.request('record_finance', {'p_amount': 100})),
        throwsA(isA<PaymentRejected>()),
      );
      expect(await repo.pending(), isNull);
    },
  );
}
