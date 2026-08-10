import 'package:flutter/material.dart';
import 'dart:convert';
import 'whatsapp_message_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:intl/intl.dart';
import 'package:flutter/foundation.dart';
import 'secure_token_storage.dart';
import 'api_client.dart';
import 'local_storage_service.dart';
import 'sales_dedup_helper.dart';
import 'invoices_page.dart';
import 'khata_page.dart';

class AllTransactionsPage extends StatefulWidget {
  const AllTransactionsPage({super.key});

  static _AllTransactionsPageState? _state;
  static void refreshTransactions() {
    _state?._loadAllTransactions();
  }

  @override
  State<AllTransactionsPage> createState() => _AllTransactionsPageState();
}

class _AllTransactionsPageState extends State<AllTransactionsPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _isLoading = false;
  String _errorMessage = '';

  List<Map<String, dynamic>> _allTransactions = [];
  List<Map<String, dynamic>> _cashTransactions = [];
  List<Map<String, dynamic>> _onlineTransactions = [];
  List<Map<String, dynamic>> _khataTransactions = [];
  List<Map<String, dynamic>> _invoiceTransactions = [];

  @override
  void initState() {
    super.initState();
    AllTransactionsPage._state = this;
    _tabController = TabController(length: 5, vsync: this);
    _loadAllTransactions();
  }

  @override
  void dispose() {
    _tabController.dispose();
    if (AllTransactionsPage._state == this) {
      AllTransactionsPage._state = null;
    }
    super.dispose();
  }

  Future<void> _loadAllTransactions() async {
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getInt('user_id') ?? prefs.getInt('userId') ?? 0;
      final token = await SecureTokenStorage.getToken() ?? '';

      // Option B: dedupe before showing transactions
      await SalesDedupHelper.cleanupAndPersist();
      final sales = await LocalStorageService.loadSales();
      // Load cash transactions (manual entry)
      _cashTransactions = [];
      // Load online transactions (manual entry or detected)
      _onlineTransactions = [];
      
      // Process local sales and separate by payment method
      for (var sale in sales) {
        if (sale is! Map) continue;
        
        final paymentMethod = sale['payment_method']?.toString() ?? 'Cash';
        final amount = double.tryParse(sale['total']?.toString() ?? '0') ?? 0;
        final saleDate = sale['sale_date'] ?? sale['created_at'] ?? DateTime.now().toIso8601String();
        final customerName = sale['customer_name'] ?? 'Walk-in Customer';
        final customerPhone = sale['customer_phone'];
        final saleId = sale['sale_id'] ?? sale['id'] ?? 'sale_${DateTime.now().millisecondsSinceEpoch}';
        
        final transaction = {
          'id': saleId,
          'amount': amount,
          'date': saleDate,
          'customer': customerName,
          'customer_phone': customerPhone,
          'items': sale['items'] ?? [],
          'raw': sale,
        };

        // Categorize by payment method
        if (paymentMethod == 'Online') {
          _onlineTransactions.add({
            ...transaction,
            'type': 'Online Payment (Manual)',
            'detection_status': 'MANUAL_ENTRY', // User entered as online
          });
        } else {
          // Default to cash for all others
          _cashTransactions.add({
            ...transaction,
            'type': 'Cash Sale',
          });
        }
      }

      // Load khata ledger transactions
      _khataTransactions = [];
      try {
        if (token.isNotEmpty && userId > 0) {
          final khataResp = await ApiClient.getJson(
            '/api/khata-history',
            headers: {'Authorization': 'Bearer $token'},
          ).timeout(const Duration(seconds: 10));

          if (khataResp.statusCode == 200) {
            final data = json.decode(khataResp.body);
            if (data['history'] is List) {
              for (var item in data['history']) {
                _khataTransactions.add({
                  'id': item['id'] ?? 'khata_${DateTime.now().millisecondsSinceEpoch}',
                  'type': item['transaction_type'] ?? 'Khata',
                  'amount': double.tryParse(item['amount']?.toString() ?? '0') ?? 0,
                  'date': item['timestamp'] ?? DateTime.now().toIso8601String(),
                  'customer_phone': item['customer_phone'],
                  'description': item['description'],
                  'raw': item,
                });
              }
            }
          }
        }
      } catch (e) {
        debugPrint('⚠️ Failed to load khata transactions: $e');
      }

      // Load invoices
      _invoiceTransactions = [];
      try {
        if (token.isNotEmpty && userId > 0) {
          final invoicesResp = await ApiClient.getJson(
            '/api/invoices/',
            headers: {'Authorization': 'Bearer $token'},
          ).timeout(const Duration(seconds: 10));

          if (invoicesResp.statusCode == 200) {
            final data = json.decode(invoicesResp.body);
            if (data['invoices'] is List) {
              for (var invoice in data['invoices']) {
                _invoiceTransactions.add({
                  'id': invoice['number'] ?? 'inv_${DateTime.now().millisecondsSinceEpoch}',
                  'type': 'Invoice',
                  'amount': double.tryParse(invoice['total_amount']?.toString() ?? '0') ?? 0,
                  'date': invoice['created_date'] ?? DateTime.now().toIso8601String(),
                  'customer': invoice['customer_name'] ?? 'Unknown',
                  'customer_phone': invoice['customer_phone'],
                  'status': invoice['payment_status'] ?? 'Pending',
                  'items_count': (invoice['items'] as List?)?.length ?? 0,
                  'raw': invoice,
                });
              }
            }
          }
        }
      } catch (e) {
        debugPrint('⚠️ Failed to load invoices: $e');
      }

      // Combine all
      _allTransactions = [
        ..._cashTransactions,
        ..._onlineTransactions,
        ..._khataTransactions,
        ..._invoiceTransactions,
      ];

      // Sort by date
      _allTransactions.sort((a, b) {
        final dateA = DateTime.tryParse(a['date'].toString()) ?? DateTime.now();
        final dateB = DateTime.tryParse(b['date'].toString()) ?? DateTime.now();
        return dateB.compareTo(dateA);
      });

      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Error loading transactions: $e';
        _isLoading = false;
      });
      debugPrint('❌ Load transactions error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('📊 All Transactions'),
        elevation: 0,
        backgroundColor: const Color(0xFF1F2937),
        foregroundColor: Colors.white,
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          indicatorColor: const Color(0xFFF59E0B),
          labelColor: Colors.white,
          unselectedLabelColor: Colors.grey[400],
          tabs: [
            Tab(text: '📋 All (${_allTransactions.length})'),
            Tab(text: '💵 Cash (${_cashTransactions.length})'),
            Tab(text: '💳 Online (${_onlineTransactions.length})'),
            Tab(text: '📔 Khata (${_khataTransactions.length})'),
            Tab(text: '🧾 Invoice (${_invoiceTransactions.length})'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage.isNotEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error_outline, size: 48, color: Colors.red),
                      const SizedBox(height: 16),
                      Text(_errorMessage),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: _loadAllTransactions,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFF59E0B),
                        ),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    _buildSummaryHeader(),
                    Expanded(
                      child: TabBarView(
                        controller: _tabController,
                        children: [
                          _buildTransactionList(_allTransactions, 'All Transactions'),
                          _buildTransactionList(_cashTransactions, 'Cash Transactions'),
                          _buildTransactionList(_onlineTransactions, 'Online Transactions'),
                          _buildTransactionList(_khataTransactions, 'Khata Ledger'),
                          _buildTransactionList(_invoiceTransactions, 'Invoices'),
                        ],
                      ),
                    ),
                  ],
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _loadAllTransactions,
        backgroundColor: const Color(0xFFF59E0B),
        child: const Icon(Icons.refresh),
      ),
    );
  }

  Widget _buildSummaryHeader() {
    final totalAmount = _allTransactions.fold<double>(
      0,
      (sum, txn) => sum + (txn['amount'] as double? ?? 0),
    );

    return Container(
      color: const Color(0xFF111827),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Transaction Summary',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _summaryCard('Total', '${_allTransactions.length}', Colors.blue),
              const SizedBox(width: 10),
              _summaryCard('Cash', '${_cashTransactions.length}', Colors.green),
              const SizedBox(width: 10),
              _summaryCard('Online', '${_onlineTransactions.length}', Colors.purple),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _summaryCard('Khata', '${_khataTransactions.length}', Colors.orange),
              const SizedBox(width: 10),
              _summaryCard('Invoice', '${_invoiceTransactions.length}', Colors.cyan),
              const SizedBox(width: 10),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Total Amount',
                        style: TextStyle(color: Colors.amber[600], fontSize: 11),
                      ),
                      Text(
                        '₹${totalAmount.toStringAsFixed(0)}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _summaryCard(String label, String count, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(color: color, fontSize: 11),
            ),
            Text(
              count,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTransactionList(
      List<Map<String, dynamic>> transactions, String emptyLabel) {
    if (transactions.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.receipt_long_outlined,
                size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text('No $emptyLabel',
                style: TextStyle(color: Colors.grey[500], fontSize: 16)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: transactions.length,
      itemBuilder: (context, index) {
        final txn = transactions[index];
        return _buildTransactionCard(txn);
      },
    );
  }

  Widget _buildTransactionCard(Map<String, dynamic> txn) {
    final amount = txn['amount'] as double? ?? 0.0;
    var date = DateTime.tryParse(txn['date'].toString()) ?? DateTime.now();
    // Convert UTC to local time if the string contains timezone info
    final dateStr = txn['date'].toString();
    if (dateStr.contains('Z') || dateStr.contains('+') || date.isUtc) {
      date = date.toLocal();
    }
    final formattedDate = DateFormat('dd MMM yyyy, hh:mm a').format(date);
    final customerPhone = txn['customer_phone'] as String?;
    final detectionStatus = txn['detection_status'] as String?;

    IconData icon = Icons.receipt;
    Color badgeColor = Colors.blue;

    final type = (txn['type'] as String?)?.toLowerCase() ?? '';
    if (type.contains('cash')) {
      icon = Icons.payments;
      badgeColor = Colors.green;
    } else if (type.contains('online') || type.contains('upi') || type.contains('card')) {
      icon = Icons.credit_card;
      badgeColor = Colors.purple;
    } else if (type.contains('khata')) {
      icon = Icons.book;
      badgeColor = Colors.orange;
    } else if (type.contains('invoice')) {
      icon = Icons.description;
      badgeColor = Colors.blue;
    }

    // For invoices, make them tappable/interactive
    bool isInvoice = type.contains('invoice');
    
    return GestureDetector(
      onTap: isInvoice ? () => _handleInvoiceTap(txn) : null,
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 8),
        color: Colors.grey[900],
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row: Icon, Type, Amount
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: badgeColor.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(icon, color: badgeColor, size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                txn['type'].toString(),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            // Detection status badge for online payments
                            if (detectionStatus == 'APP_DETECTED')
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF10B981).withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                                child: const Text(
                                  '🔍 APP DETECTED',
                                  style: TextStyle(
                                    color: Color(0xFF10B981),
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          formattedDate,
                          style: TextStyle(
                            color: Colors.grey[400],
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '₹${amount.toStringAsFixed(2)}',
                    style: TextStyle(
                      color: badgeColor,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              
              // Customer Phone - prominently displayed for all types
              if (customerPhone != null && customerPhone.toString().isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.phone, color: Colors.blue, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          customerPhone.toString(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (customerPhone != null && customerPhone.toString().isNotEmpty)
                const SizedBox(height: 8),
              
              // Other transaction details
              _buildTransactionDetails(txn),
              
              // Action buttons for invoices
              if (isInvoice) ...[
                const SizedBox(height: 12),
                _buildInvoiceActionButtons(txn),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTransactionDetails(Map<String, dynamic> txn) {
    final type = (txn['type'] as String?)?.toLowerCase() ?? '';
    final details = <Widget>[];

    if (type.contains('cash')) {
      if (txn['customer'] != null) {
        details.add(_detailRow('Customer', txn['customer'].toString()));
      }
      if (txn['items'] != null && (txn['items'] as List).isNotEmpty) {
        final itemCount = (txn['items'] as List).length;
        details.add(_detailRow('Items', '$itemCount item(s)'));
      }
    } else if (type.contains('online') || type.contains('upi') || type.contains('card')) {
      if (txn['customer'] != null) {
        details.add(_detailRow('Customer', txn['customer'].toString()));
      }
      if (txn['reference'] != null) {
        details.add(_detailRow('Reference ID', txn['reference'].toString()));
      }
    } else if (type.contains('khata')) {
      if (txn['description'] != null) {
        details.add(_detailRow('Description', txn['description'].toString()));
      }
    } else if (type.contains('invoice')) {
      if (txn['customer'] != null) {
        details.add(_detailRow('Customer', txn['customer'].toString()));
      }
      if (txn['status'] != null) {
        final statusColor = txn['status'] == 'Paid' ? Colors.green : Colors.orange;
        details.add(
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Status', style: TextStyle(color: Colors.grey)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  txn['status'].toString(),
                  style: TextStyle(color: statusColor, fontSize: 12),
                ),
              ),
            ],
          ),
        );
      }
      if (txn['items_count'] != null) {
        details.add(_detailRow('Items', '${txn['items_count']} items'));
      }
    }

    return Column(
      children: [
        ...details.asMap().entries.map((e) {
          return Padding(
            padding: EdgeInsets.only(top: e.key > 0 ? 8 : 0),
            child: e.value,
          );
        }),
      ],
    );
  }

  Widget _detailRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(color: Colors.grey[400], fontSize: 12),
        ),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(color: Colors.white, fontSize: 12),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  /// 💰 Build action buttons for invoices
  Widget _buildInvoiceActionButtons(Map<String, dynamic> txn) {
    final status = txn['status']?.toString().toUpperCase() ?? 'DRAFT';
    final isPaid = status == 'PAID';

    return Row(
      children: [
        if (!isPaid)
          Expanded(
            child: ElevatedButton.icon(
              onPressed: () => _markInvoiceAsPaid(txn),
              icon: const Icon(Icons.check_circle),
              label: const Text('Mark Paid'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF10B981),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
        if (isPaid) ...[
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green.withValues(alpha: 0.5)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.check_circle, color: Colors.green, size: 18),
                  const SizedBox(width: 6),
                  const Text(
                    'Paid',
                    style: TextStyle(color: Colors.green, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: () => _markInvoiceAsUnpaid(txn),
            icon: const Icon(Icons.undo),
            label: const Text('Unpaid'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            ),
          ),
        ],
      ],
    );
  }

  /// 🎯 Handle invoice tap (mark as paid dialog)
  Future<void> _handleInvoiceTap(Map<String, dynamic> txn) async {
    final status = txn['status']?.toString().toUpperCase() ?? 'DRAFT';
    if (status == 'PAID') return; // Already paid

    final invoiceNum = txn.containsKey('invoice_number') 
        ? txn['invoice_number']?.toString() ?? txn['id']?.toString() ?? ''
        : txn['id']?.toString() ?? '';

    if (invoiceNum.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mark as Paid?'),
        content: Text('Mark invoice $invoiceNum as PAID?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
            child: const Text('Confirm', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _markInvoiceAsPaid(txn);
    }
  }

  /// 💾 Mark invoice as paid (sync with invoices_page)
  Future<void> _markInvoiceAsPaid(Map<String, dynamic> inv) async {
    final invoiceNum = inv.containsKey('invoice_number') 
        ? inv['invoice_number']?.toString() ?? inv['id']?.toString() ?? ''
        : inv['id']?.toString() ?? '';

    if (invoiceNum.isEmpty) return;

    try {
      final customerPhone = inv['customer_phone']?.toString() ?? '';
      final amount = inv['amount'] as double? ?? 0.0;

      // 1. Update local invoices
      final localInvs = await LocalStorageService.loadLocalInvoices();
      for (var i = 0; i < localInvs.length; i++) {
        if (localInvs[i]['invoice_number']?.toString() == invoiceNum || 
            localInvs[i]['id']?.toString() == invoiceNum) {
          localInvs[i]['payment_status'] = 'PAID';
          localInvs[i]['status'] = 'PAID';
          localInvs[i]['paid_date'] = DateTime.now().toIso8601String();
          break;
        }
      }
      await LocalStorageService.saveLocalInvoices(localInvs);

      // 2. Update sales history
      final List<dynamic> history = await LocalStorageService.loadSales();
      for (var i = 0; i < history.length; i++) {
        final sId = (history[i]['sale_id'] ?? history[i]['id'] ?? history[i]['invoice_number'] ?? '').toString();
        if (sId == invoiceNum) {
          history[i]['payment_status'] = 'PAID';
          history[i]['status'] = 'PAID';
          history[i]['paid_amount'] = history[i]['total'] ?? history[i]['total_amount'] ?? 0.0;
          break;
        }
      }
      await LocalStorageService.saveSales(history);

      // 3. Update khata if customer phone exists
      if (customerPhone.isNotEmpty && amount > 0) {
        final khataBalances = await LocalStorageService.loadKhataBalances();
        if (khataBalances.containsKey(customerPhone)) {
          khataBalances[customerPhone] = (khataBalances[customerPhone] ?? 0) - amount;
          if (khataBalances[customerPhone]! < 0) {
            khataBalances[customerPhone] = 0;
          }
          await LocalStorageService.saveKhataBalances(khataBalances);
        }
      }

      // 4. Sync to backend
      final token = await SecureTokenStorage.getToken();
      if (token != null && token.isNotEmpty) {
        try {
          await ApiClient.postJson(
            '/api/invoices/$invoiceNum/mark-paid/',
            {
              'payment_status': 'PAID',
              'paid_date': DateTime.now().toIso8601String(),
              'customer_phone': customerPhone,
              'amount': amount,
            },
            headers: {'Authorization': 'Bearer $token'},
          ).timeout(const Duration(seconds: 10));
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Backend sync failed: $e');
        }
      }

      // 5. ✅ Refresh both views
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Invoice marked as PAID'),
            backgroundColor: Color(0xFF10B981),
            duration: Duration(seconds: 2),
          ),
        );
      }
      
      // Reload this page
      await _loadAllTransactions();
      
      // Also trigger invoices_page refresh by calling its static method
      InvoicesPage.refreshInvoices();
      
      // Also refresh khata page (customer balances)
      KhataPage.refreshKhata();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  /// 🔄 Mark invoice as unpaid (revert from paid)
  Future<void> _markInvoiceAsUnpaid(Map<String, dynamic> inv) async {
    final invoiceNum = inv.containsKey('invoice_number') 
        ? inv['invoice_number']?.toString() ?? inv['id']?.toString() ?? ''
        : inv['id']?.toString() ?? '';

    if (invoiceNum.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mark as Unpaid?'),
        content: Text('Revert invoice $invoiceNum back to UNPAID status?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            child: const Text('Confirm', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final customerPhone = inv['customer_phone']?.toString() ?? '';
      final amount = inv['amount'] as double? ?? 0.0;

      // 1. Update local invoices
      final localInvs = await LocalStorageService.loadLocalInvoices();
      for (var i = 0; i < localInvs.length; i++) {
        if (localInvs[i]['invoice_number']?.toString() == invoiceNum || 
            localInvs[i]['id']?.toString() == invoiceNum) {
          localInvs[i]['payment_status'] = 'UNPAID';
          localInvs[i]['status'] = 'UNPAID';
          localInvs[i]['updated_at'] = DateTime.now().toIso8601String();
          break;
        }
      }
      await LocalStorageService.saveLocalInvoices(localInvs);

      // 2. Revert sales history
      final List<dynamic> history = await LocalStorageService.loadSales();
      for (var i = 0; i < history.length; i++) {
        final sId = (history[i]['sale_id'] ?? history[i]['id'] ?? history[i]['invoice_number'] ?? '').toString();
        if (sId == invoiceNum) {
          history[i]['payment_status'] = 'UNPAID';
          history[i]['status'] = 'UNPAID';
          history[i]['paid_amount'] = 0.0;
          break;
        }
      }
      await LocalStorageService.saveSales(history);

      // 3. Restore khata balance
      if (customerPhone.isNotEmpty && amount > 0) {
        final khataBalances = await LocalStorageService.loadKhataBalances();
        khataBalances[customerPhone] = (khataBalances[customerPhone] ?? 0) + amount;
        await LocalStorageService.saveKhataBalances(khataBalances);
      }

      // 4. Sync to backend
      final token = await SecureTokenStorage.getToken();
      if (token != null && token.isNotEmpty) {
        try {
          await ApiClient.postJson(
            '/api/invoices/$invoiceNum/mark-unpaid/',
            {
              'payment_status': 'UNPAID',
              'updated_at': DateTime.now().toIso8601String(),
              'customer_phone': customerPhone,
              'amount': amount,
            },
            headers: {'Authorization': 'Bearer $token'},
          ).timeout(const Duration(seconds: 10));
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Backend sync failed: $e');
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('↩️ Invoice reverted to UNPAID'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 2),
          ),
        );
      }
      
      await _loadAllTransactions();
      InvoicesPage.refreshInvoices();
      KhataPage.refreshKhata();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }
}
