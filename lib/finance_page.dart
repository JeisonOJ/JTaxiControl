import 'package:material_ui/material_ui.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'domain.dart';
import 'repository.dart';
import 'finance_repository.dart';

const categories = {
  'maintenance': 'Reparaciones y mantenimiento',
  'parts': 'Repuestos',
  'insurance': 'Seguros / SOAT',
  'tax': 'Impuestos',
  'administration': 'Administración de empresa',
  'other': 'Otros',
};
final _money = NumberFormat.currency(
  locale: 'es_CO',
  symbol: r'$',
  decimalDigits: 0,
);
String _cop(dynamic n) => _money.format(n ?? 0);
String _date(dynamic n) =>
    DateFormat('dd/MM/yyyy').format(DateTime.parse(n as String));

class FinancePage extends StatefulWidget {
  const FinancePage({super.key, this.repository});
  final FinanceRepository? repository;
  @override
  State<FinancePage> createState() => _FinanceState();
}

class _FinanceState extends State<FinancePage> {
  late final repo =
      widget.repository ?? FinanceRepository(Supabase.instance.client);
  DbRecord? data, pending;
  String? error;
  bool busy = true;
  int tab = 0;
  DateTime month = DateTime(bogotaToday().year, bogotaToday().month);
  List<DbRecord> rows(String key) => (data?[key] as List? ?? [])
      .map((r) => Map<String, dynamic>.from(r as Map))
      .toList();
  @override
  void initState() {
    super.initState();
    load();
  }

  String message(Object e) {
    if (e is PaymentRejected) return e.message;
    if (e is PostgrestException && e.code == 'P0001') return e.message;
    if (e is PostgrestException &&
        (e.code == 'PGRST202' || e.code == '42883')) {
      return 'Finanzas aún no está activado en Supabase. La migración de Fase 2 requiere aprobación y aplicación manual.';
    }
    return 'No se pudo confirmar la operación. Comprueba internet y reintenta. Un intento pendiente conserva su identificador para evitar duplicados.';
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final p = await repo.pending();
      final result = await repo.load(dateKey(month));
      if (mounted) {
        setState(() {
          data = result;
          pending = p;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = message(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> retry() async {
    if (pending == null) return;
    setState(() => busy = true);
    try {
      await repo.submit(pending!);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message(e))));
      }
    }
    if (mounted) await load();
  }

  String taxiName(dynamic id) =>
      rows('summaries')
          .where((t) => t['id'] == id)
          .map((t) => t['plate'].toString())
          .firstOrNull ??
      'Taxi';
  Future<void> opening(DbRecord taxi) async {
    if (pending != null) {
      await retry();
      return;
    }
    final cash = TextEditingController(text: '0');
    final debt = TextEditingController(text: '0');
    DateTime day = bogotaToday();
    DbRecord? request;
    String? formError;
    bool saving = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) => PopScope(
          canPop: !saving,
          child: AlertDialog(
            title: Text('Saldos iniciales · ${taxi['plate']}'),
            content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Dinero disponible y deuda pendiente al comenzar. Son independientes: no son ingresos ni aportes nuevos. Confirma antes del primer movimiento. Después no se pueden cambiar.',
                    ),
                    if (request != null)
                      const Text(
                        'Intento pendiente: confirma los mismos datos sin duplicar.',
                      ),
                    TextField(
                      controller: cash,
                      enabled: !saving && request == null,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Dinero disponible inicial (COP)',
                      ),
                    ),
                    TextField(
                      controller: debt,
                      enabled: !saving && request == null,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Deuda inicial con el propietario (COP)',
                      ),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Fecha de inicio de los saldos'),
                      subtitle: Text(_date(dateKey(day))),
                      trailing: const Icon(Icons.calendar_month),
                      onTap: saving || request != null
                          ? null
                          : () async {
                              final selected = await showDatePicker(
                                context: context,
                                initialDate: day,
                                firstDate: DateTime(2000),
                                lastDate: bogotaToday(),
                              );
                              if (selected != null) {
                                update(() => day = selected);
                              }
                            },
                    ),
                    if (formError != null)
                      Text(
                        formError!,
                        style: const TextStyle(color: Colors.red),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => Navigator.pop(dialog),
                child: const Text('Cerrar'),
              ),
              FilledButton(
                onPressed: saving
                    ? null
                    : () async {
                        final c = int.tryParse(cash.text),
                            d = int.tryParse(debt.text);
                        if (c == null ||
                            d == null ||
                            c < 0 ||
                            d < 0 ||
                            c > 1000000000000 ||
                            d > 1000000000000) {
                          update(
                            () => formError = 'Introduce pesos enteros, desde cero, sin puntos.',
                          );
                          return;
                        }
                        request ??= repo.request('initialize_taxi', {
                          'p_taxi': taxi['id'],
                          'p_day': dateKey(day),
                          'p_cash': c,
                          'p_owner_debt': d,
                        });
                        update(() {
                          saving = true;
                          formError = null;
                        });
                        try {
                          await repo.submit(request!);
                          if (dialog.mounted) Navigator.pop(dialog);
                        } catch (e) {
                          if (e is PaymentRejected) request = null;
                          if (context.mounted) {
                            update(() => formError = message(e));
                          }
                        } finally {
                          if (context.mounted) update(() => saving = false);
                        }
                      },
                child: Text(saving ? 'Confirmando…' : 'Confirmar saldos'),
              ),
            ],
          ),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    cash.dispose();
    debt.dispose();
    if (mounted) await load();
  }

  Future<void> entry({
    String kind = 'expense',
    DbRecord? due,
    bool template = false,
  }) async {
    if (rows('summaries').isEmpty) return;
    if (pending != null) {
      await retry();
      return;
    }
    String taxi = due?['taxi_id'] ?? rows('summaries').first['id'];
    String category = due?['category'] ?? 'maintenance';
    int every = 0;
    DateTime day = bogotaToday();
    final amount = TextEditingController(text: due?['amount']?.toString());
    final note = TextEditingController(text: due == null ? '' : due['title']);
    DbRecord? request;
    String? formError;
    bool saving = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) => PopScope(
          canPop: !saving,
          child: AlertDialog(
            title: Text(
              template
                  ? 'Nueva obligación'
                  : due != null
                  ? 'Pagar obligación'
                  : kind == 'advance'
                  ? 'Aporte del propietario'
                  : kind == 'repayment'
                  ? 'Devolver al propietario'
                  : 'Registrar gasto',
            ),
            content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (request != null)
                      const Text(
                        'Intento pendiente: reintenta los mismos datos para confirmar sin duplicar.',
                      ),
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: taxi,
                      decoration: const InputDecoration(labelText: 'Taxi'),
                      items: rows('summaries')
                          .map(
                            (t) => DropdownMenuItem<String>(
                              value: t['id'],
                              child: Text(t['plate']),
                            ),
                          )
                          .toList(),
                      onChanged: saving || request != null || due != null
                          ? null
                          : (v) => update(() => taxi = v!),
                    ),
                    TextField(
                      controller: amount,
                      enabled:
                          !saving &&
                          request == null &&
                          (due?['amount'] == null),
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: template
                            ? 'Valor COP (opcional)'
                            : 'Valor COP, sin puntos',
                      ),
                    ),
                    TextField(
                      controller: note,
                      enabled: !saving && request == null,
                      maxLength: template ? 120 : 300,
                      decoration: InputDecoration(
                        labelText: template
                            ? 'Nombre de obligación'
                            : 'Descripción / nota',
                      ),
                    ),
                    if (kind == 'expense' || template)
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: category,
                        decoration: const InputDecoration(
                          labelText: 'Categoría',
                        ),
                        items: categories.entries
                            .map(
                              (e) => DropdownMenuItem(
                                value: e.key,
                                child: Text(e.value),
                              ),
                            )
                            .toList(),
                        onChanged: saving || request != null || due != null
                            ? null
                            : (v) => update(() => category = v!),
                      ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        template
                            ? 'Primer vencimiento'
                            : 'Fecha del movimiento',
                      ),
                      subtitle: Text(_date(dateKey(day))),
                      trailing: const Icon(Icons.calendar_month),
                      onTap: saving || request != null
                          ? null
                          : () async {
                              final d = await showDatePicker(
                                context: context,
                                initialDate: day,
                                firstDate: DateTime(2000),
                                lastDate: template
                                    ? DateTime(2100)
                                    : bogotaToday(),
                              );
                              if (d != null) update(() => day = d);
                            },
                    ),
                    if (template)
                      DropdownButtonFormField<int>(
                        isExpanded: true,
                        initialValue: every,
                        decoration: const InputDecoration(
                          labelText: 'Repetición',
                        ),
                        items: const [
                          DropdownMenuItem(value: 0, child: Text('Una vez')),
                          DropdownMenuItem(value: 1, child: Text('Mensual')),
                          DropdownMenuItem(value: 3, child: Text('Trimestral')),
                          DropdownMenuItem(value: 6, child: Text('Semestral')),
                          DropdownMenuItem(value: 12, child: Text('Anual')),
                        ],
                        onChanged: saving || request != null
                            ? null
                            : (v) => update(() => every = v!),
                      ),
                    if (!template)
                      const Text(
                        'Se registra en este taxi. Los aportes del propietario no son utilidad. No se admiten fondos o deuda del propietario negativos.',
                      ),
                    if (formError != null)
                      Text(
                        formError!,
                        style: const TextStyle(color: Colors.red),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => Navigator.pop(dialog),
                child: const Text('Cerrar'),
              ),
              FilledButton(
                onPressed: saving
                    ? null
                    : () async {
                        final value = int.tryParse(amount.text);
                        if (note.text.trim().length < 2 ||
                            (!template && (value == null || value <= 0)) ||
                            (template &&
                                amount.text.isNotEmpty &&
                                (value == null || value <= 0))) {
                          update(
                            () => formError = 'Completa la descripción y un valor positivo en pesos enteros.',
                          );
                          return;
                        }
                        request ??= repo.request(
                          template
                              ? 'create_finance_template'
                              : 'record_finance',
                          template
                              ? {
                                  'p_taxi': taxi,
                                  'p_title': note.text.trim(),
                                  'p_category': category,
                                  'p_amount': value,
                                  'p_first': dateKey(day),
                                  'p_every': every,
                                }
                              : {
                                  'p_taxi': taxi,
                                  'p_kind': kind,
                                  'p_amount': value,
                                  'p_day': dateKey(day),
                                  'p_category': category,
                                  'p_note': note.text.trim(),
                                  'p_due': due?['id'],
                                },
                        );
                        update(() {
                          saving = true;
                          formError = null;
                        });
                        try {
                          await repo.submit(request!);
                          if (dialog.mounted) Navigator.pop(dialog);
                        } catch (e) {
                          if (e is PaymentRejected) request = null;
                          if (context.mounted) {
                            update(() => formError = message(e));
                          }
                        } finally {
                          if (context.mounted) update(() => saving = false);
                        }
                      },
                child: Text(saving ? 'Confirmando…' : 'Guardar'),
              ),
            ],
          ),
        ),
      ),
    );
    // Controllers remain alive through the dialog's exit transition.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    amount.dispose();
    note.dispose();
    if (mounted) await load();
  }

  List<Widget> summary() => [
    Text('Resumen mensual', style: Theme.of(context).textTheme.headlineSmall),
    Row(
      children: [
        IconButton(
          tooltip: 'Mes anterior',
          onPressed: () => setMonth(-1),
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(
          child: Text(
            DateFormat('MMMM yyyy', 'es_CO').format(month),
            textAlign: TextAlign.center,
          ),
        ),
        IconButton(
          tooltip: 'Mes siguiente',
          onPressed:
              month.year == bogotaToday().year &&
                  month.month == bogotaToday().month
              ? null
              : () => setMonth(1),
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    ),
    const Text(
      'Ingresos y gastos del mes. Fondo y deuda del propietario al cierre del mes (hoy para el mes actual). Saldos sin usar pasan al mes siguiente. Cuentas por cobrar a conductores: saldo actual, generado desde la pantalla principal.',
    ),
    for (final t in rows('summaries'))
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t['plate'], style: Theme.of(context).textTheme.titleLarge),
              if (t['opening_initialized'] == true)
                Text(
                  'Inicio ${_date(t['opened_on'])}: efectivo ${_cop(t['opening_cash'])} · deuda propietario ${_cop(t['opening_owner_debt'])}',
                )
              else if (t['can_initialize'] == true) ...[
                const Text(
                  'Sin saldos iniciales: efectivo y deuda comienzan en cero.',
                ),
                OutlinedButton(
                  onPressed: pending != null ? null : () => opening(t),
                  child: const Text('Configurar saldos iniciales'),
                ),
              ] else if (t.containsKey('can_initialize'))
                const Text(
                  'Saldos iniciales en cero. Configuración cerrada por movimientos existentes.',
                ),
              Text('Ingresos cobrados: ${_cop(t['income'])}'),
              Text('Gastos: ${_cop(t['expenses'])}'),
              Text(
                'Resultado operativo: ${_cop((t['income'] as num) - (t['expenses'] as num))}',
              ),
              const Divider(),
              Text('Fondo disponible: ${_cop(t['fund'])}'),
              Text('Por cobrar a conductores (hoy): ${_cop(t['driver_debt'])}'),
              Text('Deuda con propietario: ${_cop(t['owner_debt'])}'),
            ],
          ),
        ),
      ),
  ];
  Future<void> setMonth(int delta) async {
    month = DateTime(month.year, month.month + delta);
    await load();
  }

  List<Widget> movements() => [
    Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.icon(
          onPressed: pending != null ? null : () => entry(),
          icon: const Icon(Icons.receipt_long),
          label: const Text('Gasto'),
        ),
        OutlinedButton(
          onPressed: pending != null ? null : () => entry(kind: 'advance'),
          child: const Text('Aporte propietario'),
        ),
        OutlinedButton(
          onPressed: pending != null ? null : () => entry(kind: 'repayment'),
          child: const Text('Devolución'),
        ),
      ],
    ),
    Text(
      'Movimientos · ${DateFormat('MMMM yyyy', 'es_CO').format(month)}',
      style: Theme.of(context).textTheme.titleLarge,
    ),
    const Text(
      'El mes se selecciona en Resumen. Cada taxi conserva su propio fondo y deuda.',
    ),
    for (final e in rows('entries'))
      Card(
        child: ListTile(
          title: Text('${taxiName(e['taxi_id'])} · ${_cop(e['amount'])}'),
          subtitle: Text(
            '${_date(e['day'])} · ${e['kind'] == 'advance'
                ? 'Aporte propietario'
                : e['kind'] == 'repayment'
                ? 'Devolución'
                : categories[e['category']]}\n${e['note']}',
          ),
        ),
      ),
    if (rows('entries').isEmpty)
      const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'Sin movimientos en este mes. Los cobros de conductores se conservan en Pagos.',
        ),
      ),
  ];
  List<Widget> obligations() => [
    Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.icon(
        onPressed: pending != null ? null : () => entry(template: true),
        icon: const Icon(Icons.event),
        label: const Text('Nueva obligación'),
      ),
    ),
    const Text(
      'Administración, SOAT, técnico-mecánica, seguros y otros. Repetir crea vencimientos, nunca gastos automáticos. Próximos: hasta 30 días.',
    ),
    for (final d in rows('dues'))
      Card(
        child: ListTile(
          title: Text('${taxiName(d['taxi_id'])} · ${d['title']}'),
          subtitle: Text(
            '${_date(d['due_on'])} · ${d['payment_id'] != null
                ? 'Pagada'
                : DateTime.parse(d['due_on']).isBefore(bogotaToday())
                ? 'VENCIDA'
                : DateTime.parse(d['due_on']).difference(bogotaToday()).inDays <= 30
                ? 'PRÓXIMA'
                : 'Programada'} · ${d['amount'] == null ? 'Valor por definir' : _cop(d['amount'])}',
          ),
          trailing: d['payment_id'] != null
              ? const Icon(Icons.check_circle_outline)
              : TextButton(
                  onPressed: pending != null ? null : () => entry(due: d),
                  child: const Text('Pagar'),
                ),
        ),
      ),
    if (rows('dues').isEmpty)
      const Padding(
        padding: EdgeInsets.all(16),
        child: Text('Sin obligaciones registradas.'),
      ),
  ];
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Finanzas'),
      actions: [
        IconButton(
          tooltip: 'Actualizar',
          onPressed: busy ? null : load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: busy
        ? const Center(child: CircularProgressIndicator())
        : error != null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(error!),
                  FilledButton(
                    onPressed: load,
                    child: const Text('Reintentar'),
                  ),
                ],
              ),
            ),
          )
        : RefreshIndicator(
            onRefresh: load,
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 850),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (pending != null)
                      Card(
                        child: ListTile(
                          title: const Text('Operación pendiente de confirmar'),
                          subtitle: const Text(
                            'No crees otra operación para sustituirla. Reintenta para comprobar su resultado.',
                          ),
                          trailing: TextButton(
                            onPressed: retry,
                            child: const Text('Confirmar'),
                          ),
                        ),
                      ),
                    ...switch (tab) {
                      0 => summary(),
                      1 => movements(),
                      _ => obligations(),
                    },
                  ],
                ),
              ),
            ),
          ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: tab,
      onDestinationSelected: (v) => setState(() => tab = v),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.account_balance_wallet_outlined),
          label: 'Resumen / fondos',
        ),
        NavigationDestination(
          icon: Icon(Icons.receipt_long),
          label: 'Movimientos',
        ),
        NavigationDestination(
          icon: Icon(Icons.event_note),
          label: 'Vencimientos',
        ),
      ],
    ),
  );
}
