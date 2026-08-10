import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'payment_detection_service.dart';
import 'whatsapp_message_service.dart';

/// Shop model for multi-shop context
class Shop {
  final int id;
  final int ownerId;
  final String name;
  final String? address;
  final String? phone;
  double? todaysSales;
  int? transactionCount;
  double? pendingUdhar;
  
  Shop({
    required this.id,
    required this.ownerId,
    required this.name,
    this.address,
    this.phone,
    this.todaysSales,
    this.transactionCount,
    this.pendingUdhar,
  });
}

/// Shop group for multi-shop owners
class ShopGroup {
  final int ownerId;
  final List<Shop> shops;
  final String ownerPhone;
  
  ShopGroup({
    required this.ownerId,
    required this.shops,
    required this.ownerPhone,
  });
  
  double get totalSales => shops.fold(0.0, (sum, s) => sum + (s.todaysSales ?? 0));
  int get totalTransactions => shops.fold(0, (sum, s) => sum + (s.transactionCount ?? 0));
  double get totalPendingUdhar => shops.fold(0.0, (sum, s) => sum + (s.pendingUdhar ?? 0));
}

/// Multi-shop context manager
class MultiShopContextManager {
  static const String _activeShopKey = 'active_shop_id';
  static const String _tag = '🏪 MULTI_SHOP';
  
  static Future<int?> getActiveShopId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(_activeShopKey);
    } catch (e) {
      debugPrint('$_tag Error getting active shop: $e');
      return null;
    }
  }
  
  static Future<void> setActiveShopId(int shopId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_activeShopKey, shopId);
      debugPrint('$_tag Active shop set to: $shopId');
    } catch (e) {
      debugPrint('$_tag Error setting active shop: $e');
    }
  }
  
  static Future<void> clearActiveShopId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_activeShopKey);
    } catch (e) {
      debugPrint('$_tag Error clearing active shop: $e');
    }
  }
}

/// Multi-shop owner dashboard widget
class MultiShopDashboardWidget extends StatefulWidget {
  final ShopGroup shopGroup;
  final Function(int shopId) onShopSelected;
  final VoiceLanguage language;
  
  const MultiShopDashboardWidget({
    required this.shopGroup,
    required this.onShopSelected,
    required this.language,
    Key? key,
  }) : super(key: key);
  
  @override
  State<MultiShopDashboardWidget> createState() =>
      _MultiShopDashboardWidgetState();
}

class _MultiShopDashboardWidgetState extends State<MultiShopDashboardWidget> {
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Consolidated summary
            _buildConsolidatedSummary(),
            const SizedBox(height: 24),
            
            // Title
            const Text(
              '📍 My Shops',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            
            // Shop cards
            ListView.builder(
              shrinkWrap: true,
              physics: NeverScrollableScrollPhysics(),
              itemCount: widget.shopGroup.shops.length,
              itemBuilder: (ctx, idx) => _buildShopCard(
                widget.shopGroup.shops[idx],
                idx,
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildConsolidatedSummary() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.blue[50]!, Colors.purple[50]!],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blue[200]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '📊 Today\'s Consolidated Report',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildMetric(
                '₹${widget.shopGroup.totalSales.toStringAsFixed(0)}',
                'Total Sales',
              ),
              _buildMetric(
                '${widget.shopGroup.totalTransactions}',
                'Transactions',
              ),
              _buildMetric(
                '₹${widget.shopGroup.totalPendingUdhar.toStringAsFixed(0)}',
                'Pending',
              ),
            ],
          ),
        ],
      ),
    );
  }
  
  Widget _buildMetric(String value, String label) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.green,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
      ],
    );
  }
  
  Widget _buildShopCard(Shop shop, int index) {
    return GestureDetector(
      onTap: () {
        widget.onShopSelected(shop.id);
        MultiShopContextManager.setActiveShopId(shop.id);
      },
      child: Card(
        margin: const EdgeInsets.only(bottom: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: LinearGradient(
              colors: [
                Colors.amber[50]!,
                Colors.orange[50]!,
              ],
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Shop name and number
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      shop.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.orange[200],
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'Shop ${index + 1}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.orange[900],
                      ),
                    ),
                  ),
                ],
              ),
              
              const SizedBox(height: 12),
              
              // Address
              if (shop.address != null)
                Row(
                  children: [
                    Icon(Icons.location_on, size: 16, color: Colors.grey[600]),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        shop.address!,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[700],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              
              const SizedBox(height: 12),
              Divider(color: Colors.grey[300]),
              const SizedBox(height: 12),
              
              // Stats
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Column(
                    children: [
                      Text(
                        '₹${(shop.todaysSales ?? 0).toStringAsFixed(0)}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.green,
                        ),
                      ),
                      Text(
                        'Sales',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                  Column(
                    children: [
                      Text(
                        '${shop.transactionCount ?? 0}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'Txns',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                  Column(
                    children: [
                      Text(
                        '₹${(shop.pendingUdhar ?? 0).toStringAsFixed(0)}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.red,
                        ),
                      ),
                      Text(
                        'Udhar',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Consolidated evening report builder
String buildConsolidatedEveningReport(
  ShopGroup shopGroup,
  VoiceLanguage language,
) {
  List<String> shopLines = [];
  for (int i = 0; i < shopGroup.shops.length; i++) {
    final shop = shopGroup.shops[i];
    shopLines.add(
      '${i + 1}. ${shop.name}: ₹${(shop.todaysSales ?? 0).toStringAsFixed(0)}',
    );
  }
  
  return WhatsAppMessageService.buildConsolidatedShopReport(
    shops: shopGroup.shops
        .map((shop) => {
          'name': shop.name,
          'sales': shop.todaysSales ?? 0,
        })
        .toList(),
    totalSales: shopGroup.totalSales,
    language: language,
  );
}

// Simple wrapper page for routing
class MyShopsPage extends StatelessWidget {
  const MyShopsPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Shops'),
        backgroundColor: const Color(0xFF6366F1),
      ),
      body: const Center(
        child: Text('Multi-shop dashboard - under construction'),
      ),
    );
  }
}
