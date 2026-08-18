from pathlib import Path

p = Path('lib/dashboard_page.dart')
s = p.read_text(encoding='utf-8')
if '  Future<void> _reconcileDetectedPaymentToInvoice' in s:
    print('Invoice reconciliation method already present')
    raise SystemExit(0)

method = r'''  Future<void> _reconcileDetectedPaymentToInvoice(dynamic event) async {
    try {
      final amount = (event.amount as num?)?.toDouble() ?? 0.0;
      if (amount <= 0) return;
      final rawInvoices = await LocalStorageService.loadLocalInvoices();
      if (rawInvoices.isEmpty) return;

      String normalize(dynamic value) => value?.toString().trim().toLowerCase() ?? '';
      double money(dynamic value) {
        if (value is num) return value.toDouble();
        return double.tryParse(value?.toString() ?? '') ?? 0.0;
      }
      String recordId(Map<String, dynamic> row) {
        for (final key in const ['invoice_id','sale_id','invoice_number','invoiceId','backend_id','id']) {
          final value = normalize(row[key]);
          if (value.isNotEmpty && value != '0' && value != 'null') return value;
        }
        return '';
      }

      final saleId = normalize(event.saleId);
      final payer = normalize(event.payerName);
      final candidates = <Map<String, dynamic>>[];
      for (final raw in rawInvoices) {
        if (raw is! Map) continue;
        final row = Map<String, dynamic>.from(raw);
        final total = money(row['total_amount'] ?? row['total'] ?? row['invoice_total'] ?? row['grand_total']);
        final paid = money(row['paid_amount'] ?? row['amount_paid'] ?? row['paid']);
        final due = (total - paid).clamp(0.0, double.infinity);
        if (total <= 0 || due < 0.01 || amount > due + 0.01) continue;
        if (saleId.isNotEmpty && recordId(row) == saleId) {
          candidates..clear()..add(row);
          break;
        }
        if (payer.isNotEmpty) {
          final customer = normalize(row['customer_name'] ?? row['name']);
          if (customer.isNotEmpty && !customer.contains(payer) && !payer.contains(customer)) continue;
        }
        candidates.add(row);
      }

      if (candidates.length != 1) {
        if (kDebugMode && candidates.length > 1) {
          debugPrint('⚠️ Payment ₹$amount matched ${candidates.length} invoices; manual confirmation required.');
        }
        return;
      }

      final target = candidates.first;
      final total = money(target['total_amount'] ?? target['total'] ?? target['invoice_total'] ?? target['grand_total']);
      final oldPaid = money(target['paid_amount'] ?? target['amount_paid'] ?? target['paid']);
      final newPaid = (oldPaid + amount).clamp(0.0, total);
      final newStatus = newPaid >= total - 0.01 ? 'PAID' : 'PARTIAL';
      final invoiceNumber = (target['invoice_number'] ?? target['sale_id'] ?? target['invoice_id'] ?? target['id'])?.toString().trim() ?? '';
      if (invoiceNumber.isEmpty) return;

      final updated = <String, dynamic>{
        ...target,
        'paid_amount': newPaid,
        'amount_paid': newPaid,
        'payment_status': newStatus,
        'status': newStatus,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'last_payment_amount': amount,
        'last_payment_source': event.detectionSource?.toString() ?? 'payment_detection',
        if (event.referenceId != null) 'last_payment_utr': event.referenceId.toString(),
      };
      final targetId = recordId(target);
      final updatedInvoices = rawInvoices.map((raw) {
        if (raw is! Map) return raw;
        final row = Map<String, dynamic>.from(raw);
        return recordId(row) == targetId ? updated : raw;
      }).toList();
      await LocalStorageService.saveLocalInvoices(updatedInvoices);

      await SyncQueueManager.enqueue('update_invoice_paid', {
        'invoice_number': invoiceNumber,
        'payment_status': newStatus,
        'paid_amount': newPaid,
        'amount': amount,
        'idempotency_key': 'detected_${targetId}_${event.fingerprint}',
      });
      await SyncService.updateSalePayment(invoiceNumber, newStatus, newPaid);
      await SyncService.processQueueSafe();
      SyncService.triggerDashboardRefresh();
      if (mounted) {
        _addToActivityFeed(newStatus == 'PAID'
            ? 'Invoice $invoiceNumber marked PAID (₹${newPaid.toStringAsFixed(2)})'
            : 'Invoice $invoiceNumber updated PARTIAL (₹${newPaid.toStringAsFixed(2)} / ₹${total.toStringAsFixed(2)})');
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ Detected payment → invoice reconciliation failed: $e');
        debugPrint(st.toString());
      }
    }
  }

'''
marker = '  Future<void> _checkPermissions({bool showReminderIfMissing = true}) async {'
if marker not in s:
    raise SystemExit('Dashboard permission marker not found')
s = s.replace(marker, method + marker, 1)
p.write_text(s, encoding='utf-8')
print('Inserted payment/invoice reconciliation method')
