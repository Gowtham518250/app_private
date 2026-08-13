import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'notification_service.dart';
import 'payment_event.dart';
import 'api_client.dart';

/// Online orders: analytics, UPI matching, notifications helpers.
class OnlineOrderService {
  static const _orders = 'orders';

  /// Shop UPI for customer checkout — Firestore only (never owner prefs.upi_id).
  static Future<String?> fetchShopUpi(String shopId) async {
    if (shopId.isEmpty) return null;
    try {
      final doc = await FirebaseFirestore.instance.collection('shops').doc(shopId).get();
      final upi = doc.data()?['upi_id']?.toString().trim();
      if (upi != null && upi.isNotEmpty) return upi;
    } catch (e) {
      if (kDebugMode) debugPrint('fetchShopUpi Firestore: $e');
    }
    return null;
  }

  static Future<void> syncShopUpiToFirestore(String shopId) async {
    if (shopId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final upi = prefs.getString('upi_id');
    if (upi == null || upi.isEmpty) return;
    try {
      await FirebaseFirestore.instance.collection('shops').doc(shopId).set(
        {'upi_id': upi},
        SetOptions(merge: true),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('syncShopUpi: $e');
    }
  }

  /// Online metrics from the same backend order API used by the owner order
  /// screen. The previous implementation queried a separate Firestore
  /// collection, so an order accepted/converted by the FastAPI store could
  /// correctly exist in the app while this dashboard still reported 0.
  static Future<Map<String, dynamic>> getAnalytics(String shopId) async {
    if (shopId.isEmpty || shopId == '0') {
      return {'pending': 0, 'todayCount': 0, 'totalCount': 0, 'todayRevenue': 0.0, 'paidCount': 0};
    }

    final today = DateTime.now();
    final startOfDay = DateTime(today.year, today.month, today.day);
    final statuses = const ['PENDING', 'ACCEPTED', 'DISPATCHED', 'DELIVERED'];
    final byId = <String, Map<String, dynamic>>{};

    try {
      for (final status in statuses) {
        try {
          final response = await ApiClient.getJson('/store/owner/orders?status=$status')
              .timeout(const Duration(seconds: 8));
          if (response.statusCode != 200) continue;
          final body = jsonDecode(response.body);
          final raw = body is Map ? body['orders'] : body;
          if (raw is! List) continue;
          for (final value in raw) {
            if (value is! Map) continue;
            final order = Map<String, dynamic>.from(value);
            final id = (order['order_id'] ?? order['id'] ?? '').toString().trim();
            if (id.isNotEmpty) byId[id] = {...(byId[id] ?? const <String, dynamic>{}), ...order};
          }
        } catch (e) {
          if (kDebugMode) debugPrint('getAnalytics $status: $e');
        }
      }

      var pending = 0;
      var todayCount = 0;
      var paidCount = 0;
      double todayRevenue = 0;

      for (final d in byId.values) {
        final status = (d['status'] ?? '').toString().toUpperCase();
        if (status == 'PENDING') pending++;
        if (status == 'REJECTED' || status == 'CANCELLED') continue;

        final rawTime = d['timestamp'] ?? d['created_at'] ?? d['createdAt'] ?? d['order_date'];
        DateTime? orderTime;
        if (rawTime is Timestamp) orderTime = rawTime.toDate();
        else if (rawTime != null) orderTime = DateTime.tryParse(rawTime.toString());
        if (orderTime != null && orderTime.isBefore(startOfDay)) continue;

        if (orderTime != null) {
          todayCount++;
          final rawAmount = d['total_amount'] ?? d['total'] ?? d['grand_total'];
          final amount = rawAmount is num ? rawAmount.toDouble() : double.tryParse(rawAmount?.toString() ?? '0') ?? 0.0;
          todayRevenue += amount;
          if ((d['payment_status'] ?? '').toString().toLowerCase() == 'paid') paidCount++;
        }
      }

      return {
        'pending': pending,
        'todayCount': todayCount,
        'totalCount': byId.values.where((d) {
          final st = (d['status'] ?? '').toString().toUpperCase();
          return st != 'REJECTED' && st != 'CANCELLED';
        }).length,
        'todayRevenue': todayRevenue,
        'paidCount': paidCount,
      };
    } catch (e) {
      if (kDebugMode) debugPrint('getAnalytics: $e');
      return {'pending': 0, 'todayCount': 0, 'totalCount': 0, 'todayRevenue': 0.0, 'paidCount': 0};
    }
  }

  /// Match incoming UPI to a pending online order (owner device).
  static Future<String?> tryMatchOnlineOrderPayment(
    PaymentEvent event,
    String shopId,
  ) async {
    if (shopId.isEmpty || event.isFailed || event.amount <= 0) return null;

    try {
      final snap = await FirebaseFirestore.instance
          .collection(_orders)
          .where('shop_id', isEqualTo: shopId)
          .where('payment_status', isEqualTo: 'pending')
          .where('payment_method', isEqualTo: 'upi')
          .limit(20)
          .get();

      for (final doc in snap.docs) {
        final expected = (doc.data()['total_amount'] as num?)?.toDouble() ?? 0;
        if ((event.amount - expected).abs() > 1.0) continue;

        await doc.reference.update({
          'payment_status': 'paid',
          'paid_at': FieldValue.serverTimestamp(),
          'payment_reference': event.referenceId ?? event.id,
          'payment_amount': event.amount,
        });

        await NotificationService.show(
          'Online payment received',
          '₹${event.amount.toStringAsFixed(0)} matched to order #${doc.id.substring(0, 8)}',
        );
        return doc.id;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('tryMatchOnlineOrderPayment: $e');
    }
    return null;
  }

  static Future<void> notifyOrderStatusChange({
    required String orderId,
    required String status,
    required String shopName,
    required double total,
  }) async {
    await NotificationService.show(
      'Order update — $shopName',
      '#${orderId.substring(0, 8)}: $status · ₹${total.toStringAsFixed(0)}',
    );
  }

  static Future<void> notifyNewOrderForOwner({
    required String orderId,
    required double total,
    required String customerEmail,
  }) async {
    await NotificationService.show(
      'New online order',
      '₹${total.toStringAsFixed(0)} from $customerEmail · Tap Online Store',
    );
  }
}
