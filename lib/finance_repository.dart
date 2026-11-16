import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'repository.dart';

class FinanceRepository {
  FinanceRepository(this.client);
  final SupabaseClient client;
  String get key => 'finance_pending_${client.auth.currentUser!.id}';
  Future<DbRecord> load(String month) async => Map<String, dynamic>.from(
    await client.rpc('finance_dashboard', params: {'p_month': month}) as Map,
  );
  Future<DbRecord?> pending() async {
    final raw = (await SharedPreferences.getInstance()).getString(key);
    return raw == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  DbRecord request(String rpc, DbRecord params) => {
    'rpc': rpc,
    'params': {'p_id': const Uuid().v4(), ...params},
  };
  Future<void> submit(DbRecord request) async {
    final prefs = await SharedPreferences.getInstance();
    final old = await pending();
    if (old != null && jsonEncode(old) != jsonEncode(request)) {
      throw StateError('Confirma primero la operación pendiente');
    }
    if (!await prefs.setString(key, jsonEncode(request))) {
      throw StateError('No se pudo conservar el intento');
    }
    try {
      await client.rpc(
        request['rpc'] as String,
        params: Map<String, dynamic>.from(request['params'] as Map),
      );
    } on PostgrestException catch (e) {
      if (isDefinitiveRejection(e)) {
        if (await prefs.remove(key)) throw PaymentRejected(e.message);
      }
      rethrow;
    }
    if (!await prefs.remove(key)) {
      throw StateError(
        'Operación confirmada; reintenta con el mismo identificador',
      );
    }
  }
}
