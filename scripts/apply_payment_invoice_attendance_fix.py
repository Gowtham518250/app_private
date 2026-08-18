from pathlib import Path


def replace_once(path, old, new):
    p = Path(path)
    s = p.read_text(encoding='utf-8')
    if new in s:
        return False
    if old not in s:
        raise SystemExit(f'Expected source block not found in {path}')
    p.write_text(s.replace(old, new, 1), encoding='utf-8')
    return True

replace_once(
    'lib/dashboard_page.dart',
    """    _paymentSubscription = PaymentDetectionService().onPaymentDetected.listen((\n      event,\n    ) {\n      if (mounted) {\n        final activity =\n            'Payment: ₹${event.amount.toStringAsFixed(0)} via ${event.appDisplayName}';\n        _addToActivityFeed(activity);\n        _showRealtimeNotification('Payment Received', activity, true);\n        try {\n          context.read<PaymentStateNotifier>().addPayment(event);\n        } catch (e) {\n          if (kDebugMode) debugPrint('Provider error: $e');\n        }\n      }\n    });\n""",
    """    _paymentSubscription = PaymentDetectionService().onPaymentDetected.listen((\n      event,\n    ) {\n      if (mounted) {\n        final activity =\n            'Payment: ₹${event.amount.toStringAsFixed(0)} via ${event.appDisplayName}';\n        _addToActivityFeed(activity);\n        _showRealtimeNotification('Payment Received', activity, true);\n        try {\n          context.read<PaymentStateNotifier>().addPayment(event);\n        } catch (e) {\n          if (kDebugMode) debugPrint('Provider error: $e');\n        }\n      }\n\n      // Financial state must not depend on the notification UI. Reconcile the\n      // detected payment against the canonical local invoice ledger and queue\n      // the exact new paid amount for backend persistence. This also handles\n      // PARTIAL payments (the old detector only auto-settled exact full dues).\n      unawaited(_reconcileDetectedPaymentToInvoice(event));\n    });\n"""
)

dashboard_method = r'''  Future<void> _reconcileDetectedPaymentToInvoice(dynamic event) async {
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

      // Never guess between multiple invoices with the same payable amount.
      if (candidates.length != 1) return;
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
      if (mounted) _addToActivityFeed(newStatus == 'PAID'
          ? 'Invoice $invoiceNumber marked PAID (₹${newPaid.toStringAsFixed(2)})'
          : 'Invoice $invoiceNumber updated PARTIAL (₹${newPaid.toStringAsFixed(2)} / ₹${total.toStringAsFixed(2)})');
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ Detected payment → invoice reconciliation failed: $e');
        debugPrint(st.toString());
      }
    }
  }

'''
p = Path('lib/dashboard_page.dart')
s = p.read_text(encoding='utf-8')
if '_reconcileDetectedPaymentToInvoice' not in s:
    marker = '  Future<void> _checkPermissions({bool showReminderIfMissing = true}) async {'
    if marker not in s: raise SystemExit('Dashboard permission marker not found')
    p.write_text(s.replace(marker, dashboard_method + marker, 1), encoding='utf-8')

p = Path('lib/payment_detection_service.dart')
s = p.read_text(encoding='utf-8')
if "'APGB'" not in s:
    old = "r'|DCB|Bandhan|IDFCB|HSBC|SCB|Standard|Citi|DLB|ICICI|IOB|UBI|BoB|CBI)\\b',"
    new = "r'|DCB|Bandhan|IDFCB|HSBC|SCB|Standard|Citi|DLB|ICICI|IOB|UBI|BoB|CBI|APGB|Andhra\\s+Pradesh\\s+Grameena\\s+Bank|Andhra\\s+Pradesh\\s+Gramin\\s+Bank)\\b',"
    if old in s: s = s.replace(old, new, 1)
    s = s.replace("'HDFCBK', 'HDFCBN', 'SBIINB'", "'HDFCBK', 'HDFCBN', 'APGB', 'SBIINB'", 1)
p.write_text(s, encoding='utf-8')

p = Path('lib/sync_service.dart')
s = p.read_text(encoding='utf-8')
old = """      final res = await ApiClient.postJson(\n        '${ApiClient.checkIn}?employee_id=$workerId',\n        {},\n        headers: {'Authorization': 'Bearer $token'}\n      );\n"""
new = """      // Backend guard: suppress duplicate check-in POSTs for the same employee/day.\n      try {\n        final today = DateTime.now().toIso8601String().split('T').first;\n        final existing = await ApiClient.getJson(\n          '${ApiClient.attendancePrefix}/date/$today?employee_id=$workerId',\n          headers: {'Authorization': 'Bearer $token'},\n        ).timeout(const Duration(seconds: 8));\n        if (existing.statusCode == 200) {\n          final decoded = jsonDecode(existing.body);\n          final records = decoded is List ? decoded : (decoded is Map && decoded['records'] is List ? decoded['records'] as List : const []);\n          final alreadyRecorded = records.any((raw) {\n            if (raw is! Map) return false;\n            final employee = raw['employee_id'] ?? raw['worker_id'];\n            return employee?.toString() == workerId.toString();\n          });\n          if (alreadyRecorded) {\n            if (kDebugMode) debugPrint('✅ Attendance already exists for $workerId today; duplicate check-in suppressed');\n            return true;\n          }\n        }\n      } catch (e) {\n        if (kDebugMode) debugPrint('⚠️ Attendance preflight failed; continuing with authenticated check-in: $e');\n      }\n\n      final res = await ApiClient.postJson(\n        '${ApiClient.checkIn}?employee_id=$workerId',\n        {},\n        headers: {'Authorization': 'Bearer $token'}\n      );\n"""
if 'duplicate check-in suppressed' not in s and old in s: s = s.replace(old, new, 1)
old2 = """              if (action == 'create_purchase_order' || action == 'update_purchase_order_status') {\n                SyncService.triggerDashboardRefresh();\n              }\n"""
new2 = """              if (action == 'create_purchase_order' ||\n                  action == 'update_purchase_order_status' ||\n                  action == 'update_payment' ||\n                  action == 'update_invoice_payment' ||\n                  action == 'update_invoice_paid' ||\n                  action == 'update_invoice_unpaid') {\n                SyncService.triggerDashboardRefresh();\n              }\n"""
if "action == 'update_invoice_paid'" not in s and old2 in s: s = s.replace(old2, new2, 1)
p.write_text(s, encoding='utf-8')
