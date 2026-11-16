import 'package:material_ui/material_ui.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'domain.dart';
import 'repository.dart';
import 'finance_page.dart';
import 'cancel_payment_button.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const url = String.fromEnvironment('SUPABASE_URL');
  const key = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
  String? problem;
  if (!url.startsWith('https://') || !key.startsWith('sb_publishable_')) {
    problem = 'Falta la configuración pública de Supabase. Inicia con --dart-define-from-file=config/supabase.json.';
  } else {
    try {
      await Supabase.initialize(url: url, publishableKey: key);
    } catch (_) {
      problem =
          'No se pudo iniciar la conexión. Revisa internet y la configuración.';
    }
  }
  runApp(TaxiApp(problem: problem));
}

class TaxiApp extends StatelessWidget {
  const TaxiApp({super.key, this.problem});
  final String? problem;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'JTaxiControl',
    debugShowCheckedModeBanner: false,
    locale: const Locale('es', 'CO'),
    supportedLocales: const [Locale('es', 'CO')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff145b48)),
      useMaterial3: true,
    ),
    home: problem != null
        ? Scaffold(
            appBar: AppBar(title: const Text('JTaxiControl')),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(problem!),
              ),
            ),
          )
        : const AuthGate(),
  );
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});
  @override
  Widget build(BuildContext context) {
    final auth = Supabase.instance.client.auth;
    return StreamBuilder<AuthState>(
      stream: auth.onAuthStateChange,
      builder: (context, snapshot) => auth.currentSession == null
          ? const LoginPage()
          : HomePage(key: ValueKey(auth.currentUser!.id)),
    );
  }
}

String friendly(Object error) {
  if (error is PaymentRejected) return error.message;
  if (error is AuthException) {
    return 'No fue posible iniciar sesión. Comprueba el correo, la contraseña y la conexión.';
  }
  if (error is PostgrestException && error.code == 'P0001') {
    return error.message;
  }
  return 'No se pudo confirmar la operación. Revisa internet y reintenta. Si es un pago, conserva el mismo intento. Si persiste, comprueba la instalación y autorización de la base de datos.';
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginState();
}

class _LoginState extends State<LoginPage> {
  final email = TextEditingController(), password = TextEditingController();
  bool busy = false;
  String? error;
  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> login() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await Supabase.instance.client.auth.signInWithPassword(
        email: email.text.trim(),
        password: password.text,
      );
    } catch (e) {
      if (mounted) setState(() => error = friendly(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.local_taxi, size: 56),
              const SizedBox(height: 16),
              Text(
                'JTaxiControl',
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const Text('Acceso privado · Requiere internet'),
              const SizedBox(height: 24),
              TextField(
                controller: email,
                enabled: !busy,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.username],
                decoration: const InputDecoration(labelText: 'Correo'),
              ),
              TextField(
                controller: password,
                enabled: !busy,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                decoration: const InputDecoration(labelText: 'Contraseña'),
                onSubmitted: (_) {
                  if (!busy) login();
                },
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    error!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: busy ? null : login,
                child: Text(busy ? 'Ingresando…' : 'Ingresar'),
              ),
              const Text('Solo cuentas autorizadas. No hay registro público.'),
            ],
          ),
        ),
      ),
    ),
  );
}

final money = NumberFormat.currency(
  locale: 'es_CO',
  symbol: r'$',
  decimalDigits: 0,
);
String cop(Object? n) => money.format(n ?? 0);
String dayLabel(Object? d) =>
    DateFormat('dd/MM/yyyy').format(DateTime.parse(d.toString()));

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomeState();
}

class _HomeState extends State<HomePage> {
  late final repo = TaxiRepository(Supabase.instance.client);
  bool busy = true;
  String? error;
  bool ready = false;
  int tab = 0;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    setState(() {
      busy = true;
      error = null;
      ready = false;
    });
    try {
      await repo.load();
      if (mounted) setState(() => ready = true);
    } catch (e) {
      if (mounted) setState(() => error = friendly(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> form(
    String title,
    List<Widget> Function(StateSetter) fields,
    Future<void> Function() submit, {
    bool Function()? valid,
  }) async {
    String? localError;
    bool saving = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialog) => PopScope(
          canPop: !saving,
          child: AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ...fields(setDialog),
                    if (localError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          localError!,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => Navigator.pop(dialogContext),
                child: const Text('Cerrar'),
              ),
              FilledButton(
                onPressed: saving
                    ? null
                    : () async {
                        if (valid != null && !valid()) {
                          setDialog(
                            () => localError =
                                'Revisa los campos y los valores indicados.',
                          );
                          return;
                        }
                        setDialog(() {
                          saving = true;
                          localError = null;
                        });
                        try {
                          await submit();
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext);
                          }
                        } catch (e) {
                          if (context.mounted) {
                            setDialog(() => localError = friendly(e));
                          }
                        } finally {
                          if (context.mounted) setDialog(() => saving = false);
                        }
                      },
                child: Text(saving ? 'Confirmando…' : 'Guardar'),
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted) await refresh();
  }

  TextField field(
    TextEditingController c,
    String label, {
    bool enabled = true,
    bool numeric = false,
  }) => TextField(
    controller: c,
    enabled: enabled,
    keyboardType: numeric ? TextInputType.number : TextInputType.text,
    decoration: InputDecoration(labelText: label),
  );
  Widget dateField(
    String label,
    DateTime value,
    void Function(DateTime) change, {
    DateTime? first,
  }) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(label),
    subtitle: Text(DateFormat('dd/MM/yyyy').format(value)),
    trailing: const Icon(Icons.calendar_month),
    onTap: () async {
      final d = await showDatePicker(
        context: context,
        initialDate: value,
        firstDate: first ?? DateTime(2020),
        lastDate: DateTime(bogotaToday().year + 2),
      );
      if (d != null) change(d);
    },
  );
  Widget daysField(Set<int> days, StateSetter update) => Wrap(
    spacing: 4,
    children: List.generate(
      7,
      (i) => FilterChip(
        label: Text(['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'][i]),
        selected: days.contains(i + 1),
        onSelected: (v) => update(() {
          v ? days.add(i + 1) : days.remove(i + 1);
        }),
      ),
    ),
  );
  Future<void> taxi(int slot, {String plate = ''}) async {
    final c = TextEditingController(text: plate);
    await form(
      'Taxi $slot',
      (_) => [field(c, 'Placa')],
      () => repo.rpc('save_taxi', {'p_slot': slot, 'p_plate': c.text.trim()}),
      valid: () => c.text.trim().length >= 3,
    );
    c.dispose();
  }

  Future<void> driver([DbRecord? row]) async {
    final n = TextEditingController(text: row?['name']),
        p = TextEditingController(text: row?['phone']);
    await form(
      row == null ? 'Nuevo conductor' : 'Editar conductor',
      (_) => [field(n, 'Nombre'), field(p, 'Teléfono (opcional)')],
      () => repo.rpc('save_driver', {
        'p_id': row?['id'],
        'p_name': n.text.trim(),
        'p_phone': p.text.trim(),
      }),
      valid: () => n.text.trim().length >= 2,
    );
    n.dispose();
    p.dispose();
  }

  Future<void> assign(DbRecord taxi) async {
    if (repo.rows('drivers').isEmpty) {
      await driver();
      return;
    }
    String selected = repo.rows('drivers').first['id'], mode = 'fixed';
    final hasCurrent = repo
        .rows('assignments')
        .any((a) => a['taxi_id'] == taxi['id'] && a['ends_on'] == null);
    DateTime start = bogotaToday().add(Duration(days: hasCurrent ? 1 : 0));
    final amount = TextEditingController();
    final days = <int>{1, 2, 3, 4, 5, 6};
    await form(
      'Asignar conductor',
      (s) => [
        const Text(
          'El cambio conserva las deudas del conductor anterior. Los reemplazos comienzan mañana o después.',
        ),
        DropdownButtonFormField<String>(
          initialValue: selected,
          decoration: const InputDecoration(labelText: 'Conductor'),
          items: repo
              .rows('drivers')
              .map(
                (d) => DropdownMenuItem<String>(
                  value: d['id'],
                  child: Text(d['name']),
                ),
              )
              .toList(),
          onChanged: (v) => s(() => selected = v!),
        ),
        DropdownButtonFormField<String>(
          initialValue: mode,
          decoration: const InputDecoration(labelText: 'Modalidad'),
          items: const [
            DropdownMenuItem(value: 'fixed', child: Text('Cuota fija')),
            DropdownMenuItem(
              value: 'flexible',
              child: Text('Aportes flexibles, sin deuda'),
            ),
          ],
          onChanged: (v) => s(() => mode = v!),
        ),
        dateField(
          'Inicio',
          start,
          (d) => s(() => start = d),
          first: bogotaToday().add(Duration(days: hasCurrent ? 1 : 0)),
        ),
        if (mode == 'fixed') ...[
          field(amount, 'Cuota diaria en pesos enteros', numeric: true),
          daysField(days, s),
        ],
      ],
      () => repo.rpc('assign_driver', {
        'p_taxi': taxi['id'],
        'p_driver': selected,
        'p_start': dateKey(start),
        'p_mode': mode,
        'p_amount': mode == 'fixed' ? int.parse(amount.text) : 0,
        'p_days': days.toList()..sort(),
      }),
      valid: () =>
          days.isNotEmpty &&
          (mode == 'flexible' || (int.tryParse(amount.text) ?? 0) > 0),
    );
    amount.dispose();
  }

  Future<void> quota(DbRecord a) async {
    var effective = bogotaToday().add(const Duration(days: 1));
    final amount = TextEditingController();
    final days = <int>{1, 2, 3, 4, 5, 6};
    await form(
      'Cuota y calendario futuros',
      (s) => [
        const Text(
          'Las obligaciones ya generadas conservan su valor. Selecciona todos los días de cobro.',
        ),
        field(amount, 'Nueva cuota COP', numeric: true),
        dateField(
          'Vigente desde',
          effective,
          (d) => s(() => effective = d),
          first: effective,
        ),
        daysField(days, s),
      ],
      () => repo.rpc('change_quota', {
        'p_assignment': a['id'],
        'p_effective': dateKey(effective),
        'p_amount': int.parse(amount.text),
        'p_days': days.toList()..sort(),
      }),
      valid: () => days.isNotEmpty && (int.tryParse(amount.text) ?? 0) > 0,
    );
    amount.dispose();
  }

  Future<void> exempt(DbRecord a) async {
    var day = bogotaToday();
    final reason = TextEditingController();
    await form(
      'Eximir una fecha',
      (s) => [
        dateField('Día exento', day, (d) => s(() => day = d)),
        field(reason, 'Motivo: descanso, pico y placa, reparación…'),
        const Text(
          'No admite fechas con abonos. La cuota original queda conservada en el historial.',
        ),
      ],
      () => repo.rpc('exempt_day', {
        'p_assignment': a['id'],
        'p_day': dateKey(day),
        'p_reason': reason.text.trim(),
      }),
      valid: () => reason.text.trim().length >= 2,
    );
    reason.dispose();
  }

  String assignmentLabel(DbRecord a) =>
      '${repo.label('drivers', a['driver_id'], 'name')} · ${repo.label('taxis', a['taxi_id'], 'plate')}';
  bool paymentOpen = false;
  Future<void> payment(DbRecord selected) async {
    if (paymentOpen) return;
    paymentOpen = true;
    try {
      await paymentDialog(selected);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendly(e))));
      }
    } finally {
      paymentOpen = false;
    }
  }

  Future<void> paymentDialog(DbRecord selected) async {
    DbRecord? request = await repo.pending();
    if (!mounted) return;
    final a = request == null
        ? selected
        : repo
              .rows('assignments')
              .firstWhere((a) => a['id'] == request!['p_assignment']);
    final amount = TextEditingController(text: request?['p_amount'].toString()),
        note = TextEditingController(text: request?['p_note']);
    var day = request == null
        ? bogotaToday()
        : DateTime.parse(request['p_day']);
    await form(
      'Registrar / confirmar pago',
      (s) => [
        Text(
          assignmentLabel(a),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Text(
          'Deuda: ${cop(assignmentDebt(a['id'], repo.rows('obligations'), repo.rows('allocations')))}',
        ),
        if (request != null)
          const Text(
            'Hay un intento pendiente. Sus datos están bloqueados para reintentar sin duplicarlo, incluso después de cerrar la app.',
          ),
        field(
          amount,
          'Valor COP (sin puntos)',
          numeric: true,
          enabled: request == null,
        ),
        field(note, 'Nota (opcional)', enabled: request == null),
        if (request == null)
          dateField('Fecha de recepción', day, (d) => s(() => day = d))
        else
          Text('Fecha: ${dayLabel(request!['p_day'])}'),
        const Text(
          'Los abonos cubren primero las cuotas más antiguas de esta asignación. No se admiten anticipos de cuota fija.',
        ),
      ],
      () async {
        request ??= repo.payment(
          a['id'],
          int.parse(amount.text),
          dateKey(day),
          note.text.trim(),
        );
        // Preserve one request across every ambiguous network result.
        try {
          await repo.pay(request!);
        } on PaymentRejected {
          request = null;
          rethrow;
        }
      },
      valid: () => (int.tryParse(amount.text) ?? 0) > 0,
    );
    amount.dispose();
    note.dispose();
  }

  List<Widget> taxisView() => [
    Text('Tus taxis', style: Theme.of(context).textTheme.headlineMedium),
    const Text('Cuentas independientes · Desliza para actualizar'),
    for (var slot = 1; slot <= 2; slot++) ...[
      const SizedBox(height: 12),
      if (!repo.rows('taxis').any((t) => t['slot'] == slot))
        Card(
          child: ListTile(
            title: Text('Taxi $slot sin configurar'),
            trailing: FilledButton(
              onPressed: () => taxi(slot),
              child: const Text('Registrar'),
            ),
          ),
        )
      else
        ...repo
            .rows('taxis')
            .where((t) => t['slot'] == slot)
            .map(
              (t) => Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              t['plate'],
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Editar placa',
                            onPressed: () => taxi(slot, plate: t['plate']),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                        ],
                      ),
                      ...repo
                          .rows('assignments')
                          .where(
                            (a) =>
                                a['taxi_id'] == t['id'] &&
                                a['starts_on'].compareTo(
                                      dateKey(bogotaToday()),
                                    ) <=
                                    0 &&
                                (a['ends_on'] == null ||
                                    a['ends_on'].compareTo(
                                          dateKey(bogotaToday()),
                                        ) >=
                                        0),
                          )
                          .map(
                            (a) => Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Actual: ${repo.label('drivers', a['driver_id'], 'name')}',
                                ),
                                Text(
                                  a['mode'] == 'fixed' ? 'Cuota fija' : 'Aportes flexibles · sin deuda automática',
                                ),
                              ],
                            ),
                          ),
                      const SizedBox(height: 8),
                      Text(
                        'Deuda total histórica: ${cop(repo.rows('assignments').where((a) => a['taxi_id'] == t['id']).fold<int>(0, (s, a) => s + assignmentDebt(a['id'], repo.rows('obligations'), repo.rows('allocations'))))}',
                      ),
                      OutlinedButton.icon(
                        onPressed: () => assign(t),
                        icon: const Icon(Icons.person_add_alt),
                        label: const Text('Asignar / cambiar conductor'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    ],
  ];
  List<Widget> driversView() => [
    Row(
      children: [
        Expanded(
          child: Text(
            'Conductores',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
        ),
        IconButton(
          tooltip: 'Nuevo conductor',
          onPressed: () => driver(),
          icon: const Icon(Icons.person_add),
        ),
      ],
    ),
    const Text(
      'Los conductores son registros administrativos, sin cuentas de acceso.',
    ),
    for (final d in repo.rows('drivers'))
      Card(
        child: ListTile(
          title: Text(d['name']),
          subtitle: Text(d['phone']),
          trailing: IconButton(
            tooltip: 'Editar',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => driver(d),
          ),
        ),
      ),
    const SizedBox(height: 16),
    Text(
      'Asignaciones e historial',
      style: Theme.of(context).textTheme.titleLarge,
    ),
    for (final a in repo.rows('assignments')) assignmentCard(a),
  ];
  Widget assignmentCard(DbRecord a) {
    final balance = assignmentDebt(
      a['id'],
      repo.rows('obligations'),
      repo.rows('allocations'),
    );
    final rules =
        repo
            .rows('quota_rules')
            .where((r) => r['assignment_id'] == a['id'])
            .toList()
          ..sort((x, y) => x['effective_on'].compareTo(y['effective_on']));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              assignmentLabel(a),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              '${dayLabel(a['starts_on'])} — ${a['ends_on'] == null ? 'Sin fecha final' : dayLabel(a['ends_on'])}',
            ),
            Text(
              a['starts_on'].compareTo(dateKey(bogotaToday())) > 0
                  ? 'Programada'
                  : a['ends_on'] != null &&
                        a['ends_on'].compareTo(dateKey(bogotaToday())) < 0
                  ? 'Anterior · conserva su deuda'
                  : 'Vigente',
            ),
            Text(
              a['mode'] == 'fixed'
                  ? 'Deuda pendiente: ${cop(balance)}'
                  : 'Aportes flexibles: no genera deuda',
            ),
            for (final r in rules)
              if (a['mode'] == 'fixed')
                Text(
                  '${dayLabel(r['effective_on'])}: ${cop(r['amount'])} · Días ${(r['weekdays'] as List).map((d) => ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'][(d as int) - 1]).join(', ')}',
                ),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: () => payment(a),
                  child: const Text('Pago / reintento'),
                ),
                if (a['mode'] == 'fixed') ...[
                  TextButton(
                    onPressed: () => quota(a),
                    child: const Text('Cambiar cuota'),
                  ),
                  TextButton(
                    onPressed: () => exempt(a),
                    child: const Text('Eximir fecha'),
                  ),
                ],
              ],
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Cuotas y abonos'),
              children: [
                ...repo
                    .rows('obligations')
                    .where((o) => o['assignment_id'] == a['id'])
                    .map(
                      (o) => ListTile(
                        title: Text(
                          '${dayLabel(o['due_on'])} · ${cop(o['amount'])}',
                        ),
                        subtitle: Text(
                          o['exempt_reason'] != null
                              ? 'Exenta: ${o['exempt_reason']}'
                              : 'Pendiente: ${cop(obligationBalance(o, repo.rows('allocations')))}',
                        ),
                      ),
                    ),
                ...repo
                    .rows('exemptions')
                    .where((e) => e['assignment_id'] == a['id'])
                    .map(
                      (e) => ListTile(
                        leading: const Icon(Icons.event_busy),
                        title: Text(dayLabel(e['day'])),
                        subtitle: Text(e['reason']),
                      ),
                    ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> paymentsView() {
    final payments = repo.rows('payments').toList()
      ..sort((a, b) => b['created_at'].compareTo(a['created_at']));
    return [
      Text(
        'Pagos recibidos',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const Text('Cada pago pertenece al conductor y asignación originales.'),
      if (payments.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text('Aún no hay pagos.'),
        ),
      for (final p in payments)
        Card(
          child: ExpansionTile(
            title: Text(
              '${p['cancelled_at'] != null ? 'ANULADO · ' : ''}${cop(p['amount'])} · ${dayLabel(p['paid_on'])}',
            ),
            subtitle: Text(
              '${assignmentLabel(repo.rows('assignments').firstWhere((a) => a['id'] == p['assignment_id']))}\n${p['note']}',
            ),
            children: [
              if (p['cancelled_at'] == null)
                CancelPaymentButton(payment: p, onChanged: refresh)
              else
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'Anulado el ${DateFormat('dd/MM/yyyy HH:mm').format(DateTime.parse(p['cancelled_at']).toUtc().subtract(const Duration(hours: 5)))} (Colombia)\nUsuario: ${p['cancelled_by']}\nMotivo: ${p['cancellation_reason'] == '' ? 'Sin motivo indicado' : p['cancellation_reason']}\nNo suma efectivo ni ingresos. Los abonos siguientes son históricos y ya no reducen deuda.',
                  ),
                ),
              for (final al
                  in repo
                      .rows('allocations')
                      .where((a) => a['payment_id'] == p['id']))
                ListTile(
                  title: Text(
                    '${al['reversed_at'] != null ? 'Abono revertido · ' : ''}Cuota ${dayLabel(repo.rows('obligations').firstWhere((o) => o['id'] == al['obligation_id'])['due_on'])}',
                  ),
                  trailing: Text(cop(al['amount'])),
                ),
            ],
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('JTaxiControl'),
      actions: [
        IconButton(
          tooltip: 'Finanzas',
          icon: const Icon(Icons.account_balance_wallet_outlined),
          onPressed: busy
              ? null
              : () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const FinancePage()),
                ),
        ),
        IconButton(
          tooltip: 'Actualizar',
          onPressed: busy ? null : refresh,
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: 'Cerrar sesión',
          onPressed: busy
              ? null
              : () => Supabase.instance.client.auth.signOut(),
          icon: const Icon(Icons.logout),
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
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: refresh,
                    child: const Text('Reintentar'),
                  ),
                ],
              ),
            ),
          )
        : !ready
        ? const SizedBox.shrink()
        : RefreshIndicator(
            onRefresh: refresh,
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 850),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text(
                        'Requiere internet · Valores en COP · Fechas de Colombia',
                      ),
                    ),
                    ...switch (tab) {
                      0 => taxisView(),
                      1 => driversView(),
                      _ => paymentsView(),
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
        NavigationDestination(icon: Icon(Icons.local_taxi), label: 'Taxis'),
        NavigationDestination(
          icon: Icon(Icons.people_outline),
          label: 'Conductores',
        ),
        NavigationDestination(
          icon: Icon(Icons.payments_outlined),
          label: 'Pagos',
        ),
      ],
    ),
  );
}
