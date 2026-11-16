import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

typedef DbRecord = Map<String, dynamic>;

class PaymentRejected implements Exception {
  PaymentRejected(this.message);
  final String message;
}

// Membership is checked before the server looks up the token. Losing access
// cannot prove that an earlier attempt was not committed; keep that attempt.
bool isDefinitiveRejection(PostgrestException error) =>
    (error.code == 'P0001' && error.message != 'Acceso no autorizado') ||
    (error.code?.startsWith('23') ?? false);

class TaxiRepository {
  TaxiRepository(this.client);
  final SupabaseClient client;
  final Map<String, List<DbRecord>> data = {};
  Future<void> load() async {
    final snapshot = Map<String, dynamic>.from(
      await client.rpc('dashboard') as Map,
    );
    final next = <String, List<DbRecord>>{};
    for (final table in [
      'taxis',
      'drivers',
      'assignments',
      'quota_rules',
      'obligations',
      'payments',
      'allocations',
      'exemptions',
    ]) {
      next[table] = (snapshot[table] as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
    }
    data
      ..clear()
      ..addAll(next);
  }

  List<DbRecord> rows(String table) => data[table] ?? [];
  String label(String table, Object? id, String field) =>
      rows(table)
          .where((r) => r['id'] == id)
          .map((r) => r[field].toString())
          .firstOrNull ??
      'Sin registro';
  Future<void> rpc(String name, DbRecord params) async {
    await client.rpc(name, params: params);
  }

  String get pendingKey => 'pending_payment_${client.auth.currentUser!.id}';
  Future<DbRecord?> pending() async {
    final raw = (await SharedPreferences.getInstance()).getString(pendingKey);
    return raw == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  DbRecord payment(String assignment, int amount, String day, String note) => {
    'p_id': const Uuid().v4(),
    'p_assignment': assignment,
    'p_amount': amount,
    'p_day': day,
    'p_note': note,
  };
  Future<void> pay(DbRecord request) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = await pending();
    if (existing != null && existing['p_id'] != request['p_id']) {
      throw StateError('Primero confirma el pago pendiente');
    }
    if (!await prefs.setString(pendingKey, jsonEncode(request))) {
      throw StateError('No se pudo conservar el identificador del pago');
    }
    try {
      await rpc('record_payment', request);
    } on PostgrestException catch (e) {
      // These database errors guarantee rollback. Network/timeouts do not.
      if (isDefinitiveRejection(e)) {
        if (await prefs.remove(pendingKey)) {
          throw PaymentRejected(e.message);
        }
      }
      rethrow;
    }
    if (!await prefs.remove(pendingKey)) {
      throw StateError(
        'Pago confirmado; reintenta para comprobar su confirmación',
      );
    }
  }
}
