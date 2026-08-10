import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dart:async';
import 'dart:convert';
import 'local_storage_service.dart';
import 'whatsapp_message_service.dart';
import 'api_client.dart';
import 'sync_queue_manager.dart';
import 'sync_service.dart';
import 'visual_widgets.dart';

class KhataPage extends StatefulWidget {
  final String? focusPhone;
  const KhataPage({super.key, this.focusPhone});

  static _KhataPageState? _state;
  static void refreshKhata() {
    _state?._loadKhata();
    _state?._loadInvoiceAnalytics();
  }

  @override
  State<KhataPage> createState() => _KhataPageState();
}

class _KhataPageState extends State<KhataPage> with SingleTickerProviderStateMixin {
  static const Color _primary = AppColors.primary;     // #635BFF
  static const Color _danger = Color(0xFFEF4444);      // Red
  static const Color _success = Color(0xFF10B981);     // Green
  static const Color _warning = Color(0xFFF59E0B);     // Amber

  List<Map<String, dynamic>> _customers = [];
  List<Map<String, dynamic>> _filteredCustomers = [];
  
  // Analytics State
  double _totalOutstanding = 0.0;
  double _totalOverdue = 0.0;
  double _collectedToday = 0.0;
  double _dueThisWeek = 0.0;
  int _pendingCount = 0;
  int _overdueCount = 0;

  bool _loading = true;
  String _searchQuery = '';
  String _activeFilter = 'ALL'; // ALL, OVERDUE, HIGH_BALANCE
  final TextEditingController _searchController = TextEditingController();

  // ── Invoice Analytics Tab State ──
  late final TabController _tabController;
  bool _invoicesLoading = true;
  List<Map<String, dynamic>> _allInvoices = [];
  String _invoiceStatusFilter = 'ALL'; // ALL, PAID, PARTIAL, UNPAID
  double _invoicedTotal = 0.0;
  double _paidTotal = 0.0;
  double _pendingTotal = 0.0;
  int _paidCount = 0;
  int _partialCount = 0;
  int _unpaidCount = 0;

  // Search / sort for invoice list
  String _invoiceSearchQuery = '';
  final TextEditingController _invoiceSearchController = TextEditingController();
  String _invoiceSortOption = 'DATE_DESC'; // DATE_DESC, DATE_ASC, AMOUNT_DESC, AMOUNT_ASC, STATUS

  // Top customers ranked by UNCLEARED (outstanding) amount, not total revenue
  List<Map<String, dynamic>> _topOutstandingCustomers = [];

  @override
  void initState() {
    super.initState();
    KhataPage._state = this;
    _tabController = TabController(length: 2, vsync: this);
    
    // Load local data immediately
    _loadKhata();
    _loadInvoiceAnalytics();
    
    // Sync with backend after a short delay
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        _loadKhata();
        _loadInvoiceAnalytics();
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _invoiceSearchController.dispose();
    _tabController.dispose();
    if (KhataPage._state == this) {
      KhataPage._state = null;
    }
    super.dispose();
  }

  /// Loads all local invoices and computes payment-status analytics
  /// (Paid / Partial / Unpaid) plus totals for the Invoices tab.
  Future<void> _loadInvoiceAnalytics() async {
    if (!mounted) return;
    setState(() => _invoicesLoading = true);

    try {
      final raw = await LocalStorageService.loadLocalInvoices();
      final invoices = raw
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      // Sort newest first for the list view
      invoices.sort((a, b) {
        final da = DateTime.tryParse(a['invoice_date']?.toString() ?? a['created_at']?.toString() ?? '') ?? DateTime(2000);
        final db = DateTime.tryParse(b['invoice_date']?.toString() ?? b['created_at']?.toString() ?? '') ?? DateTime(2000);
        return db.compareTo(da);
      });

      double invoiced = 0.0;
      double paid = 0.0;
      int paidCount = 0;
      int partialCount = 0;
      int unpaidCount = 0;

      // customer key -> {name, phone, outstanding}
      final Map<String, Map<String, dynamic>> outstandingByCustomer = {};

      for (final inv in invoices) {
        final total = (inv['total_amount'] as num?)?.toDouble() ??
            double.tryParse(inv['total_amount']?.toString() ?? inv['total']?.toString() ?? '0') ??
            0.0;
        final paidAmt = (inv['paid_amount'] as num?)?.toDouble() ??
            double.tryParse(inv['paid_amount']?.toString() ?? '0') ??
            0.0;

        invoiced += total;
        paid += paidAmt.clamp(0, total);

        final status = (inv['payment_status']?.toString() ?? _deriveStatus(total, paidAmt)).toUpperCase();
        if (status == 'PAID') {
          paidCount++;
        } else if (status == 'PARTIAL') {
          partialCount++;
        } else {
          unpaidCount++;
        }

        // Uncleared amount for this invoice (0 if fully paid)
        final outstanding = (total - paidAmt).clamp(0, double.infinity);
        if (outstanding > 0.01) {
          final name = inv['customer_name']?.toString().trim();
          final phone = inv['customer_phone']?.toString().trim() ?? '';
          final displayName = (name == null || name.isEmpty) ? 'Guest Customer' : name;
          // Key by phone when available so the same person's invoices merge together
          final key = phone.isNotEmpty ? phone : displayName;

          final existing = outstandingByCustomer[key];
          if (existing != null) {
            existing['outstanding'] = (existing['outstanding'] as double) + outstanding;
            existing['invoice_count'] = (existing['invoice_count'] as int) + 1;
          } else {
            outstandingByCustomer[key] = {
              'name': displayName,
              'phone': phone,
              'outstanding': outstanding,
              'invoice_count': 1,
            };
          }
        }
      }

      final topOutstanding = outstandingByCustomer.values.toList()
        ..sort((a, b) => (b['outstanding'] as double).compareTo(a['outstanding'] as double));

      if (!mounted) return;
      setState(() {
        _allInvoices = invoices;
        _invoicedTotal = invoiced;
        _paidTotal = paid;
        _pendingTotal = (invoiced - paid).clamp(0, double.infinity);
        _paidCount = paidCount;
        _partialCount = partialCount;
        _unpaidCount = unpaidCount;
        _topOutstandingCustomers = topOutstanding.take(5).toList();
        _invoicesLoading = false;
      });
    } catch (e) {
      if (kDebugMode) debugPrint('Error loading invoice analytics: $e');
      if (mounted) setState(() => _invoicesLoading = false);
    }
  }

  String _deriveStatus(double total, double paid) {
    if (paid >= total - 0.5) return 'PAID';
    if (paid > 0) return 'PARTIAL';
    return 'UNPAID';
  }

  List<Map<String, dynamic>> get _filteredInvoices {
    List<Map<String, dynamic>> list = _invoiceStatusFilter == 'ALL'
        ? List.from(_allInvoices)
        : _allInvoices.where((inv) {
            final total = (inv['total_amount'] as num?)?.toDouble() ??
                double.tryParse(inv['total_amount']?.toString() ?? inv['total']?.toString() ?? '0') ??
                0.0;
            final paidAmt = (inv['paid_amount'] as num?)?.toDouble() ??
                double.tryParse(inv['paid_amount']?.toString() ?? '0') ??
                0.0;
            final status = (inv['payment_status']?.toString() ?? _deriveStatus(total, paidAmt)).toUpperCase();
            return status == _invoiceStatusFilter;
          }).toList();

    // Search by customer name or invoice/sale number
    if (_invoiceSearchQuery.trim().isNotEmpty) {
      final q = _invoiceSearchQuery.trim().toLowerCase();
      list = list.where((inv) {
        final name = (inv['customer_name'] ?? '').toString().toLowerCase();
        final phone = (inv['customer_phone'] ?? '').toString().toLowerCase();
        final number = (inv['invoice_number'] ?? inv['sale_id'] ?? '').toString().toLowerCase();
        return name.contains(q) || phone.contains(q) || number.contains(q);
      }).toList();
    }

    double totalOf(Map<String, dynamic> inv) =>
        (inv['total_amount'] as num?)?.toDouble() ??
        double.tryParse(inv['total_amount']?.toString() ?? inv['total']?.toString() ?? '0') ??
        0.0;
    DateTime dateOf(Map<String, dynamic> inv) =>
        DateTime.tryParse(inv['invoice_date']?.toString() ?? inv['created_at']?.toString() ?? '') ?? DateTime(2000);

    switch (_invoiceSortOption) {
      case 'DATE_ASC':
        list.sort((a, b) => dateOf(a).compareTo(dateOf(b)));
        break;
      case 'AMOUNT_DESC':
        list.sort((a, b) => totalOf(b).compareTo(totalOf(a)));
        break;
      case 'AMOUNT_ASC':
        list.sort((a, b) => totalOf(a).compareTo(totalOf(b)));
        break;
      case 'STATUS':
        list.sort((a, b) {
          const order = {'UNPAID': 0, 'PARTIAL': 1, 'PAID': 2};
          final sa = (a['payment_status']?.toString() ?? _deriveStatus(totalOf(a), 0)).toUpperCase();
          final sb = (b['payment_status']?.toString() ?? _deriveStatus(totalOf(b), 0)).toUpperCase();
          return (order[sa] ?? 3).compareTo(order[sb] ?? 3);
        });
        break;
      case 'DATE_DESC':
      default:
        list.sort((a, b) => dateOf(b).compareTo(dateOf(a)));
    }

    return list;
  }

  Future<void> _loadKhata() async {
    if (!mounted) return;
    setState(() => _loading = true);

    try {
      // 1. Load from local storage first (immediate response)
      await _loadKhataLocalFallback();
      
      // 2. Then try to sync with backend (background update)
      try {
        final summaryResp = await ApiClient.getJson('/api/khata/pending-summary');
        final listResp = await ApiClient.getJson('/api/khata/pending-customers');

        if (summaryResp.statusCode == 200 && listResp.statusCode == 200) {
          final sumData = json.decode(summaryResp.body);
          final listData = json.decode(listResp.body);

          _totalOutstanding = (sumData['total_outstanding'] as num?)?.toDouble() ?? 0.0;
          _totalOverdue = (sumData['total_overdue'] as num?)?.toDouble() ?? 0.0;
          _collectedToday = (sumData['collected_today'] as num?)?.toDouble() ?? 0.0;
          _dueThisWeek = (sumData['due_this_week'] as num?)?.toDouble() ?? 0.0;
          _pendingCount = (sumData['pending_customers_count'] as num?)?.toInt() ?? 0;
          _overdueCount = (sumData['overdue_customers_count'] as num?)?.toInt() ?? 0;

          final rawList = List<Map<String, dynamic>>.from(listData['customers'] ?? []);
          _customers = rawList.where((c) {
            double bal = (c['balance'] as num?)?.toDouble() ?? 0.0;
            return bal > 0;
          }).toList();
          
          if (kDebugMode) debugPrint('✅ Backend khata data loaded successfully');
        } else {
          if (kDebugMode) debugPrint('⚠️ Backend khata returned non-200 status, using local data');
        }
      } catch (e) {
        if (kDebugMode) debugPrint('⚠️ Backend khata sync failed: $e, using local data');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Error loading khata: $e');
    }

    _applyFilter();

    if (mounted) {
      setState(() => _loading = false);
    }
  }

  Future<void> _loadKhataLocalFallback() async {
    var unified = await LocalStorageService.loadUnifiedCustomersLedger();
    _customers = [];
    _totalOutstanding = 0.0;
    _totalOverdue = 0.0;
    _pendingCount = 0;
    _overdueCount = 0;

    if (kDebugMode) debugPrint('📦 Loading ${unified.length} customers from local storage');

    for (var c in unified) {
      // FIX: loadUnifiedCustomersLedger() returns 'unified_balance' and
      // 'history', not 'balance' and 'invoices'. Reading the wrong keys
      // meant `bal` was always 0.0 here, so this tab silently showed zero
      // pending customers even when real outstanding balances existed
      // locally — every time the backend call above failed or was slow
      // (exactly the offline-first case), this was the only data source.
      double bal = (c['unified_balance'] as num?)?.toDouble() ?? 0.0;
      if (bal > 0.01) {
        _totalOutstanding += bal;
        _pendingCount++;
        _customers.add({
          'customer_id': c['phone'],
          'customer_name': c['name'] ?? 'Customer',
          'customer_phone': c['phone'] ?? '',
          'total_balance': bal,
          'overdue_amount': bal,
          'is_overdue': false,
          'days_overdue': 0,
          'earliest_due_date': c['due_date'],
          'invoices': c['history'] ?? []
        });
      }
    }
  }

  void _applyFilter() {
    List<Map<String, dynamic>> temp = List.from(_customers);

    // Search filter
    if (_searchQuery.trim().isNotEmpty) {
      final q = _searchQuery.trim().toLowerCase();
      temp = temp.where((c) {
        final name = (c['customer_name'] ?? '').toString().toLowerCase();
        final phone = (c['customer_phone'] ?? '').toString().toLowerCase();
        return name.contains(q) || phone.contains(q);
      }).toList();
    }

    // Filter Chips
    if (_activeFilter == 'OVERDUE') {
      temp = temp.where((c) => c['is_overdue'] == true).toList();
    } else if (_activeFilter == 'HIGH_BALANCE') {
      temp = temp.where((c) => (c['total_balance'] as num? ?? 0) >= 1000).toList();
    }

    _filteredCustomers = temp;
  }

  Future<void> _makePhoneCall(String phone) async {
    if (phone.isEmpty) {
      _showToast('No phone number registered for this customer');
      return;
    }
    final url = 'tel:${phone.replaceAll(RegExp(r'[^\d+]'), '')}';
    if (await canLaunchUrlString(url)) {
      await launchUrlString(url);
    } else {
      _showToast('Could not launch phone dialer');
    }
  }

  Future<void> _sendWhatsAppReminder(Map<String, dynamic> customer) async {
    final phone = customer['customer_phone']?.toString() ?? '';
    final name = customer['customer_name']?.toString() ?? 'Customer';
    final balance = (customer['total_balance'] as num?)?.toDouble() ?? 0.0;
    final dueDate = customer['earliest_due_date']?.toString() ?? 'As soon as possible';

    if (phone.isEmpty) {
      _showToast('No phone number available for WhatsApp');
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final shopName = prefs.getString('shop_name') ?? prefs.getString('user_name') ?? 'Our Store';
    final upiId = prefs.getString('upi_id') ?? prefs.getString('shop_upi_id') ?? prefs.getString('upi_vpa');

    final success = await WhatsAppMessageService.sendPaymentReminderWithUPI(
      phone: phone,
      customerName: name,
      pendingAmount: balance,
      shopName: shopName,
      upiId: upiId,
      dueDate: dueDate,
    );

    if (success) {
      _showToast('WhatsApp reminder opened for $name!');
    } else {
      _showToast('Could not launch WhatsApp app');
    }
  }

  Future<void> _batchWhatsAppAllOverdue() async {
    final overdueList = _customers.where((c) => c['is_overdue'] == true || (c['total_balance'] as num? ?? 0) > 0).toList();

    if (overdueList.isEmpty) {
      _showToast('No pending overdue customers to notify');
      return;
    }

    _showToast('Sending WhatsApp reminder to ${overdueList.length} customers...');

    for (var c in overdueList) {
      await _sendWhatsAppReminder(c);
      await Future.delayed(const Duration(milliseconds: 600));
    }
  }

  void _showPaymentModal(Map<String, dynamic> customer) {
    final TextEditingController amountController = TextEditingController(
      text: (customer['total_balance'] as num?)?.toStringAsFixed(2) ?? '0.00',
    );
    final TextEditingController notesController = TextEditingController();
    String selectedMethod = 'CASH';
    bool isSubmitting = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom + 20,
                top: 24,
                left: 24,
                right: 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Settle Udhar / Payment',
                            style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.bold, color: const Color(0xFF1E293B)),
                          ),
                          Text(
                            customer['customer_name'] ?? 'Customer',
                            style: GoogleFonts.inter(fontSize: 14, color: AppColors.textMuted),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _primary.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _primary.withValues(alpha: 0.2)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Current Pending Balance:', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w500)),
                        Text(
                          '₹${((customer['total_balance'] as num?)?.toDouble() ?? 0.0).toStringAsFixed(2)}',
                          style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.bold, color: _primary),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: amountController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: 'Payment Received (₹)',
                      prefixIcon: const Icon(Icons.currency_rupee),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('Payment Mode:', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Row(
                    children: ['CASH', 'UPI', 'CARD', 'TRANSFER'].map((method) {
                      final isSelected = selectedMethod == method;
                      return Expanded(
                        child: GestureDetector(
                          onTap: () => setModalState(() => selectedMethod = method),
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                              color: isSelected ? _primary : Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: isSelected ? _primary : Colors.grey.shade300),
                            ),
                            child: Text(
                              method,
                              textAlign: TextAlign.center,
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: isSelected ? Colors.white : Colors.black87,
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: notesController,
                    decoration: InputDecoration(
                      labelText: 'Notes / Payment Ref (Optional)',
                      prefixIcon: const Icon(Icons.note_alt_outlined),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: isSubmitting
                          ? null
                          : () async {
                              final amt = double.tryParse(amountController.text.trim()) ?? 0.0;
                              if (amt <= 0) {
                                _showToast('Please enter a valid payment amount');
                                return;
                              }

                              setModalState(() => isSubmitting = true);

                              final paymentPayload = {
                                'customer_phone': customer['customer_phone'],
                                'customer_id': customer['customer_id'],
                                'amount': amt,
                                'payment_method': selectedMethod,
                                'notes': notesController.text.trim(),
                              };

                              try {
                                final resp = await ApiClient.postJson(
                                  '/api/khata/record-payment',
                                  paymentPayload,
                                ).timeout(const Duration(seconds: 15));

                                if (resp.statusCode == 200) {
                                  if (ctx.mounted) Navigator.pop(ctx);
                                  _showToast('✅ Payment of ₹$amt recorded successfully!');
                                  _loadKhata();
                                } else {
                                  final errData = json.decode(resp.body);
                                  _showToast('Payment record failed: ${errData['detail']}');
                                }
                              } catch (e) {
                                // 🔧 FIX (data loss): this used to just show
                                // an error toast and discard the payment —
                                // no offline queue, no retry, nothing saved.
                                // A shopkeeper recording a customer's cash/
                                // UPI payment while offline (or during any
                                // network blip) would believe it was saved
                                // when it was actually gone. Now it's queued
                                // for automatic retry the same durable way
                                // sales and purchase orders already are.
                                await SyncQueueManager.enqueue('record_khata_payment', paymentPayload);
                                unawaited(SyncService.processQueueSafe());
                                if (ctx.mounted) Navigator.pop(ctx);
                                _showToast('⚠️ No connection — payment of ₹$amt saved and will sync automatically.');
                                _loadKhata();
                              } finally {
                                if (ctx.mounted) setModalState(() => isSubmitting = false);
                              }
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _success,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: isSubmitting
                          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : Text('Record Payment', style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showDeadlineModal(Map<String, dynamic> customer) {
    DateTime selectedDate = DateTime.now().add(const Duration(days: 7));
    bool isSaving = false;

    showDatePicker(
      context: context,
      initialDate: selectedDate,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    ).then((picked) async {
      if (picked != null) {
        final dateStr = "${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}";
        try {
          final resp = await ApiClient.postJson('/api/khata/update-deadline', {
            'customer_phone': customer['customer_phone'],
            'customer_id': customer['customer_id'],
            'due_date': dateStr,
          });

          if (resp.statusCode == 200) {
            _showToast('⏰ Payment deadline set to $dateStr');
            _loadKhata();
          } else {
            _showToast('Failed to update deadline');
          }
        } catch (e) {
          _showToast('Error setting deadline: $e');
        }
      }
    });
  }

  void _showToast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: GoogleFonts.inter(color: Colors.white, fontWeight: FontWeight.w500)),
        backgroundColor: const Color(0xFF1E293B),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: Text(
          'Khata & Pending Udhar',
          style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.bold, color: const Color(0xFF0F172A)),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFF0F172A)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () {
              _loadKhata();
              _loadInvoiceAnalytics();
            },
            tooltip: 'Refresh',
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          labelColor: _primary,
          unselectedLabelColor: const Color(0xFF64748B),
          indicatorColor: _primary,
          labelStyle: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.bold),
          unselectedLabelStyle: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w500),
          tabs: const [
            Tab(text: 'Pending Udhar'),
            Tab(text: 'Invoice Analytics'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildKhataTab(),
          _buildInvoiceAnalyticsTab(),
        ],
      ),
    );
  }

  Widget _buildKhataTab() {
    return _loading
        ? const Center(child: CircularProgressIndicator(color: _primary))
        : RefreshIndicator(
            onRefresh: _loadKhata,
            color: _primary,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 1. ANALYTICS HEADER CARDS
                  _buildAnalyticsHeader(),

                  const SizedBox(height: 16),

                  // 2. BATCH ACTION & SEARCH BAR
                  _buildSearchBarAndActions(),

                  const SizedBox(height: 12),

                  // 3. FILTER CHIPS
                  _buildFilterChips(),

                  const SizedBox(height: 16),

                  // 4. CUSTOMER PENDING LIST
                  if (_filteredCustomers.isEmpty)
                    _buildEmptyState()
                  else
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _filteredCustomers.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (ctx, idx) => _buildCustomerCard(_filteredCustomers[idx]),
                    ),
                ],
              ),
            ),
          );
  }

  Widget _buildAnalyticsHeader() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF4F46E5), Color(0xFF635BFF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: _primary.withValues(alpha: 0.3),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'TOTAL OUTSTANDING UDHAR',
                    style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white70, letterSpacing: 0.8),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '₹${_totalOutstanding.toStringAsFixed(2)}',
                    style: GoogleFonts.inter(fontSize: 28, fontWeight: FontWeight.w900, color: Colors.white),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.people_alt_outlined, color: Colors.white, size: 16),
                    const SizedBox(width: 6),
                    Text(
                      '$_pendingCount Pending',
                      style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(color: Colors.white24, height: 1),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildMiniStat('Overdue Amount', '₹${_totalOverdue.toStringAsFixed(0)}', _danger),
              _buildMiniStat('Due This Week', '₹${_dueThisWeek.toStringAsFixed(0)}', _warning),
              _buildMiniStat('Paid Today', '₹${_collectedToday.toStringAsFixed(0)}', _success),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMiniStat(String label, String value, Color badgeColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: badgeColor, shape: BoxShape.circle)),
            const SizedBox(width: 4),
            Text(label, style: GoogleFonts.inter(fontSize: 11, color: Colors.white70)),
          ],
        ),
        const SizedBox(height: 2),
        Text(value, style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
      ],
    );
  }

  Widget _buildSearchBarAndActions() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _searchController,
            onChanged: (val) {
              _searchQuery = val;
              setState(() => _applyFilter());
            },
            decoration: InputDecoration(
              hintText: 'Search by customer or phone...',
              prefixIcon: const Icon(Icons.search, color: Color(0xFF64748B)),
              fillColor: Colors.white,
              filled: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: Colors.grey.shade300),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: Colors.grey.shade200),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          onPressed: _batchWhatsAppAllOverdue,
          icon: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
          style: IconButton.styleFrom(
            backgroundColor: const Color(0xFF25D366),
            padding: const EdgeInsets.all(12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          tooltip: 'WhatsApp All Overdue',
        ),
      ],
    );
  }

  Widget _buildFilterChips() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _buildChip('ALL', 'All Pending (${_customers.length})'),
          const SizedBox(width: 8),
          _buildChip('OVERDUE', 'Overdue (${_overdueCount})', color: _danger),
          const SizedBox(width: 8),
          _buildChip('HIGH_BALANCE', 'High Balance (>₹1000)', color: _warning),
        ],
      ),
    );
  }

  Widget _buildChip(String key, String label, {Color? color}) {
    final isSelected = _activeFilter == key;
    final activeColor = color ?? _primary;

    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) {
        setState(() {
          _activeFilter = key;
          _applyFilter();
        });
      },
      selectedColor: activeColor.withValues(alpha: 0.15),
      backgroundColor: Colors.white,
      labelStyle: GoogleFonts.inter(
        fontSize: 12,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
        color: isSelected ? activeColor : const Color(0xFF64748B),
      ),
      side: BorderSide(color: isSelected ? activeColor : Colors.grey.shade200),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    );
  }

  Widget _buildCustomerCard(Map<String, dynamic> c) {
    final name = c['customer_name'] ?? 'Customer';
    final phone = c['customer_phone'] ?? '';
    final balance = (c['total_balance'] as num?)?.toDouble() ?? 0.0;
    final isOverdue = c['is_overdue'] == true;
    final daysOverdue = (c['days_overdue'] as num?)?.toInt() ?? 0;
    final invoices = List<Map<String, dynamic>>.from(c['invoices'] ?? []);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isOverdue ? _danger.withValues(alpha: 0.3) : Colors.grey.shade200),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: isOverdue ? _danger.withValues(alpha: 0.1) : _primary.withValues(alpha: 0.1),
                  child: Text(
                    name.isNotEmpty ? name[0].toUpperCase() : 'C',
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: isOverdue ? _danger : _primary,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.bold, color: const Color(0xFF0F172A))),
                      if (phone.isNotEmpty)
                        Text(phone, style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF64748B))),
                      if (isOverdue)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '⚠️ Overdue by $daysOverdue days',
                            style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.bold, color: _danger),
                          ),
                        ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('₹${balance.toStringAsFixed(2)}', style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w900, color: _primary)),
                    Text('${invoices.length} bill(s)', style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF94A3B8))),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFFF1F5F9)),
          // ACTION BUTTONS BAR
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildActionButton(Icons.call_rounded, 'Call', Colors.blue, () => _makePhoneCall(phone)),
                _buildActionButton(Icons.chat_bubble_outline_rounded, 'WhatsApp', const Color(0xFF25D366), () => _sendWhatsAppReminder(c)),
                _buildActionButton(Icons.check_circle_outline_rounded, 'Mark Paid', _success, () => _showPaymentModal(c)),
                _buildActionButton(Icons.calendar_month_outlined, 'Deadline', _warning, () => _showDeadlineModal(c)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton(IconData icon, String label, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 4),
            Text(label, style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Column(
          children: [
            Icon(Icons.check_circle_outline_rounded, size: 64, color: _success.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            Text(
              'All Udhar Clear!',
              style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.bold, color: const Color(0xFF1E293B)),
            ),
            const SizedBox(height: 4),
            Text(
              'No pending customer balances found.',
              style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF64748B)),
            ),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════
  // INVOICE ANALYTICS TAB
  // ══════════════════════════════════════════════════════════

  Widget _buildInvoiceAnalyticsTab() {
    if (_invoicesLoading) {
      return const Center(child: CircularProgressIndicator(color: _primary));
    }

    return RefreshIndicator(
      onRefresh: _loadInvoiceAnalytics,
      color: _primary,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Overview', style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.bold, color: const Color(0xFF0F172A))),
                TextButton.icon(
                  onPressed: _exportSummary,
                  icon: const Icon(Icons.ios_share_rounded, size: 16),
                  label: Text('Export', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600)),
                  style: TextButton.styleFrom(foregroundColor: _primary),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _buildInvoiceSummaryCards(),
            const SizedBox(height: 20),
            _buildPaymentStatusChart(),
            const SizedBox(height: 20),
            _buildTopOutstandingCustomers(),
            const SizedBox(height: 20),
            Text('All Invoices', style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.bold, color: const Color(0xFF0F172A))),
            const SizedBox(height: 10),
            _buildInvoiceSearchAndSort(),
            const SizedBox(height: 10),
            _buildInvoiceStatusChips(),
            const SizedBox(height: 12),
            if (_filteredInvoices.isEmpty)
              _buildInvoiceEmptyState()
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _filteredInvoices.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (ctx, idx) => _buildInvoiceTile(_filteredInvoices[idx]),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInvoiceSearchAndSort() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _invoiceSearchController,
            onChanged: (val) => setState(() => _invoiceSearchQuery = val),
            decoration: InputDecoration(
              hintText: 'Search invoice #, customer, phone...',
              prefixIcon: const Icon(Icons.search, color: Color(0xFF64748B), size: 20),
              isDense: true,
              fillColor: Colors.white,
              filled: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey.shade300),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey.shade200),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: PopupMenuButton<String>(
            initialValue: _invoiceSortOption,
            onSelected: (val) => setState(() => _invoiceSortOption = val),
            icon: const Icon(Icons.sort_rounded, color: Color(0xFF64748B)),
            itemBuilder: (ctx) => [
              _sortMenuItem('DATE_DESC', 'Newest first'),
              _sortMenuItem('DATE_ASC', 'Oldest first'),
              _sortMenuItem('AMOUNT_DESC', 'Amount: high to low'),
              _sortMenuItem('AMOUNT_ASC', 'Amount: low to high'),
              _sortMenuItem('STATUS', 'Status: unpaid first'),
            ],
          ),
        ),
      ],
    );
  }

  PopupMenuItem<String> _sortMenuItem(String value, String label) {
    final isSelected = _invoiceSortOption == value;
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          if (isSelected) const Icon(Icons.check, size: 16, color: _primary) else const SizedBox(width: 16),
          const SizedBox(width: 8),
          Text(label, style: GoogleFonts.inter(fontSize: 13, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
        ],
      ),
    );
  }

  /// Customers with the highest UNCLEARED (outstanding) balance across their invoices —
  /// this is who to chase for payment, not just who bought the most.
  Widget _buildTopOutstandingCustomers() {
    if (_topOutstandingCustomers.isEmpty) {
      return const SizedBox.shrink();
    }

    final maxOutstanding = (_topOutstandingCustomers.first['outstanding'] as double);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.priority_high_rounded, size: 16, color: Color(0xFFEF4444)),
              const SizedBox(width: 6),
              Text('Top Customers by Uncleared Amount', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.bold, color: const Color(0xFF0F172A))),
            ],
          ),
          const SizedBox(height: 14),
          ..._topOutstandingCustomers.map((c) {
            final name = c['name'] as String;
            final outstanding = c['outstanding'] as double;
            final invoiceCount = c['invoice_count'] as int;
            final phone = c['phone'] as String;
            final ratio = maxOutstanding > 0 ? (outstanding / maxOutstanding) : 0.0;

            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(name,
                                  style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: const Color(0xFF334155)),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                            ),
                            Text('₹${outstanding.toStringAsFixed(0)}',
                                style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.bold, color: _danger)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: ratio.clamp(0.0, 1.0),
                            minHeight: 6,
                            backgroundColor: Colors.grey.shade100,
                            valueColor: const AlwaysStoppedAnimation(_danger),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text('$invoiceCount unpaid/partial invoice(s)',
                            style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF94A3B8))),
                      ],
                    ),
                  ),
                  if (phone.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: () => _makePhoneCall(phone),
                      icon: const Icon(Icons.call_rounded, size: 18, color: Colors.blue),
                      tooltip: 'Call $name',
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildInvoiceSummaryCards() {
    return Row(
      children: [
        Expanded(child: _buildSummaryCard('Total Invoiced', _invoicedTotal, const Color(0xFF4F46E5), Icons.receipt_long_rounded)),
        const SizedBox(width: 10),
        Expanded(child: _buildSummaryCard('Total Paid', _paidTotal, _success, Icons.check_circle_rounded)),
        const SizedBox(width: 10),
        Expanded(child: _buildSummaryCard('Total Pending', _pendingTotal, _danger, Icons.pending_actions_rounded)),
      ],
    );
  }

  Widget _buildSummaryCard(String label, double amount, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 8),
          Text(label, style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF64748B), fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            '₹${amount.toStringAsFixed(0)}',
            style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w900, color: const Color(0xFF0F172A)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  /// Payment status breakdown: Paid / Partial / Unpaid as a donut chart
  Widget _buildPaymentStatusChart() {
    final total = _paidCount + _partialCount + _unpaidCount;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Payment Status Breakdown', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.bold, color: const Color(0xFF0F172A))),
          const SizedBox(height: 16),
          if (total == 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text('No invoices yet', style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF94A3B8))),
              ),
            )
          else
            Row(
              children: [
                SizedBox(
                  width: 130,
                  height: 130,
                  child: PieChart(
                    PieChartData(
                      sectionsSpace: 3,
                      centerSpaceRadius: 32,
                      sections: [
                        if (_paidCount > 0)
                          PieChartSectionData(
                            value: _paidCount.toDouble(),
                            color: _success,
                            title: '$_paidCount',
                            radius: 26,
                            titleStyle: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                        if (_partialCount > 0)
                          PieChartSectionData(
                            value: _partialCount.toDouble(),
                            color: _warning,
                            title: '$_partialCount',
                            radius: 26,
                            titleStyle: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                        if (_unpaidCount > 0)
                          PieChartSectionData(
                            value: _unpaidCount.toDouble(),
                            color: _danger,
                            title: '$_unpaidCount',
                            radius: 26,
                            titleStyle: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildLegendRow('Paid', _paidCount, total, _success),
                      const SizedBox(height: 10),
                      _buildLegendRow('Partial', _partialCount, total, _warning),
                      const SizedBox(height: 10),
                      _buildLegendRow('Unpaid', _unpaidCount, total, _danger),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildLegendRow(String label, int count, int total, Color color) {
    final pct = total > 0 ? (count / total * 100) : 0.0;
    return Row(
      children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Expanded(
          child: Text('$label ($count)', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: const Color(0xFF334155))),
        ),
        Text('${pct.toStringAsFixed(0)}%', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.bold, color: color)),
      ],
    );
  }

  Widget _buildInvoiceStatusChips() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _buildInvoiceChip('ALL', 'All (${_allInvoices.length})'),
          const SizedBox(width: 8),
          _buildInvoiceChip('PAID', 'Paid ($_paidCount)', color: _success),
          const SizedBox(width: 8),
          _buildInvoiceChip('PARTIAL', 'Partial ($_partialCount)', color: _warning),
          const SizedBox(width: 8),
          _buildInvoiceChip('UNPAID', 'Unpaid ($_unpaidCount)', color: _danger),
        ],
      ),
    );
  }

  Widget _buildInvoiceChip(String key, String label, {Color? color}) {
    final isSelected = _invoiceStatusFilter == key;
    final activeColor = color ?? _primary;

    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => setState(() => _invoiceStatusFilter = key),
      selectedColor: activeColor.withValues(alpha: 0.15),
      backgroundColor: Colors.white,
      labelStyle: GoogleFonts.inter(
        fontSize: 12,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
        color: isSelected ? activeColor : const Color(0xFF64748B),
      ),
      side: BorderSide(color: isSelected ? activeColor : Colors.grey.shade200),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    );
  }

  Widget _buildInvoiceTile(Map<String, dynamic> inv) {
    final total = (inv['total_amount'] as num?)?.toDouble() ??
        double.tryParse(inv['total_amount']?.toString() ?? inv['total']?.toString() ?? '0') ??
        0.0;
    final paidAmt = (inv['paid_amount'] as num?)?.toDouble() ??
        double.tryParse(inv['paid_amount']?.toString() ?? '0') ??
        0.0;
    final status = (inv['payment_status']?.toString() ?? _deriveStatus(total, paidAmt)).toUpperCase();
    final customerName = inv['customer_name']?.toString() ?? 'Guest Customer';
    final invoiceNumber = inv['invoice_number']?.toString() ?? inv['sale_id']?.toString() ?? '—';
    final dateStr = inv['invoice_date']?.toString() ?? inv['created_at']?.toString() ?? '';

    Color statusColor;
    switch (status) {
      case 'PAID':
        statusColor = _success;
        break;
      case 'PARTIAL':
        statusColor = _warning;
        break;
      default:
        statusColor = _danger;
    }

    return InkWell(
      onTap: () => _showInvoiceDetailModal(inv),
      borderRadius: BorderRadius.circular(14),
      child: Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
            child: Icon(Icons.receipt_rounded, color: statusColor, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('#$invoiceNumber · $customerName',
                    style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.bold, color: const Color(0xFF0F172A)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(dateStr.split('T').first, style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF94A3B8))),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('₹${total.toStringAsFixed(0)}', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w900, color: const Color(0xFF0F172A))),
              const SizedBox(height: 2),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                child: Text(status, style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.bold, color: statusColor)),
              ),
            ],
          ),
          const SizedBox(width: 4),
          Icon(Icons.chevron_right_rounded, color: Colors.grey.shade400, size: 20),
        ],
      ),
      ),
    );
  }

  /// Bottom sheet showing full line-item breakdown for a single invoice
  void _showInvoiceDetailModal(Map<String, dynamic> inv) {
    final total = (inv['total_amount'] as num?)?.toDouble() ??
        double.tryParse(inv['total_amount']?.toString() ?? inv['total']?.toString() ?? '0') ??
        0.0;
    final paidAmt = (inv['paid_amount'] as num?)?.toDouble() ??
        double.tryParse(inv['paid_amount']?.toString() ?? '0') ??
        0.0;
    final status = (inv['payment_status']?.toString() ?? _deriveStatus(total, paidAmt)).toUpperCase();
    final customerName = inv['customer_name']?.toString() ?? 'Guest Customer';
    final customerPhone = inv['customer_phone']?.toString() ?? '';
    final invoiceNumber = inv['invoice_number']?.toString() ?? inv['sale_id']?.toString() ?? '—';
    final dateStr = inv['invoice_date']?.toString() ?? inv['created_at']?.toString() ?? '';
    final lineItems = List<Map<String, dynamic>>.from(inv['line_items'] ?? inv['items'] ?? []);

    Color statusColor;
    switch (status) {
      case 'PAID':
        statusColor = _success;
        break;
      case 'PARTIAL':
        statusColor = _warning;
        break;
      default:
        statusColor = _danger;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.7,
          minChildSize: 0.4,
          maxChildSize: 0.92,
          expand: false,
          builder: (context, scrollController) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Invoice #$invoiceNumber', style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.bold, color: const Color(0xFF1E293B))),
                          Text(dateStr.split('T').first, style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF64748B))),
                        ],
                      ),
                      IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: const Color(0xFFF8FAFC), borderRadius: BorderRadius.circular(12)),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 18,
                          backgroundColor: _primary.withValues(alpha: 0.1),
                          child: Text(customerName.isNotEmpty ? customerName[0].toUpperCase() : 'C',
                              style: GoogleFonts.inter(fontWeight: FontWeight.bold, color: _primary)),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(customerName, style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.bold)),
                              if (customerPhone.isNotEmpty)
                                Text(customerPhone, style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF64748B))),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                          child: Text(status, style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.bold, color: statusColor)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('Line Items', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.bold, color: const Color(0xFF0F172A))),
                  const SizedBox(height: 8),
                  Expanded(
                    child: lineItems.isEmpty
                        ? Center(
                            child: Text('No line-item detail saved for this invoice',
                                style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF94A3B8))),
                          )
                        : ListView.separated(
                            controller: scrollController,
                            itemCount: lineItems.length,
                            separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFFF1F5F9)),
                            itemBuilder: (ctx, idx) {
                              final item = lineItems[idx];
                              final name = item['product_name'] ?? item['name'] ?? item['product'] ?? 'Item';
                              final qty = item['quantity'] ?? item['qty'] ?? 1;
                              final price = (item['unit_price'] as num?)?.toDouble() ?? (item['price'] as num?)?.toDouble() ?? 0.0;
                              final lineTotal = (item['line_total'] as num?)?.toDouble() ?? (item['total'] as num?)?.toDouble() ?? (price * (qty is num ? qty : 1));
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                child: Row(
                                  children: [
                                    Expanded(
                                      flex: 3,
                                      child: Text('$name', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600)),
                                    ),
                                    Expanded(
                                      flex: 1,
                                      child: Text('x$qty', textAlign: TextAlign.center, style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF64748B))),
                                    ),
                                    Expanded(
                                      flex: 2,
                                      child: Text('₹${lineTotal.toStringAsFixed(0)}', textAlign: TextAlign.right, style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.bold)),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                  const Divider(height: 24),
                  _buildDetailRow('Total Amount', '₹${total.toStringAsFixed(2)}', bold: true),
                  _buildDetailRow('Paid Amount', '₹${paidAmt.toStringAsFixed(2)}', color: _success),
                  if (total - paidAmt > 0.01) _buildDetailRow('Balance Due', '₹${(total - paidAmt).toStringAsFixed(2)}', color: _danger, bold: true),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildDetailRow(String label, String value, {bool bold = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF64748B))),
          Text(value, style: GoogleFonts.inter(fontSize: 14, fontWeight: bold ? FontWeight.bold : FontWeight.w500, color: color ?? const Color(0xFF0F172A))),
        ],
      ),
    );
  }

  /// Builds a plain-text summary and copies it to the clipboard so it can be
  /// pasted into WhatsApp/SMS/email. (Wire up `share_plus` if you want the
  /// native OS share sheet instead of copy-to-clipboard.)
  Future<void> _exportSummary() async {
    final buffer = StringBuffer();
    buffer.writeln('📊 INVOICE SUMMARY');
    buffer.writeln('Generated: ${DateTime.now().toString().split('.').first}');
    buffer.writeln('─────────────────────');
    buffer.writeln('Total Invoiced: ₹${_invoicedTotal.toStringAsFixed(2)}');
    buffer.writeln('Total Paid: ₹${_paidTotal.toStringAsFixed(2)}');
    buffer.writeln('Total Pending: ₹${_pendingTotal.toStringAsFixed(2)}');
    buffer.writeln('');
    buffer.writeln('Payment Status:');
    buffer.writeln('  Paid: $_paidCount invoice(s)');
    buffer.writeln('  Partial: $_partialCount invoice(s)');
    buffer.writeln('  Unpaid: $_unpaidCount invoice(s)');

    if (_topOutstandingCustomers.isNotEmpty) {
      buffer.writeln('');
      buffer.writeln('Top Uncleared Balances:');
      for (final c in _topOutstandingCustomers) {
        buffer.writeln('  ${c['name']}: ₹${(c['outstanding'] as double).toStringAsFixed(2)}');
      }
    }

    final summary = buffer.toString();

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Export Summary', style: GoogleFonts.inter(fontWeight: FontWeight.bold)),
        content: SingleChildScrollView(
          child: SelectableText(summary, style: GoogleFonts.inter(fontSize: 13, height: 1.5)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          ElevatedButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: summary));
              if (mounted) Navigator.pop(ctx);
              _showToast('📋 Summary copied to clipboard');
            },
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('Copy'),
            style: ElevatedButton.styleFrom(backgroundColor: _primary, foregroundColor: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _buildInvoiceEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Column(
          children: [
            Icon(Icons.receipt_long_outlined, size: 64, color: Colors.grey.shade300),
            const SizedBox(height: 12),
            Text('No invoices found', style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.bold, color: const Color(0xFF1E293B))),
            const SizedBox(height: 4),
            Text('Invoices will appear here once sales are recorded.',
                style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF64748B))),
          ],
        ),
      ),
    );
  }
}