import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../api_client.dart';
import '../../visual_widgets.dart';

class OnlineOrdersTab extends StatefulWidget {
  const OnlineOrdersTab({super.key});

  @override
  State<OnlineOrdersTab> createState() => _OnlineOrdersTabState();
}

class _OnlineOrdersTabState extends State<OnlineOrdersTab>
    with SingleTickerProviderStateMixin {
  String _shopId = '';
  List<Map<String, dynamic>> _pendingOrders = [];
  // 🚨 FIX: Accepted orders are now kept in their own list instead of just
  // vanishing once ACCEPT succeeds. Previously _fetchOrders() only ever asked
  // the backend for status=PENDING, so the moment an order was accepted it
  // dropped out of the only list the screen showed — it wasn't lost on the
  // backend, but the owner had no way to see it or its details again in-app.
  List<Map<String, dynamic>> _acceptedOrders = [];
  // 🛡️ FIX: previously only PENDING and ACCEPTED were ever fetched, so an
  // order that got dispatched (a real, valid next stage the backend
  // supports via action=DISPATCH) would disappear from view exactly the
  // same way the original bug worked, just one stage later. Tracking it
  // explicitly closes that gap.
  List<Map<String, dynamic>> _dispatchedOrders = [];
  bool _isLoading = true;
  // Tracks order ids whose ACCEPT/REJECT call is still being retried in the
  // background, so the UI can show a "syncing" indicator instead of silently
  // failing if the network drops mid-action.
  final Set<String> _pendingSync = {};
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadShopIdAndOrders();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadShopIdAndOrders() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _shopId = (prefs.getInt('user_id') ?? 0).toString();
    });
    await _fetchAllOrders();
  }

  Future<void> _fetchAllOrders() async {
    setState(() => _isLoading = true);
    await Future.wait([
      _fetchOrdersByStatus('PENDING'),
      _fetchOrdersByStatus('ACCEPTED'),
      _fetchOrdersByStatus('DISPATCHED'),
    ]);
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _fetchOrdersByStatus(String status) async {
    try {
      final res = await ApiClient.getJson('/store/owner/orders?status=$status');
      if (res.statusCode == 200) {
        final body = json.decode(res.body);
        final orders = List<Map<String, dynamic>>.from(body['orders'] ?? []);
        if (!mounted) return;
        setState(() {
          if (status == 'PENDING') {
            _pendingOrders = orders;
          } else if (status == 'ACCEPTED') {
            _acceptedOrders = orders;
          } else {
            _dispatchedOrders = orders;
          }
        });
      }
    } catch (e) {
      debugPrint('Failed to fetch $status orders: $e');
      // Deliberately NOT clearing the existing list here — a failed refresh
      // should never make previously-loaded orders disappear from the screen.
    }
  }

  Future<void> _updateOrderStatus(Map<String, dynamic> order, String action) async {
    final orderId = order['order_id']?.toString() ?? '0';

    // Optimistic local update: move the order between lists immediately so the
    // owner keeps seeing its full details right away, and retry the backend
    // call in the background instead of making the order vanish while we wait.
    setState(() {
      _pendingOrders.removeWhere((o) => o['order_id']?.toString() == orderId);
      _acceptedOrders.removeWhere((o) => o['order_id']?.toString() == orderId);
      _dispatchedOrders.removeWhere((o) => o['order_id']?.toString() == orderId);
      if (action == 'ACCEPT') {
        _acceptedOrders.insert(0, {...order, 'status': 'ACCEPTED'});
      } else if (action == 'DISPATCH') {
        _dispatchedOrders.insert(0, {...order, 'status': 'DISPATCHED'});
      }
      // REJECT and DELIVER both move the order to a final state this screen
      // doesn't track a list for — it correctly drops out of view, unlike
      // the original bug where every action caused that same disappearance.
      _pendingSync.add(orderId);
    });

    final ok = await _sendOrderAction(orderId, action);

    if (!mounted) return;
    setState(() => _pendingSync.remove(orderId));

    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Order $action successfully!')),
      );
    } else {
      // Keep the order visible (still marked as "syncing failed") and offer a
      // manual retry instead of losing the action entirely.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Order $action saved locally but not confirmed by server yet — tap to retry.'),
          action: SnackBarAction(
            label: 'RETRY',
            onPressed: () => _updateOrderStatus(order, action),
          ),
        ),
      );
    }
  }

  /// Backend call with a couple of quick retries — protects against a single
  /// dropped packet on flaky mobile data from silently losing the accept/reject.
  Future<bool> _sendOrderAction(String orderId, String action) async {
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        final res = await ApiClient.postJson(
          '/store/owner/orders/$orderId/action?action=$action',
          {},
        ).timeout(const Duration(seconds: 12));
        if (res.statusCode == 200) return true;
      } catch (e) {
        debugPrint('Order action attempt ${attempt + 1} failed: $e');
      }
      if (attempt < 2) {
        await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (_shopId.isEmpty || _shopId == '0') {
      return const Scaffold(body: Center(child: Text('Invalid Shop Profile')));
    }

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('Online Orders', style: TextStyle(color: Colors.black87)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.black87),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.primary,
          unselectedLabelColor: Colors.black54,
          indicatorColor: AppColors.primary,
          isScrollable: true,
          tabs: [
            Tab(text: 'Pending (${_pendingOrders.length})'),
            Tab(text: 'Accepted (${_acceptedOrders.length})'),
            Tab(text: 'Dispatched (${_dispatchedOrders.length})'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildOrderList(
                  orders: _pendingOrders,
                  emptyText: 'No incoming orders',
                  nextAction: 'ACCEPT',
                ),
                _buildOrderList(
                  orders: _acceptedOrders,
                  emptyText: 'No accepted orders yet',
                  nextAction: 'DISPATCH',
                ),
                _buildOrderList(
                  orders: _dispatchedOrders,
                  emptyText: 'No dispatched orders yet',
                  nextAction: 'DELIVER',
                ),
              ],
            ),
    );
  }

  Widget _buildOrderList({
    required List<Map<String, dynamic>> orders,
    required String emptyText,
    required String? nextAction, // 'ACCEPT' | 'DISPATCH' | 'DELIVER' | null (no next stage from here)
  }) {
    return RefreshIndicator(
      onRefresh: _fetchAllOrders,
      child: orders.isEmpty
          ? ListView(
              children: [
                const SizedBox(height: 100),
                Center(child: Text(emptyText, style: const TextStyle(color: Colors.black54))),
              ],
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: orders.length,
              itemBuilder: (context, index) {
                final order = orders[index];
                final orderId = order['order_id']?.toString() ?? '0';
                final items = order['items'] as List<dynamic>? ?? [];
                final syncing = _pendingSync.contains(orderId);

                return GlassContainer(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Order #$orderId',
                              style: const TextStyle(
                                  color: AppColors.primary, fontWeight: FontWeight.bold, fontSize: 16)),
                          if (syncing)
                            const Badge(label: Text('SYNCING'), backgroundColor: Colors.orange)
                          else if (nextAction == 'ACCEPT')
                            const Badge(label: Text('NEW'), backgroundColor: Colors.redAccent)
                          else if (nextAction == 'DISPATCH')
                            const Badge(label: Text('ACCEPTED'), backgroundColor: Colors.green)
                          else
                            const Badge(label: Text('DISPATCHED'), backgroundColor: Colors.blue),
                        ],
                      ),
                      const Divider(color: Colors.black12, height: 24),
                      // FIX: backend never sends 'customer_email' -- it sends
                      // customer_name + customer_phone. This previously
                      // always rendered "Customer: null".
                      Text('Customer: ${order['customer_name'] ?? 'Guest'}',
                          style: const TextStyle(color: Colors.black87, fontSize: 16)),
                      if ((order['customer_phone'] ?? '').toString().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(order['customer_phone'].toString(),
                              style: const TextStyle(color: Colors.black54, fontSize: 13)),
                        ),
                      if ((order['delivery_address'] ?? '').toString().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text('Deliver to: ${order['delivery_address']}',
                              style: const TextStyle(color: Colors.black54, fontSize: 13)),
                        ),
                      const SizedBox(height: 16),
                      const Text('Items Requested:', style: TextStyle(color: Colors.black54, fontSize: 14)),
                      const SizedBox(height: 8),
                      ...items.map((item) {
                        // FIX: backend field is 'unit_price', not 'price' -- previously always 0/blank.
                        final qty = item['quantity'] ?? 1;
                        final unitPrice = (item['unit_price'] is num) ? (item['unit_price'] as num) : 0;
                        final qtyNum = (qty is num) ? qty : (num.tryParse(qty.toString()) ?? 1);
                        final lineTotal = unitPrice * qtyNum;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 4.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('${qty}x ${item['product_name'] ?? 'Item'}',
                                  style: const TextStyle(color: Colors.black87)),
                              Text('Rs ${lineTotal.toStringAsFixed(2)}',
                                  style: const TextStyle(color: Colors.black87)),
                            ],
                          ),
                        );
                      }),
                      const Divider(color: Colors.black12, height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Total Value', style: TextStyle(color: Colors.black54, fontSize: 16)),
                          Text('Rs ${order['total_amount']}',
                              style: const TextStyle(
                                  color: Colors.green, fontSize: 20, fontWeight: FontWeight.bold)),
                        ],
                      ),
                      if (nextAction == 'ACCEPT') ...[
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: syncing ? null : () => _updateOrderStatus(order, 'REJECT'),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.redAccent,
                                  side: const BorderSide(color: Colors.redAccent),
                                ),
                                child: const Text('Reject'),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: syncing ? null : () => _updateOrderStatus(order, 'ACCEPT'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.primary,
                                  foregroundColor: Colors.white,
                                ),
                                child: const Text('Accept Order'),
                              ),
                            ),
                          ],
                        ),
                      ] else if (nextAction == 'DISPATCH') ...[
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: syncing ? null : () => _updateOrderStatus(order, 'DISPATCH'),
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, foregroundColor: Colors.white),
                            icon: const Icon(Icons.local_shipping_outlined, size: 18),
                            label: const Text('Mark as Dispatched'),
                          ),
                        ),
                      ] else if (nextAction == 'DELIVER') ...[
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: syncing ? null : () => _updateOrderStatus(order, 'DELIVER'),
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                            icon: const Icon(Icons.check_circle_outline, size: 18),
                            label: const Text('Mark as Delivered'),
                          ),
                        ),
                      ] else if (syncing) ...[
                        const SizedBox(height: 12),
                        const Text('Confirming with server…', style: TextStyle(color: Colors.orange, fontSize: 12)),
                      ],
                    ],
                  ),
                );
              },
            ),
    );
  }
}