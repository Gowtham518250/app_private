import 'package:flutter/foundation.dart';
import 'format_helper.dart';
import 'local_storage_service.dart';
import 'financial_math.dart';

/// Result of a one-time Hive sales cleanup (Option B).
class SalesCleanupResult {
  final int before;
  final int after;
  final int removed;

  const SalesCleanupResult({
    required this.before,
    required this.after,
    required this.removed,
  });
}

/// Prevents duplicate bills/lines from cloud sync + dashboard merge.
class SalesDedupHelper {
  static String _dayKey(dynamic dateStr) {
    final s = dateStr?.toString() ?? '';
    if (s.isEmpty) return '';
    return s.split('T').first.split(' ').first;
  }

  static double _num(dynamic v, [double fallback = 0]) {
    if (v == null) return fallback;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? fallback;
  }

  static String _productKey(Map item) {
    final raw = (item['product_name'] ?? item['item'] ?? item['product'] ?? 'unknown').toString();
    return FormatHelper.normalizeName(raw);
  }

  /// Fingerprint for a full bill (matches local SALE_xxx vs cloud row id).
  static String billFingerprint(Map<String, dynamic> sale) {
    final saleId = (sale['sale_id'] ?? sale['invoice_number'] ?? '').toString();
    final day = _dayKey(sale['sale_date'] ?? sale['created_at'] ?? sale['date']);
    final total = _num(sale['total']).toStringAsFixed(2);
    final items = sale['items'] as List? ?? [];

    if (items.isEmpty) {
      final product = FormatHelper.normalizeName((sale['product'] ?? 'unknown').toString());
      final qty = _num(sale['quantity'] ?? sale['qty'], 1).toStringAsFixed(2);
      final price = _num(sale['price']).toStringAsFixed(2);
      return '${saleId}_${day}_${product}_${qty}_${price}_$total';
    }

    final parts = <String>[];
    for (final raw in items) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      final product = _productKey(item);
      final qty = _num(item['qty'] ?? item['quantity'], 1).toStringAsFixed(2);
      final price = _num(item['price']).toStringAsFixed(2);
      parts.add('${product}_${qty}_$price');
    }
    parts.sort();
    return '${saleId}_${day}_${parts.join('|')}_$total';
  }

  /// Content-only fingerprint — catches duplicate lines even with different sale_id.
  static String lineContentFingerprint(Map<String, dynamic> line) {
    final day = _dayKey(line['sale_date'] ?? line['created_at'] ?? line['date']);
    final product = FormatHelper.normalizeName(
      (line['product_name'] ?? line['product'] ?? line['item'] ?? 'unknown').toString(),
    );
    final qty = _num(line['quantity'] ?? line['qty'], 1).toStringAsFixed(2);
    final price = _num(line['price']).toStringAsFixed(2);
    final total = _num(line['total']).toStringAsFixed(2);
    return '${day}_${product}_${qty}_${price}_$total';
  }

  /// Prefer owner-created local bills over cloud-reimport copies.
  static bool _preferIncomingBill(Map<String, dynamic> existing, Map<String, dynamic> incoming) {
    final eId = (existing['sale_id'] ?? existing['id'] ?? '').toString();
    final iId = (incoming['sale_id'] ?? incoming['id'] ?? '').toString();
    final eCloud = existing['customer_name']?.toString() == 'Cloud Restore' || existing['is_synced'] == true;
    final iCloud = incoming['customer_name']?.toString() == 'Cloud Restore' || incoming['is_synced'] == true;

    if (eId.startsWith('SALE_') && !iId.startsWith('SALE_')) return false;
    if (iId.startsWith('SALE_') && !eId.startsWith('SALE_')) return true;
    if (!eCloud && iCloud) return false;
    if (eCloud && !iCloud) return true;
    return false;
  }

  /// Real bill only — rejects empty/zero rows that polluted dashboards.
  static bool isValidBill(Map<String, dynamic> sale) {
    if (sale['status']?.toString() == 'CANCELLED') return true;
    final total = _num(sale['total']);
    final items = sale['items'] as List? ?? [];
    if (items.isEmpty) {
      final price = _num(sale['price']);
      final qty = _num(sale['quantity'] ?? sale['qty'], 1);
      return price > 0 && qty > 0 && total > 0;
    }
    return total > 0 || items.isNotEmpty;
  }

  /// Remove duplicate bills; keeps the best copy per fingerprint.
  static List<Map<String, dynamic>> dedupeBills(List<dynamic> raw) {
    final Map<String, Map<String, dynamic>> byId = {};
    final Map<String, Map<String, dynamic>> byFingerprint = {};
    final List<Map<String, dynamic>> cancelled = [];
    final List<Map<String, dynamic>> finalResult = [];

    for (final entry in raw) {
      if (entry is! Map) continue;
      final sale = Map<String, dynamic>.from(entry);
      if (!isValidBill(sale)) continue;
      if (sale['status']?.toString() == 'CANCELLED') {
        cancelled.add(sale);
        continue;
      }

      final saleId = (sale['sale_id'] ?? sale['id'] ?? '').toString();
      final fp = billFingerprint(sale);

      // Strong ID match takes precedence
      if (saleId.isNotEmpty && saleId.startsWith('SALE_')) {
        if (byId.containsKey(saleId)) {
          final existing = byId[saleId]!;
          if (_preferIncomingBill(existing, sale)) {
            byId[saleId] = sale;
            // Update fingerprint mapping as well
            final oldFp = billFingerprint(existing);
            if (byFingerprint[oldFp] == existing) {
              byFingerprint.remove(oldFp);
              byFingerprint[fp] = sale;
            }
          }
          continue;
        }
      }

      // Fingerprint match (only if we don't have conflicting SALE_ ids)
      if (byFingerprint.containsKey(fp)) {
        final existing = byFingerprint[fp]!;
        final eId = (existing['sale_id'] ?? existing['id'] ?? '').toString();
        
        // Prevent merging two explicitly different local sales
        bool isDistinctSale = saleId.startsWith('SALE_') && eId.startsWith('SALE_') && saleId != eId;
        
        if (!isDistinctSale) {
          if (_preferIncomingBill(existing, sale)) {
            byFingerprint[fp] = sale;
            if (eId.startsWith('SALE_')) byId.remove(eId);
            if (saleId.startsWith('SALE_')) byId[saleId] = sale;
          }
          continue;
        }
      }

      // New sale
      if (saleId.startsWith('SALE_')) {
        byId[saleId] = sale;
      }
      byFingerprint[fp] = sale;
      finalResult.add(sale); // Keep original order
    }

    // Rebuild final list based on latest references in byId / byFingerprint
    final uniqueSales = <Map<String, dynamic>>[];
    
    for (final fp in byFingerprint.keys) {
      uniqueSales.add(byFingerprint[fp]!);
    }

    return [...uniqueSales, ...cancelled];
  }

  /// Remove duplicate flattened lines shown in charts/transactions.
  static List<Map<String, dynamic>> dedupeFlattenedLines(List<Map<String, dynamic>> lines) {
    final seen = <String>{};
    final out = <Map<String, dynamic>>[];

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final saleId = (line['sale_id'] ?? line['invoice_number'] ?? '').toString();
      final fp = lineContentFingerprint(line);
      final compositeKey = saleId.isNotEmpty ? '${saleId}_${fp}_$i' : '${fp}_$i';
      
      if (seen.contains(compositeKey)) continue;
      seen.add(compositeKey);
      out.add(line);
    }
    return out;
  }

  /// Option B: one-time cleanup — dedupe Hive bills and persist if changed.
  static Future<SalesCleanupResult> cleanupAndPersist() async {
    final raw = await LocalStorageService.loadSales();
    final before = raw.length;
    final deduped = dedupeBills(raw);
    final after = deduped.length;

    if (after < before) {
      await LocalStorageService.saveSales(deduped);
      if (kDebugMode) debugPrint('🧹 Sales cleanup: removed ${before - after} duplicate bills ($after remain)');
    }

    return SalesCleanupResult(before: before, after: after, removed: before - after);
  }

  /// True when [cloud] bill duplicates an existing [local] bill.
  static bool isDuplicateBill(Map<String, dynamic> cloud, Iterable<Map<String, dynamic>> localBills) {
    final cloudId = (cloud['sale_id'] ?? cloud['id'] ?? '').toString();
    final cloudFp = billFingerprint(cloud);

    for (final local in localBills) {
      final localId = (local['sale_id'] ?? local['id'] ?? '').toString();
      
      // Strong match
      if (cloudId.isNotEmpty && localId.isNotEmpty && cloudId == localId) return true;
      
      // Fingerprint match, but only if they don't have conflicting SALE_ ids
      if (billFingerprint(local) == cloudFp) {
         bool isDistinctSale = cloudId.startsWith('SALE_') && localId.startsWith('SALE_') && cloudId != localId;
         if (!isDistinctSale) return true;
      }
    }
    return false;
  }

  /// Group API line rows (one row per item) into bills by sale_id.
  static List<Map<String, dynamic>> groupApiLinesIntoBills(List<dynamic> apiSales) {
    final Map<String, Map<String, dynamic>> grouped = {};

    for (final raw in apiSales) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);

      final price = _num(item['price']);
      final qty = _num(item['quantity'] ?? item['qty'], 1);
      if (price <= 0 || qty <= 0) continue;

      final lineTotal = _num(item['total'], CurrencyManager.multiply(price, qty));
      final timestamp = item['sale_date'] ?? item['created_at'] ?? DateTime.now().toUtc().toIso8601String();
      final saleId = (item['sale_id'] ?? item['id'] ?? 'API_${item.hashCode}').toString();
      final product = (item['product'] ?? item['product_name'] ?? item['item'] ?? item['name'] ?? item['itemName'] ?? item['title'] ?? '').toString().trim();

      if (product.isEmpty || product.toLowerCase() == 'unknown' || product.toLowerCase() == 'unknown item' || product.toLowerCase() == 'product') {
        if (kDebugMode) debugPrint('Skipping invalid restored record: $saleId');
        continue;
      }
      
      if (kDebugMode) {
        debugPrint('SALE RESTORED:\ninvoice_number: $saleId\nproduct_name: $product\nquantity: $qty\nprice: $price');
      }

      grouped.putIfAbsent(saleId, () => {
        'sale_id': saleId,
        'customer_name': item['customer_name'] ?? 'Cloud Restore',
        'items': <Map<String, dynamic>>[],
        'sale_date': timestamp,
        'created_at': timestamp,
        'date': timestamp,
        'total': 0.0,
        'paid_amount': 0.0,
        'payment_status': 'PAID',
        'is_synced': true,
      });

      final bill = grouped[saleId]!;
      (bill['items'] as List).add({
        'product_name': product,
        'item': product,
        'qty': qty,
        'quantity': qty,
        'price': price,
        'total': lineTotal,
        'total_with_tax': lineTotal,
      });
      bill['total'] = _num(bill['total']) + lineTotal;
      bill['paid_amount'] = bill['total'];
    }

    return grouped.values.map((b) => Map<String, dynamic>.from(b)).toList();
  }
}
