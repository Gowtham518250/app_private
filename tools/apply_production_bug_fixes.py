#!/usr/bin/env python3
"""Apply the three verified production fixes directly to the Flutter source.

Run from repository root:
    python3 tools/apply_production_bug_fixes.py

The script is fail-fast on unknown source layouts, but idempotent when the fix
has already been applied. Modified files receive a .bak backup before being
written.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(path: str, old: str, new: str) -> None:
    p = ROOT / path
    text = p.read_text(encoding="utf-8")
    if old not in text:
        if new in text:
            return
        raise RuntimeError(f"Anchor not found in {path}: {old[:160]!r}")
    backup = p.with_suffix(p.suffix + ".bak")
    if not backup.exists():
        backup.write_text(text, encoding="utf-8")
    p.write_text(text.replace(old, new, 1), encoding="utf-8")


# 1) PAYMENT DETECTION -------------------------------------------------------
replace_once(
    "lib/payment_detection_service.dart",
    '''  static bool isLegitimate(String s) {\n    final t = s.trim();\n    if (!_valid.hasMatch(t) || _digits.hasMatch(t)) return false;\n\n    // DLT-format headers (e.g. "VM-HDFCBK") get checked against the known\n''',
    '''  static bool isLegitimate(String s) {\n    final t = s.trim();\n    if (!_valid.hasMatch(t) || _digits.hasMatch(t)) return false;\n\n    // Normalize Indian DLT sender IDs such as VA-APGB-T to APGB before\n    // checking the trusted bank/entity registry.\n    var entity = t.toUpperCase();\n    final dlt = RegExp(r'^[A-Z]{2}-(.+)$').firstMatch(entity);\n    if (dlt != null) entity = dlt.group(1)!;\n    entity = entity.replaceFirst(RegExp(r'-[A-Z]$'), '');\n    if (_BankSenderRegistry.isKnown(entity)) return true;\n\n    // DLT-format headers (e.g. "VM-HDFCBK") get checked against the known\n''',
)

replace_once(
    "lib/payment_detection_service.dart",
    '''  static bool _isVerifiedBankSender(String? sender) {\n    if (sender == null || sender.isEmpty) return false;\n    var s = sender.toUpperCase().trim();\n    final dlt = RegExp(r'^[A-Z]{2}-(.+)$').firstMatch(s);\n    if (dlt != null) s = dlt.group(1)!;\n    return _BankSenderRegistry.isKnown(s);\n  }\n''',
    '''  static bool _isVerifiedBankSender(String? sender) {\n    if (sender == null || sender.isEmpty) return false;\n    var s = sender.toUpperCase().trim();\n    final dlt = RegExp(r'^[A-Z]{2}-(.+)$').firstMatch(s);\n    if (dlt != null) s = dlt.group(1)!;\n    s = s.replaceFirst(RegExp(r'-[A-Z]$'), '');\n    return _BankSenderRegistry.isKnown(s);\n  }\n''',
)

p = ROOT / "lib/payment_detection_service.dart"
text = p.read_text(encoding="utf-8")
registry_anchor = "  static final _s = <String>{\n"
if registry_anchor not in text:
    raise RuntimeError("Bank sender registry anchor not found")
registry_end = text.find("};", text.index(registry_anchor))
registry_block = text[text.index(registry_anchor):registry_end]
if "'APGB'" not in registry_block:
    backup = p.with_suffix(p.suffix + ".bak")
    if not backup.exists():
        backup.write_text(text, encoding="utf-8")
    text = text.replace(registry_anchor, registry_anchor + "    'APGB', 'APGBUP',\n", 1)
    p.write_text(text, encoding="utf-8")

# 2) DASHBOARD PAYMENT SETTINGS ---------------------------------------------
replace_once(
    "lib/dashboard_page.dart",
    '''            _compactIconButton(\n              Icons.notifications_active_rounded,\n              'Payment Detection',\n              () => _schedulePaymentDetectionReminder(force: true),\n              isPrimary: true,\n            ),''',
    '''            _compactIconButton(\n              Icons.notifications_active_rounded,\n              'Payment Detection',\n              _openPaymentDetectionSettings,\n              isPrimary: true,\n            ),''',
)

p = ROOT / "lib/dashboard_page.dart"
text = p.read_text(encoding="utf-8")
if "Future<void> _openPaymentDetectionSettings()" not in text:
    marker = "  Future<void> _schedulePaymentDetectionReminder({bool force = false}) async {"
    if marker not in text:
        raise RuntimeError("Dashboard payment reminder marker not found")
    helper = '''  Future<void> _openPaymentDetectionSettings() async {\n    if (!mounted) return;\n    await showDialog<void>(\n      context: context,\n      barrierDismissible: true,\n      builder: (ctx) => AlertDialog(\n        title: const Text('Payment Detection Settings'),\n        content: const Text('Review SMS and notification access for automatic payment detection.'),\n        actions: [\n          TextButton(\n            onPressed: () async {\n              Navigator.of(ctx).pop();\n              await openAppSettings();\n            },\n            child: const Text('APP SETTINGS'),\n          ),\n          FilledButton(\n            onPressed: () async {\n              Navigator.of(ctx).pop();\n              try {\n                await PaymentDetectionService().ensureChannelsRunning();\n              } catch (e) {\n                if (kDebugMode) debugPrint('Payment detection start failed: $e');\n              }\n              if (mounted) {\n                await Future<void>.delayed(const Duration(milliseconds: 300));\n                await _checkPermissions(showReminderIfMissing: false);\n              }\n            },\n            child: const Text('START DETECTION'),\n          ),\n        ],\n      ),\n    );\n  }\n\n'''
    backup = p.with_suffix(p.suffix + ".bak")
    if not backup.exists():
        backup.write_text(text, encoding="utf-8")
    p.write_text(text.replace(marker, helper + marker, 1), encoding="utf-8")

# 3) SAVE-SALE / INVOICE SYNC -----------------------------------------------
replace_once(
    "lib/sale_service.dart",
    '''  final invoicePayload = {\n    'invoice_number': saleId,\n    'offline_id': offlineId,\n    'customer_name': customerName.isNotEmpty ? customerName : 'Cash Customer',\n    'customer_phone': customerPhone.isNotEmpty ? customerPhone : null,\n    'total_amount': grandTotal,\n    'paid_amount': paidAmount,\n    'tax': withTax ? (totals['tax'] ?? 0.0) : 0.0,\n''',
    '''  double computedLineSubtotal = 0.0;\n  for (final line in lineItems) {\n    final qty = double.tryParse((line['quantity'] ?? line['qty'] ?? 0).toString()) ?? 0.0;\n    final price = double.tryParse((line['unit_price'] ?? line['price'] ?? 0).toString()) ?? 0.0;\n    final discount = double.tryParse((line['discount_amount'] ?? 0).toString()) ?? 0.0;\n    computedLineSubtotal += (qty * price) - discount;\n  }\n  computedLineSubtotal = computedLineSubtotal < 0 ? 0.0 : computedLineSubtotal;\n  final requestedTax = withTax ? double.tryParse((totals['tax'] ?? 0.0).toString()) : 0.0;\n  final safeTax = requestedTax > 0.0\n      ? requestedTax\n      : (grandTotal - computedLineSubtotal).clamp(0.0, double.infinity).toDouble();\n\n  final invoicePayload = {\n    'invoice_number': saleId,\n    'offline_id': offlineId,\n    'customer_name': customerName.isNotEmpty ? customerName : 'Cash Customer',\n    'customer_phone': customerPhone.isNotEmpty ? customerPhone : null,\n    'total_amount': grandTotal,\n    'paid_amount': paidAmount,\n    'tax': safeTax,\n''',
)

replace_once(
    "lib/sale_service.dart",
    "        if (item['discount_amount'] != null) 'discount_amount': item['discount_amount'],\n",
    "        'discount_amount': item['discount_amount'] ?? 0.0,\n",
)

replace_once(
    "lib/sale_service.dart",
    '''        if (response.statusCode == 200 || response.statusCode == 201) {\n          return true;\n        }\n''',
    '''        if ((response.statusCode >= 200 && response.statusCode < 300) || response.statusCode == 409) {\n          return true;\n        }\n''',
)

replace_once(
    "lib/sync_service.dart",
    '''      final res = await ApiClient.postJson(\n        endpoint,\n        payload,\n        headers: {\n          if (token.isNotEmpty) 'Authorization': 'Bearer $token',\n        },\n      ).timeout(const Duration(seconds: 15));\n\n      // 201 = created; 200 = already exists/idempotent duplicate.\n      return res.statusCode == 200 || res.statusCode == 201;\n''',
    '''      if (!payload.containsKey('tax')) {\n        final rawItems = payload['line_items'];\n        double subtotal = 0.0;\n        if (rawItems is List) {\n          for (final raw in rawItems) {\n            if (raw is! Map) continue;\n            final qty = double.tryParse((raw['quantity'] ?? raw['qty'] ?? 0).toString()) ?? 0.0;\n            final price = double.tryParse((raw['unit_price'] ?? raw['price'] ?? 0).toString()) ?? 0.0;\n            final discount = double.tryParse((raw['discount_amount'] ?? 0).toString()) ?? 0.0;\n            subtotal += (qty * price) - discount;\n          }\n        }\n        final total = double.tryParse((payload['total_amount'] ?? 0).toString()) ?? 0.0;\n        payload['tax'] = (total - subtotal).clamp(0.0, double.infinity).toDouble();\n      }\n\n      final res = await ApiClient.postJson(\n        endpoint,\n        payload,\n        headers: {\n          if (token.isNotEmpty) 'Authorization': 'Bearer $token',\n        },\n      ).timeout(const Duration(seconds: 20));\n\n      if ((res.statusCode >= 200 && res.statusCode < 300) || res.statusCode == 409) return true;\n      if (kDebugMode) debugPrint('❌ Sale sync rejected: ${res.statusCode} ${res.body}');\n      return false;\n''',
)

print('✅ Applied payment detection, dashboard settings, and sale-sync fixes.')
