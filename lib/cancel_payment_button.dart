import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'finance_repository.dart';
import 'repository.dart';

class CancelPaymentButton extends StatefulWidget {
  const CancelPaymentButton({
    super.key,
    required this.payment,
    required this.onChanged,
    this.repository,
  });
  final DbRecord payment;
  final Future<void> Function() onChanged;
  final FinanceRepository? repository;
  @override
  State<CancelPaymentButton> createState() => _CancelPaymentState();
}

class _CancelPaymentState extends State<CancelPaymentButton> {
  bool busy = false;
  late final repo =
      widget.repository ?? FinanceRepository(Supabase.instance.client);
  Future<void> cancel() async {
    if (busy) return;
    setState(() => busy = true);
    final reason = TextEditingController();
    try {
      DbRecord? request = await repo.pending();
      if (!mounted) return;
      if (request != null &&
          (request['rpc'] != 'cancel_payment' ||
              request['params']['p_payment'] != widget.payment['id'])) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Confirma primero la operación pendiente en Finanzas o el pago original.',
            ),
          ),
        );
        return;
      }
      reason.text = request?['params']['p_reason'] ?? '';
      bool saving = false;
      String? error;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialog) => StatefulBuilder(
          builder: (context, update) => PopScope(
            canPop: !saving,
            child: AlertDialog(
              title: const Text('¿Anular este pago?'),
              content: SizedBox(
                width: 400,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Valor: ${widget.payment['amount']} COP · Fecha: ${widget.payment['paid_on']}',
                      ),
                      const Text(
                        'El pago quedará en el historial como anulado. Se descontará del efectivo e ingresos y se restaurarán las cuotas que abonó. No se puede deshacer desde la aplicación. Si afecta gastos o devoluciones posteriores, se rechazará.',
                      ),
                      if (request != null)
                        const Text(
                          'Hay un intento pendiente. Confirmar reintenta la misma anulación, sin duplicarla.',
                        ),
                      TextField(
                        controller: reason,
                        enabled: !saving && request == null,
                        maxLength: 300,
                        decoration: const InputDecoration(
                          labelText: 'Motivo (opcional)',
                        ),
                      ),
                      if (error != null)
                        Text(error!, style: const TextStyle(color: Colors.red)),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.pop(dialog),
                  child: const Text('Volver'),
                ),
                FilledButton(
                  onPressed: saving
                      ? null
                      : () async {
                          request ??= repo.request('cancel_payment', {
                            'p_payment': widget.payment['id'],
                            'p_reason': reason.text.trim(),
                          });
                          update(() {
                            saving = true;
                            error = null;
                          });
                          try {
                            await repo.submit(request!);
                            if (dialog.mounted) Navigator.pop(dialog);
                          } catch (e) {
                            if (e is PaymentRejected) request = null;
                            if (context.mounted) {
                              update(
                                () => error = e is PaymentRejected ? e.message : 'No se pudo confirmar. Revisa internet y reintenta esta misma anulación.',
                              );
                            }
                          } finally {
                            if (context.mounted) update(() => saving = false);
                          }
                        },
                  child: Text(saving ? 'Confirmando…' : 'Confirmar anulación'),
                ),
              ],
            ),
          ),
        ),
      );
      if (mounted) await widget.onChanged();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No se pudo consultar el intento pendiente. Revisa internet y vuelve a intentar.',
            ),
          ),
        );
      }
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      reason.dispose();
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: busy ? null : cancel,
    icon: const Icon(Icons.cancel_outlined),
    label: const Text('Anular pago'),
  );
}
