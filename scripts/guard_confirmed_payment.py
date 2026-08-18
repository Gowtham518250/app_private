from pathlib import Path
p = Path('lib/dashboard_page.dart')
s = p.read_text(encoding='utf-8')
old = """  Future<void> _reconcileDetectedPaymentToInvoice(dynamic event) async {\n    try {\n      final amount = (event.amount as num?)?.toDouble() ?? 0.0;\n"""
new = """  Future<void> _reconcileDetectedPaymentToInvoice(dynamic event) async {\n    try {\n      // Never mutate invoice money for a LIKELY notification. The detection\n      // engine requires an independent confirmation anchor; only CONFIRMED\n      // events may automatically settle or partially settle an invoice.\n      if (event.decision != PaymentDecision.confirmed) return;\n      final amount = (event.amount as num?)?.toDouble() ?? 0.0;\n"""
if old not in s: raise SystemExit('method header not found')
if 'if (event.decision != PaymentDecision.confirmed) return;' not in s:
    p.write_text(s.replace(old, new, 1), encoding='utf-8')
