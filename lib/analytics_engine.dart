import 'package:flutter/foundation.dart';
import 'format_helper.dart';

class AnalyticsEngine {
  // ── Helper: Format product name for display (Standard Title Case) ──────────────
  static String formatProductName(String raw) {
    if (raw.isEmpty) return 'Unknown';
    String name = raw.toString().trim();
    
    return name.split(' ').map((word) {
      if (word.isEmpty) return '';
      return word[0].toUpperCase() + word.substring(1).toLowerCase();
    }).join(' ');
  }

  List<dynamic> sales = [];
  int selectedTimeFilter = 0;

  List<Map<String, dynamic>> filteredSalesCache = [];
  Map<String, double> salesByMonthCache = {};
  Map<String, double> salesByWeekCache = {};
  Map<String, double> salesByYearCache = {};
  Map<String, Map<String, dynamic>> productAnalyticsCache = {};
  Map<String, Map<int, double>> monthlyProductSales = {}; // Added for Dashboard compatibility

  // ═══ Metrics ═══
  double totalSales = 0.0;
  int totalTransactions = 0;
  double averageSale = 0.0;
  int uniqueProducts = 0;
  double growthPercentage = 0.0;
  int totalOnlineOrders = 0; // 🔒 NEW: Track online orders
  
  double filteredTotalSales = 0.0;
  int filteredTotalTransactions = 0;
  double filteredAverageSale = 0.0;
  int filteredUniqueProducts = 0;
  double filteredGrowthPercentage = 0.0;
  int filteredOnlineOrders = 0; // 🔒 NEW: Track filtered online orders
  
  double todayRevenue = 0.0;
  double yesterdayRevenue = 0.0;
  int todayTransactionsCount = 0;
  String todayTopProduct = '';
  String todayBestHourLabel = '';
  int yesterdayTransactionsCount = 0;
  String yesterdayTopProduct = '';
  String yesterdayBestHourLabel = '';
  double previousDayRevenue = 0.0;

  // Compatibility Getters for Dashboard
  double get todaySalesValue => todayRevenue;
  int get todayTransactionsValue => todayTransactionsCount;
  
  // FIX: Access salesByMonthCache for current month revenue
  double get monthlyRevenue {
    final now = DateTime.now();
    final currentMon = _months[now.month - 1];
    return salesByMonthCache[currentMon] ?? 0.0;
  }

  // FIX-A: Filter-aware display getters for KPI cards
  double get displayRevenue {
    switch (selectedTimeFilter) {
      case 0:
        return todayRevenue;  // Today
      case 1:
      case 2:
      case 3:
        return filteredTotalSales;  // Week/Month/Year
      default:
        return filteredTotalSales;
    }
  }

  int get displayTransactions {
    if (selectedTimeFilter == 0) {
      return todayTransactionsCount;  // Today
    }
    return filteredTotalTransactions;  // Week/Month/Year
  }

  List<Map<String, dynamic>> recentSales = [];

  static const List<String> _months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

  /// Parse sale date with multiple format support and force Indian Time (IST)
  DateTime getLocalDate(Map<String, dynamic> sale) {
    try {
      // Try multiple date fields in order of preference
      String? str = (sale['created_at'] ?? sale['sale_date'] ?? sale['invoice_date'] ?? sale['date'] ?? '').toString().trim();
      if (str.isEmpty) return DateTime(1970);
      
      if (kDebugMode) debugPrint('🔍 Date parsing: "$str", is_local: ${sale['is_local']}, available fields: ${sale.keys.join(', ')}');
      
      // If it's just a date (YYYY-MM-DD), convert to datetime at start of day in IST
      if (str.length == 10 && str.contains('-')) {
        final parts = str.split('-');
        if (parts.length == 3) {
          final year = int.tryParse(parts[0]) ?? 1970;
          final month = int.tryParse(parts[1]) ?? 1;
          final day = int.tryParse(parts[2]) ?? 1;
          final date = DateTime(year, month, day);
          // Return as IST (already at midnight)
          return date;
        }
      }
      
      bool isBackend = sale['is_local'] == false;
      if (isBackend && !str.endsWith('Z') && !str.contains('+')) {
        str += 'Z'; // Force UTC parsing for backend sales missing timezone
        if (kDebugMode) debugPrint('🔧 Added Z for backend date: $str');
      }

      DateTime? parsed = DateTime.tryParse(str);
      if (parsed == null) {
        if (kDebugMode) debugPrint('❌ Failed to parse date: $str');
        return DateTime(1970);
      }
      
      // Force Indian Standard Time (IST = UTC + 5:30)
      final istTime = parsed.toUtc().add(const Duration(hours: 5, minutes: 30));
      
      if (kDebugMode) debugPrint('✅ Date: "$str" → $istTime (IST)');
      
      return istTime;
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Date parsing error: $e');
      return DateTime(1970);
    }
  }

  static double _toDouble(dynamic v) {
    if (v == null) return 0.0;
    if (v is num) return v.toDouble();
    try {
      // Remove everything except numbers, dots, and negative signs
      String cleaned = v.toString().replaceAll(RegExp(r'[^0-9.\-]'), '');
      if (cleaned.isEmpty || cleaned == '.' || cleaned == '-') return 0.0;
      return double.tryParse(cleaned) ?? 0.0;
    } catch (_) {
      return 0.0;
    }
  }

  /// 🚀 PRODUCTION-GRADE ANALYTICS (Single Pass O(N))
  void recalculateAnalytics(List<dynamic> newSales, int timeFilter) {
    sales = newSales;
    selectedTimeFilter = timeFilter;
    
    final now = DateTime.now();
    final todayDate = DateTime(now.year, now.month, now.day);
    final yesterdayDate = todayDate.subtract(const Duration(days: 1));
    final prevDayDate = todayDate.subtract(const Duration(days: 2));
    final normalizedNow = DateTime(now.year, now.month, now.day);

    if (kDebugMode) {
      debugPrint('🔍 Analytics Recalculation:');
      debugPrint('  - Total sales: ${newSales.length}');
      debugPrint('  - Today: $todayDate');
      debugPrint('  - Yesterday: $yesterdayDate');
      debugPrint('  - Filter: $timeFilter');
    }

    // Reset Metrics
    todayRevenue = 0.0; yesterdayRevenue = 0.0; previousDayRevenue = 0.0;
    todayTransactionsCount = 0; yesterdayTransactionsCount = 0;
    totalOnlineOrders = 0; // 🔒 NEW: Reset online orders counter
    filteredOnlineOrders = 0; // 🔒 NEW: Reset filtered online orders counter
    
    final Map<String, double> todayProductRevenue = {};
    final Map<String, double> yesterdayProductRevenue = {};
    final Map<int, double> todayHourRevenue = {};
    final Map<int, double> yesterdayHourRevenue = {};
    
    salesByMonthCache = {};
    for (int i = 11; i >= 0; i--) {
      final d = DateTime(now.year, now.month - i, 1);
      final mon = '${_months[d.month - 1]} ${d.year.toString().substring(2)}';
      salesByMonthCache[mon] = 0.0;
    }
    salesByWeekCache = {for (int i = 1; i <= 8; i++) 'w$i': 0.0};
    salesByYearCache = {}; // DYNAMIC: Will grow based on encountered years
    monthlyProductSales = {};

    // ── Single Pass Processing ──
    final List<Map<String, dynamic>> flattenedSales = [];
    for (final rawS in newSales) {
      final s = Map<String, dynamic>.from(rawS as Map);
      if (s['items'] is List) {
        final items = s['items'] as List;
        for (int i = 0; i < items.length; i++) {
          final item = Map<String, dynamic>.from(items[i] as Map);
          final String prodName = (item['product_name'] ?? item['product'] ?? item['item'] ?? item['description'] ?? 'Unknown').toString();
          final String bCode = (item['product_id'] ?? item['barcode'] ?? '').toString();
          final double parsedPrice = _toDouble(item['price'] ?? item['unit_price']);
          final double parsedQty = _toDouble(item['qty'] ?? item['quantity'] ?? 1);
          final double lineTotal = _toDouble(item['total_with_tax'] ?? item['total'] ?? item['line_total'] ?? (parsedPrice * parsedQty));
          
          flattenedSales.add({
            'sale_date': s['sale_date'] ?? s['created_at'] ?? s['date'] ?? s['invoice_date'],
            'created_at': s['created_at'] ?? s['sale_date'] ?? s['date'] ?? s['invoice_date'],
            'date': s['date'] ?? s['invoice_date'] ?? s['sale_date'] ?? s['created_at'],
            'total': lineTotal,
            'product_name': prodName,
            'product_id': bCode,
            'barcode': bCode,
            'qty': parsedQty,
            'quantity': parsedQty,
            'price': parsedPrice,
            'payment_status': s['payment_status'] ?? s['status'],
            'paid_amount': s['paid_amount'],
            'invoice_total': s['total_amount'] ?? s['total'] ?? s['totalAmount'],
            'source': s['source'] ?? s['order_source'] ?? 'OFFLINE', // 🔒 NEW: Track order source
          });
        }
      } else {
        flattenedSales.add(s);
      }
    }

    sales = flattenedSales;

    final Set<String> todayUniqueInvoices = {};
    final Set<String> yesterdayUniqueInvoices = {};
    final Set<String> onlineOrderInvoices = {}; // 🔒 NEW: Track online order invoices

    for (final s in flattenedSales) {
      try {
        final dt = getLocalDate(s);
        final String invoiceKey = (s['created_at'] ?? s['sale_date'] ?? s['date'] ?? '').toString();
        final double itemTotal = _toDouble(s['total_amount'] ?? s['total']);
        final double invoiceTotal = _toDouble(s['invoice_total'] ?? itemTotal);
        final double paidAmount = _toDouble(s['paid_amount'] ?? invoiceTotal);
        
        // Feature: Proportional revenue scaling based on paid amount vs total
        double ratio = 1.0;
        final String status = (s['payment_status'] ?? '').toString().toUpperCase();
        if (invoiceTotal > 0) {
          if (status == 'UNPAID' || status == 'PENDING' || status == 'PARTIAL') {
            ratio = paidAmount / invoiceTotal;
          } else if (s.containsKey('paid_amount') && s['paid_amount'] != null && paidAmount >= 0 && paidAmount < invoiceTotal && status != 'PAID') {
            ratio = paidAmount / invoiceTotal;
          }
        }
        final double val = itemTotal * ratio;
        final day = DateTime(dt.year, dt.month, dt.day);
        final String bCode = (s['product_id'] ?? s['barcode'] ?? '').toString().trim();
        final String rawName = s['product_name']?.toString() ?? s['product']?.toString() ?? s['item']?.toString() ?? '';
        final String formattedName = formatProductName(rawName);

        // Monthly trends for products (Current Year)
        if (dt.year == now.year && rawName.isNotEmpty) {
          monthlyProductSales.putIfAbsent(formattedName, () => {});
          monthlyProductSales[formattedName]![dt.month] = (monthlyProductSales[formattedName]![dt.month] ?? 0.0) + val;
        }

        // Today / Yesterday
        if (day == todayDate) {
          todayRevenue += val;
          if (invoiceKey.isNotEmpty) todayUniqueInvoices.add(invoiceKey);
          todayHourRevenue[dt.hour] = (todayHourRevenue[dt.hour] ?? 0.0) + val;
          if (rawName.isNotEmpty && formattedName != 'Unknown') todayProductRevenue[formattedName] = (todayProductRevenue[formattedName] ?? 0.0) + val;
          
          // 🔒 NEW: Track online orders
          final String source = (s['source'] ?? s['order_source'] ?? 'OFFLINE').toString().toUpperCase();
          if (source == 'ONLINE' || source == 'WEB' || source == 'APP') {
            if (invoiceKey.isNotEmpty) onlineOrderInvoices.add(invoiceKey);
          }
          
          if (kDebugMode && todayRevenue > 0) {
            debugPrint('✅ Today sale found: $formattedName, amount: ₹$val, date: $day, time: ${dt.hour}:00');
          }
        } else if (day == yesterdayDate) {
          yesterdayRevenue += val;
          if (invoiceKey.isNotEmpty) yesterdayUniqueInvoices.add(invoiceKey);
          yesterdayHourRevenue[dt.hour] = (yesterdayHourRevenue[dt.hour] ?? 0.0) + val;
          if (rawName.isNotEmpty && formattedName != 'Unknown') yesterdayProductRevenue[formattedName] = (yesterdayProductRevenue[formattedName] ?? 0.0) + val;
          
          // 🔒 NEW: Track online orders
          final String source = (s['source'] ?? s['order_source'] ?? 'OFFLINE').toString().toUpperCase();
          if (source == 'ONLINE' || source == 'WEB' || source == 'APP') {
            if (invoiceKey.isNotEmpty) onlineOrderInvoices.add(invoiceKey);
          }
          
          if (kDebugMode && yesterdayRevenue > 0) {
            debugPrint('✅ Yesterday sale found: $formattedName, amount: ₹$val, date: $day');
          }
        } else if (day == prevDayDate) {
          previousDayRevenue += val;
          
          // 🔒 NEW: Track online orders
          final String source = (s['source'] ?? s['order_source'] ?? 'OFFLINE').toString().toUpperCase();
          if (source == 'ONLINE' || source == 'WEB' || source == 'APP') {
            if (invoiceKey.isNotEmpty) onlineOrderInvoices.add(invoiceKey);
          }
        }

        // Monthly (Year-aware for clashing prevention)
        final mon = '${_months[dt.month - 1]} ${dt.year.toString().substring(2)}';
        if (salesByMonthCache.containsKey(mon)) {
          salesByMonthCache[mon] = (salesByMonthCache[mon] ?? 0.0) + val;
        }

        // Yearly
        final yrStr = dt.year.toString();
        salesByYearCache[yrStr] = (salesByYearCache[yrStr] ?? 0.0) + val;

        // Weekly (Sliding 8 weeks)
        final daysDiff = normalizedNow.difference(day).inDays;
        if (daysDiff >= 0 && daysDiff < 56) {
          final wk = 8 - (daysDiff ~/ 7); // FIX: w8 is current week, w1 is oldest
          final wkLabel = 'w$wk';
          if (salesByWeekCache.containsKey(wkLabel)) {
            salesByWeekCache[wkLabel] = (salesByWeekCache[wkLabel] ?? 0.0) + val;
          }
        }
      } catch (_) {}
    }

    // Top Products & Best Hours
    todayBestHourLabel = _findBestHour(todayHourRevenue);
    yesterdayBestHourLabel = _findBestHour(yesterdayHourRevenue);

    if (todayProductRevenue.isNotEmpty) {
      todayTopProduct = todayProductRevenue.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    }
    if (yesterdayProductRevenue.isNotEmpty) {
      yesterdayTopProduct = yesterdayProductRevenue.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    }

    // ── Time Filtered Cache
    todayTransactionsCount = todayUniqueInvoices.isEmpty && todayRevenue > 0 ? 1 : todayUniqueInvoices.length;
    yesterdayTransactionsCount = yesterdayUniqueInvoices.isEmpty && yesterdayRevenue > 0 ? 1 : yesterdayUniqueInvoices.length;
    
    // 🔒 NEW: Calculate total online orders from all sales data
    final allOnlineInvoices = flattenedSales.where((s) {
      final String source = (s['source'] ?? s['order_source'] ?? 'OFFLINE').toString().toUpperCase();
      return source == 'ONLINE' || source == 'WEB' || source == 'APP';
    }).map((s) => (s['created_at'] ?? s['sale_date'] ?? s['date'] ?? '').toString()).where((s) => s.isNotEmpty).toSet();
    totalOnlineOrders = allOnlineInvoices.isEmpty && flattenedSales.isNotEmpty ? 0 : allOnlineInvoices.length;

    filteredSalesCache = flattenedSales.where((sale) {
      final dt = getLocalDate(sale);
      final daysAgo = normalizedNow.difference(DateTime(dt.year, dt.month, dt.day)).inDays;
      if (selectedTimeFilter == 0) return daysAgo == 0;
      if (selectedTimeFilter == 1) return daysAgo < 7;
      if (selectedTimeFilter == 2) return daysAgo < 30;
      if (selectedTimeFilter == 3) return dt.year == now.year;
      return true;
    }).toList();

    filteredTotalSales = filteredSalesCache.fold(0.0, (sum, s) => sum + _toDouble(s['total_amount'] ?? s['total']));
    final uniqueInvoices = filteredSalesCache.map((s) => (s['created_at'] ?? s['sale_date'] ?? s['date'] ?? '').toString()).where((s) => s.isNotEmpty).toSet();
    filteredTotalTransactions = uniqueInvoices.isEmpty && filteredSalesCache.isNotEmpty ? 1 : uniqueInvoices.length;
    filteredAverageSale = filteredTotalTransactions > 0 ? filteredTotalSales / filteredTotalTransactions : 0.0;
    filteredUniqueProducts = filteredSalesCache.map((s) { // FIX R2
      final b = (s['product_id'] ?? s['barcode'] ?? '').toString().trim();
      return b.isNotEmpty
          ? b
          : (s['product_name']?.toString() ?? 'Unknown').toLowerCase().trim();
    }).toSet().length;
    
    // 🔒 NEW: Calculate filtered online orders
    final filteredOnlineInvoices = filteredSalesCache.where((s) {
      final String source = (s['source'] ?? s['order_source'] ?? 'OFFLINE').toString().toUpperCase();
      return source == 'ONLINE' || source == 'WEB' || source == 'APP';
    }).map((s) => (s['created_at'] ?? s['sale_date'] ?? s['date'] ?? '').toString()).where((s) => s.isNotEmpty).toSet();
    filteredOnlineOrders = filteredOnlineInvoices.isEmpty && filteredSalesCache.isNotEmpty ? 0 : filteredOnlineInvoices.length;

    // 🔒 BUG FIX: Calculate main metrics (not just filtered metrics)
    totalSales = flattenedSales.fold(0.0, (sum, s) => sum + _toDouble(s['total_amount'] ?? s['total']));
    final allUniqueInvoices = flattenedSales.map((s) => (s['created_at'] ?? s['sale_date'] ?? s['date'] ?? '').toString()).where((s) => s.isNotEmpty).toSet();
    totalTransactions = allUniqueInvoices.isEmpty && flattenedSales.isNotEmpty ? 1 : allUniqueInvoices.length;
    averageSale = totalTransactions > 0 ? totalSales / totalTransactions : 0.0;
    uniqueProducts = flattenedSales.map((s) {
      final b = (s['product_id'] ?? s['barcode'] ?? '').toString().trim();
      return b.isNotEmpty
          ? b
          : (s['product_name']?.toString() ?? 'Unknown').toLowerCase().trim();
    }).toSet().length;

    final sortedForRecent = List<Map<String, dynamic>>.from(filteredSalesCache)
      ..sort((a, b) => getLocalDate(b).compareTo(getLocalDate(a)));
    recentSales = sortedForRecent.take(5).toList();

    // Growth calculation
    if (filteredSalesCache.length < 2) {
      filteredGrowthPercentage = 0.0;
    } else {
      _calculateGrowth(timeFilter);
    }

    // Product specific analytics for the filtered period
    productAnalyticsCache = {};
    for (final s in filteredSalesCache) {
      final String b = (s['product_id'] ?? s['barcode'] ?? '').toString().trim();
      final String rawName = s['product_name']?.toString() ?? s['product']?.toString() ?? s['item']?.toString() ?? 'Unknown';
      
      // 🚀 PRODUCTION FIX: Use Normalized Key from FormatHelper
      final String nameKey = FormatHelper.normalizeName(rawName);
      final String displayName = formatProductName(rawName);
      
      // We use the ID if available and not '0', otherwise the normalized name key
      final String key = (b.isNotEmpty && b != '0') ? b : nameKey;
      
      productAnalyticsCache.putIfAbsent(key, () => {
        'total': 0.0, 
        'count': 0, 
        'quantity': 0.0,
        'name': displayName,
        'display_name': displayName // Store formatted name for UI
      });
      
      final v = _toDouble(s['total_amount'] ?? s['total']);
      final q = _toDouble(s['qty'] ?? s['quantity']);
      productAnalyticsCache[key]!['total'] = (productAnalyticsCache[key]!['total'] as double) + v;
      productAnalyticsCache[key]!['count'] = (productAnalyticsCache[key]!['count'] as int) + 1;
      productAnalyticsCache[key]!['quantity'] = (productAnalyticsCache[key]!['quantity'] as double) + q;
    }

    // 🚀 FIX: Calculate percentages for Pie Chart visualization
    if (filteredTotalSales > 0) {
      productAnalyticsCache.forEach((key, data) {
        final total = data['total'] as double;
        data['percentage'] = (total / filteredTotalSales) * 100;
      });
    }

    if (kDebugMode) {
      debugPrint('📊 Analytics Calculation Complete:');
      debugPrint('  - Today Revenue: ₹$todayRevenue');
      debugPrint('  - Today Transactions: $todayTransactionsCount');
      debugPrint('  - Yesterday Revenue: ₹$yesterdayRevenue');
      debugPrint('  - Total Sales: ₹$totalSales');
      debugPrint('  - Filtered Sales: ₹$filteredTotalSales');
      debugPrint('  - Today Top Product: $todayTopProduct');
    }
  }

  /// FIX-6 R2: Growth calculation — compare against meaningful baseline per time filter
  void _calculateGrowth(int timeFilter) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    double current = 0, previous = 0;

    if (timeFilter == 0) {
      // Today vs Yesterday
      current = todayRevenue;
      previous = yesterdayRevenue;
    } else if (timeFilter == 1) {
      // This week vs last week (Monday-based weeks)
      final thisWeekStart = today.subtract(Duration(days: today.weekday - 1));
      final lastWeekStart = thisWeekStart.subtract(const Duration(days: 7));
      for (final s in sales) {
        final sMap = Map<String, dynamic>.from(s as Map);
        final dt = getLocalDate(sMap);
        final val = _toDouble(sMap['total']);
        final saleDay = DateTime(dt.year, dt.month, dt.day);
        
        if (!saleDay.isBefore(thisWeekStart) && saleDay.isBefore(today.add(const Duration(days: 1)))) {
          current += val; // This week
        } else if (!saleDay.isBefore(lastWeekStart) && saleDay.isBefore(thisWeekStart)) {
          previous += val; // Last week
        }
      }
    } else if (timeFilter == 2) {
      // This month vs last month
      final thisMonthStart = DateTime(now.year, now.month, 1);
      final lastMonthStart = now.month == 1
          ? DateTime(now.year - 1, 12, 1)
          : DateTime(now.year, now.month - 1, 1);
      for (final s in sales) {
        final sMap = Map<String, dynamic>.from(s as Map);
        final dt = getLocalDate(sMap);
        final val = _toDouble(sMap['total']);
        
        if (!dt.isBefore(thisMonthStart)) {
          current += val; // This month
        } else if (!dt.isBefore(lastMonthStart) && dt.isBefore(thisMonthStart)) {
          previous += val; // Last month
        }
      }
    } else if (timeFilter == 3) {
      // Year-over-Year growth: This year vs Previous year
      final thisYear = now.year;
      final prevYear = now.year - 1;
      for (final s in sales) {
        final sMap = Map<String, dynamic>.from(s as Map);
        final dt = getLocalDate(sMap);
        final val = _toDouble(sMap['total']);
        
        if (dt.year == thisYear) {
          current += val;
        } else if (dt.year == prevYear) {
          previous += val;
        }
      }
    }

    // 🔒 BUG FIX: Calculate and set BOTH growth percentage variables
    final calculatedGrowth = previous == 0
        ? (current > 0 ? 100.0 : 0.0)
        : ((current - previous) / previous) * 100;
    
    filteredGrowthPercentage = calculatedGrowth;
    growthPercentage = calculatedGrowth; // 🔒 FIX: Also set the main growthPercentage
  }

  String _findBestHour(Map<int, double> hourRevenue) {
    if (hourRevenue.isEmpty) return 'No Sales';
    double maxVal = -1;
    int bestH = -1;
    hourRevenue.forEach((h, v) {
      if (v > maxVal) { maxVal = v; bestH = h; }
    });
    if (bestH < 0 || maxVal <= 0) return 'No Sales';
    return _formatHourRange(bestH);
  }

  String _formatHourRange(int hour) {
    String fmt(int h) {
      if (h == 0) return '12 AM';
      if (h < 12) return '$h AM';
      if (h == 12) return '12 PM';
      return '${h - 12} PM';
    }
    return '${fmt(hour)} - ${fmt((hour + 1) % 24)}';
  }
}