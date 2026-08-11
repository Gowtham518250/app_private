import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:synchronized/synchronized.dart';
import 'api_client.dart';
import 'models.dart';
import 'local_storage_service.dart';
import 'secure_token_storage.dart';
import 'sync_queue_manager.dart';
import 'sale_service.dart';
import 'error_log_helper.dart';
import 'sales_dedup_helper.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'agent_debug_log.dart';

class SyncService {
  static DateTime? _lastServerTime;
  static Duration? _serverTimeOffset;  // Duration, not DateTime!
  
  static final _syncStatusController = StreamController<int>.broadcast();
  static Stream<int> get syncQueueStream => _syncStatusController.stream;
  
  // 🔒 Use Lock for atomic operations (prevents race conditions)
  static final _syncLock = Lock();
  
  static final _refreshNotifier = StreamController<void>.broadcast();
  static Stream<void> get refreshStream => _refreshNotifier.stream;
  /// Public method: call after saving to Hive to force Dashboard to reload.
  static void triggerDashboardRefresh() {
    try { _refreshNotifier.add(null); } catch (_) {}
  }
  static Timer? _pulseTimer;
  static bool _initialized = false;
  static StreamSubscription<ConnectivityResult>? _connectivitySub;

  /// Initialize and start periodic sync workers
  static Future<void> init() async {
    if (_initialized) {
      if (kDebugMode) debugPrint('⚠️ SyncService already initialized, skipping...');
      return;
    }
    _initialized = true;
    
    try {
      // Listen for connectivity changes
      _connectivitySub?.cancel();
      _connectivitySub = Connectivity().onConnectivityChanged.listen((dynamic result) {
        final bool isOffline = result is List 
            ? (result.isEmpty || (result.length == 1 && result.first == ConnectivityResult.none))
            : result == ConnectivityResult.none;
            
        if (!isOffline) {
          processQueueSafe();
          downloadUserDataSafe();
        }
      });

      // 🚀 Start LivePulseTimer (Runs every 60 seconds)
      _startPulseTimer();
      
      // Initial sync
      await processQueueSafe();
      await downloadUserDataSafe();
      
      if (kDebugMode) debugPrint('✅ SyncService initialized successfully');
    } catch (e) {
      await ErrorLogHelper.logException(e, StackTrace.current, context: 'SyncService.init');
    }
  }
  
  /// Start or restart the pulse timer
  static void _startPulseTimer() {
    _pulseTimer?.cancel();
    // 🚨 DATA-LOSS-PREVENTION FIX: shortened 60s -> 20s AND now also drives the
    // pending sync queue (sales, purchase orders, stock updates, etc). Previously
    // this timer only re-downloaded data; the queue itself only re-ran on a
    // connectivity-change EVENT, which frequently never fires on flaky mobile/5G
    // networks (tower handoffs, weak-signal "still connected" states). That gap is
    // exactly why a sale could sit unsynced for a long time despite having signal.
    _pulseTimer = Timer.periodic(const Duration(seconds: 20), (timer) async {
      if (!_initialized) return;

      try {
        final connection = await Connectivity().checkConnectivity();
        if (connection != ConnectivityResult.none) {
          // Always try to flush the pending queue first — this is the data that
          // must not be lost (sales, purchase orders, stock decrements, etc).
          await processQueueSafe();
          await downloadUserDataSafe();
          _refreshNotifier.add(null); // Notify UI to rebuild
        }
      } catch (e) {
        if (kDebugMode) debugPrint('⚠️ Pulse timer error: $e');
        await ErrorLogHelper.logException(e, StackTrace.current, context: 'SyncService.pulseTimer');
      }
    });
  }
  
  /// Dispose all resources
  static Future<void> dispose() async {
    if (kDebugMode) debugPrint('🛑 Disposing SyncService...');
    _pulseTimer?.cancel();
    _pulseTimer = null;
    await _connectivitySub?.cancel();
    _connectivitySub = null;
    _initialized = false;
    
    try {
      await _syncStatusController.close();
      await _refreshNotifier.close();
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Error closing streams: $e');
    }
  }
  
  static Future<bool> checkInWorker(String workerId) async {
    try {
      final token = await SecureTokenStorage.getToken() ?? '';
      if (token.isEmpty) {
        await ErrorLogHelper.logMessage('Token unavailable for checkIn', level: 'WARNING');
        return false;
      }

      final res = await ApiClient.postJson(
        '${ApiClient.checkIn}?employee_id=$workerId',
        {},
        headers: {'Authorization': 'Bearer $token'}
      );
      
      if (res.statusCode == 200 || res.statusCode == 201) {
        if (kDebugMode) debugPrint('✅ Worker checked in: $workerId');
        return true;
      } else {
        await ErrorLogHelper.logMessage(
          'Worker check-in failed: ${res.statusCode}',
          level: 'ERROR',
          attributes: {'workerId': workerId, 'status': res.statusCode.toString()},
        );
        return false;
      }
    } catch (e) {
      await ErrorLogHelper.logException(e, StackTrace.current, 
        context: 'SyncService.checkInWorker',
        attributes: {'workerId': workerId});
      return false;
    }
  }

  /// Syncs an individual check-out event to the backend
  static Future<bool> checkOutWorker(String workerId) async {
    try {
      final token = await SecureTokenStorage.getToken() ?? '';
      if (token.isEmpty) {
        await ErrorLogHelper.logMessage('Token unavailable for checkOut', level: 'WARNING');
        return false;
      }

      final res = await ApiClient.postJson(
        '${ApiClient.checkOut}?employee_id=$workerId',
        {},
        headers: {'Authorization': 'Bearer $token'}
      );
      
      if (res.statusCode == 200 || res.statusCode == 201) {
        if (kDebugMode) debugPrint('✅ Worker checked out: $workerId');
        return true;
      } else {
        await ErrorLogHelper.logMessage(
          'Worker check-out failed: ${res.statusCode}',
          level: 'ERROR',
          attributes: {'workerId': workerId, 'status': res.statusCode.toString()},
        );
        return false;
      }
    } catch (e) {
      await ErrorLogHelper.logException(e, StackTrace.current,
        context: 'SyncService.checkOutWorker',
        attributes: {'workerId': workerId});
      return false;
    }
  }
  
  /// Syncs worker profile data to the backend
  static Future<bool> syncWorkerProfile(Map<String, dynamic> workerData) async {
    try {
      final token = await SecureTokenStorage.getToken() ?? '';
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs?.getInt('user_id') ?? prefs?.getInt('userId');
      
      if (token.isEmpty || userId == null) {
        await ErrorLogHelper.logMessage('Missing token or userId for worker sync', level: 'WARNING');
        return false;
      }

      final res = await ApiClient.postJson(
        '${ApiClient.attendancePrefix}/workers?user_id=$userId',
        workerData,
        headers: {'Authorization': 'Bearer $token'},
      );
      
      if (res.statusCode == 200 || res.statusCode == 201) {
        if (kDebugMode) debugPrint('✅ Worker profile synced: ${workerData['id'] ?? 'unknown'}');
        return true;
      } else {
        await ErrorLogHelper.logMessage(
          'Worker profile sync failed: ${res.statusCode}',
          level: 'ERROR',
          attributes: {'worker': workerData['id']?.toString() ?? 'unknown'},
        );
        return false;
      }
    } catch (e) {
      await ErrorLogHelper.logException(e, StackTrace.current,
        context: 'SyncService.syncWorkerProfile');
      return false;
    }
  }

  /// Downloads user data (workers, shop details) from backend - Thread-safe
  static Future<void> downloadUserDataSafe() async {
    await _syncLock.synchronized(() async {
      try {
        await _downloadUserDataImpl();
      } catch (e) {
        await ErrorLogHelper.logException(e, StackTrace.current, context: 'SyncService.downloadUserData');
      }
    });
  }

  /// Internal implementation - calls Synchronized
  static Future<void> _downloadUserDataImpl() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs == null) {
        await ErrorLogHelper.logMessage('SharedPreferences unavailable', level: 'WARNING');
        return;
      }
      
      final userId = prefs.getInt('user_id') ?? prefs.getInt('userId');
      if (userId == null) {
        if (kDebugMode) debugPrint('⚠️ No userId found, skipping download');
        return;
      }

      // 1. Fetch Workers
      try {
        final token = await SecureTokenStorage.getToken() ?? '';
        if (token.isEmpty) {
          await ErrorLogHelper.logMessage('Token unavailable for worker fetch', level: 'WARNING');
        } else {
        final res = await ApiClient.getJson('${ApiClient.attendancePrefix}/workers?user_id=$userId', headers: {
          'Authorization': 'Bearer $token',
        });
        
        if (res.statusCode == 200) {
          final List<dynamic> workers = jsonDecode(res.body);
          await prefs.setString('workers_json', jsonEncode(workers));
          if (kDebugMode) debugPrint('✅ Workers downloaded: ${workers.length} records');
        } else {
          await ErrorLogHelper.logMessage(
            'Worker fetch failed: ${res.statusCode}',
            level: 'WARNING',
          );
        }
        }
      } catch (e) {
        await ErrorLogHelper.logException(e, StackTrace.current, context: 'SyncService.downloadWorkers');
      }

      // 2. Fetch Invoices/Sales (to populate Dashboard and Credit Book)
      try {
        final token = await SecureTokenStorage.getToken() ?? '';
        if (token.isNotEmpty) {
          final List<dynamic> allApiItems = [];
          
          // Fetch invoices from /api/invoices/
          try {
            final invoicesRes = await ApiClient.getJson(ApiClient.invoicesList, headers: {
              'Authorization': 'Bearer $token',
            });
            if (invoicesRes.statusCode == 200) {
              final decoded = jsonDecode(invoicesRes.body);
              final invoices = decoded is List ? decoded : (decoded['invoices'] ?? decoded['results'] ?? []);
              allApiItems.addAll(invoices);
            }
          } catch (e) {
            if (kDebugMode) debugPrint('⚠️ Failed to fetch invoices from /api/invoices: $e');
          }
          
          // Fetch sales from /auth/sales
          try {
            final salesRes = await ApiClient.getJson('/auth/sales', headers: {
              'Authorization': 'Bearer $token',
            });
            if (salesRes.statusCode == 200) {
              final sales = jsonDecode(salesRes.body);
              if (sales is List) allApiItems.addAll(sales);
            }
          } catch (e) {
            if (kDebugMode) debugPrint('⚠️ Failed to fetch sales from /auth/sales: $e');
          }
          
          final currentLocal = await LocalStorageService.loadSales();
          final localBills = currentLocal
              .whereType<Map>()
              .map((s) => Map<String, dynamic>.from(s))
              .toList();
          final existingIds = localBills.map((s) => s['sale_id'].toString()).toSet();
          final List<Map<String, dynamic>> newItems = [];

          // Group API rows — /auth/sales returns one row per line item (flattened)
          final Map<String, List<dynamic>> grouped = {};
          for (final item in allApiItems) {
            if (item is! Map) continue;
            final saleId = (item['invoice_number'] ?? item['sale_id'] ?? item['number'] ?? '').toString();
            if (saleId.isEmpty) continue;
            grouped.putIfAbsent(saleId, () => []).add(item);
          }

          for (final entry in grouped.entries) {
            final saleId = entry.key;
            if (existingIds.contains(saleId)) continue;

            final firstItem = entry.value.first as Map;
            dynamic rawLineItems = firstItem['line_items'] ?? firstItem['items'];
            if (rawLineItems == null || (rawLineItems is List && rawLineItems.isEmpty)) {
              rawLineItems = entry.value;
            }
            if (rawLineItems is! List || rawLineItems.isEmpty) continue;
            
            final validItems = <Map<String, dynamic>>[];
            for (final li in rawLineItems) {
              if (li is! Map) continue;
              final name = (li['product_name'] ?? li['description'] ?? li['item'] ?? li['name'] ?? li['product'] ?? '').toString().trim();
              if (name.isEmpty || name.toLowerCase() == 'unknown' || name.toLowerCase() == 'unknown item') continue;
              
              final double price = double.tryParse((li['unit_price'] ?? li['price'] ?? 0).toString()) ?? 0.0;
              final double qty = double.tryParse((li['quantity'] ?? li['qty'] ?? 1).toString()) ?? 1.0;
              final double lineTotal = double.tryParse((li['line_total'] ?? li['total'] ?? li['total_with_tax'] ?? (price * qty)).toString()) ?? price * qty;
              
              validItems.add({
                'product_name': name,
                'item': name,
                'name': name,
                'product': name,
                'qty': qty,
                'quantity': qty,
                'price': price,
                'unit_price': price,
                'total': lineTotal,
                'line_total': lineTotal,
                'total_with_tax': lineTotal,
              });
            }
            if (validItems.isEmpty) continue;
            
            final businessDate = firstItem['business_date'] ??
                firstItem['sale_date'] ??
                firstItem['invoice_date'] ??
                firstItem['date'];
            newItems.add({
              'sale_id': saleId,
              'customer_name': firstItem['customer_name'] ?? 'Cash Customer',
              'customer_phone': firstItem['customer_phone'] ?? '',
              'items': validItems,
              'business_date': businessDate,
              'created_at': firstItem['created_at'],
              'updated_at': firstItem['updated_at'],
              'total': firstItem['total_amount']?.toString() ?? firstItem['total']?.toString() ?? firstItem['totalAmount']?.toString() ?? '0',
              'paid_amount': firstItem['paid_amount']?.toString() ?? '0',
              'payment_status': firstItem['payment_status'] ?? 'PAID',
              'sync_status': 'synced',
              'is_synced': true,
              'source': 'cloud_restore',
            });
          }

          // #region agent log
          AgentDebugLog.log(
            location: 'sync_service.dart:downloadUserData',
            message: 'CLOUD MERGE RESULT',
            hypothesisId: 'H4',
            data: {
              'apiItemCount': allApiItems.length,
              'groupedBills': grouped.length,
              'newItemsMerged': newItems.length,
            },
          );
          // #endregion

          if (newItems.isNotEmpty) {
            final List<Map<String, dynamic>> merged = [...localBills, ...newItems];
            final deduped = SalesDedupHelper.dedupeBills(merged);
            await LocalStorageService.saveSales(deduped);
            if (kDebugMode) {
              debugPrint('✅ Cloud restore: ${newItems.length} new bills from API');
            }
            _refreshNotifier.add(null);
          }
        }
      } catch (e) {
        await ErrorLogHelper.logException(e, StackTrace.current, context: 'SyncService.downloadSales');
      }

      // Option B: always run one-time dedupe after cloud fetch
      final cleanup = await SalesDedupHelper.cleanupAndPersist();
      if (cleanup.removed > 0) {
        _refreshNotifier.add(null);
      }
      
    } catch (e) {
      await ErrorLogHelper.logException(e, StackTrace.current, context: 'SyncService._downloadUserDataImpl');
    }
  }


  /// Fallback: POST each line to /auth/sales (works when /api/invoices/* returns 500).
  static Future<bool> syncViaLegacyAuthSales({
    required String saleId,
    required List<Map<String, dynamic>> lineItems,
    String? token,
    String? businessDate,
  }) async {
    if (lineItems.isEmpty) return false;
    final String authToken = token?.isNotEmpty == true
        ? token!
        : (await SecureTokenStorage.getToken() ?? '');
    if (authToken.isEmpty) {
      AgentDebugLog.log(
        location: 'sync_service.dart:syncViaLegacyAuthSales',
        message: 'LEGACY SYNC ABORTED — no token',
        hypothesisId: 'H8',
        data: {'saleId': saleId},
      );
      return false;
    }
    final String? saleDate = businessDate;
    int synced = 0;
    final List<Map<String, dynamic>> lineErrors = [];
    for (int i = 0; i < lineItems.length; i++) {
      final item = lineItems[i];
      final name = (item['product_name'] ?? item['product'] ?? 'Item').toString();
      final priceVal = (item['unit_price'] ?? item['price'] ?? 0);
      final price = (priceVal is num ? priceVal.toDouble() : double.tryParse(priceVal.toString()) ?? 0.0);
      final qtyVal = (item['quantity'] ?? item['qty'] ?? 1);
      final qty = (qtyVal is num ? qtyVal.toDouble() : double.tryParse(qtyVal.toString()) ?? 1.0);
      final lineTotalVal = item['line_total'] ?? item['total'] ?? (price * qty);
      final lineTotal = (lineTotalVal is num ? lineTotalVal.toDouble() : double.tryParse(lineTotalVal.toString()) ?? price * qty);
      final body = <String, dynamic>{
        'product_name': name,
        'product': name,
        'price': price.toString(),
        'quantity': qty.toStringAsFixed(3), // Fix Bug #8: preserve fractional quantities
        'total': lineTotal.toString(),
        'sale_id': saleId,
        if (saleDate != null && saleDate.isNotEmpty) 'date': saleDate,
      };
      try {
        // Fix Bug #13: Use JSON post and decode response body to Map
        final resp = await ApiClient.postJson(
          ApiClient.salesEndpoint,
          body,
          headers: {'Authorization': 'Bearer $authToken'},
        );
        final Map<String, dynamic> res = resp.body.isNotEmpty
            ? (jsonDecode(resp.body) as Map<String, dynamic>)
            : <String, dynamic>{};

        if (res['status'] == 'success' || res['success'] == true || res['id'] != null) {
          synced++;
        } else {
          lineErrors.add({'index': i, 'error': res['message'] ?? 'Unknown error'});
        }
      } catch (e) {
        lineErrors.add({'index': i, 'error': e.toString()});
      }
    }
    final ok = synced == lineItems.length;
    AgentDebugLog.log(
      location: 'sync_service.dart:syncViaLegacyAuthSales',
      message: 'LEGACY /auth/sales sync',
      hypothesisId: 'H7',
      data: {'saleId': saleId, 'synced': synced, 'total': lineItems.length, 'success': ok, 'errors': lineErrors},
    );
    return ok;
  }

  /// High-reliability sale sync (Queued by default for offline-first)
  static Future<void> syncSale(Map<String, dynamic> sale) async {
    try {
      await SyncQueueManager.enqueue('sync_sale', sale);
      _syncStatusController.add(await SyncQueueManager.getQueueSize());
      await processQueueSafe();
    } catch (e) {
      await ErrorLogHelper.logException(e, StackTrace.current, context: 'SyncService.syncSale');
    }
  }

  /// Update payment status - queued for offline safety
  static Future<void> updateSalePayment(String saleId, String status, double amount) async {
    try {
      await SyncQueueManager.enqueue('update_payment', {
        'invoice_number': saleId,
        'payment_status': status,
        'paid_amount': amount,
      });
      _syncStatusController.add(await SyncQueueManager.getQueueSize());
      await processQueueSafe();
    } catch (e) {
      await ErrorLogHelper.logException(e, StackTrace.current, context: 'SyncService.updateSalePayment');
    }
  }

  /// Process sync queue - Thread-safe with Lock
  static Future<void> processQueueSafe() async {
    if (SyncQueueManager.isSyncing) {
      if (kDebugMode) debugPrint('⚠️ Sync already in progress, skipping overlap');
      return;
    }
    SyncQueueManager.isSyncing = true;
    try {
      await _syncLock.synchronized(() async {
        try {
          await _processQueueImpl();
        } catch (e) {
          await ErrorLogHelper.logException(e, StackTrace.current, context: 'SyncService.processQueue');
        }
      });
    } finally {
      SyncQueueManager.isSyncing = false;
    }
  }

  /// Internal queue processing implementation
  static Future<void> _processQueueImpl() async {
    try {
      final dynamic connection = await Connectivity().checkConnectivity();
      final bool isOffline = connection is List 
          ? (connection.isEmpty || (connection.length == 1 && connection.first == ConnectivityResult.none))
          : connection == ConnectivityResult.none;
          
      if (isOffline) {
        _syncStatusController.add(await SyncQueueManager.getQueueSize());
        return;
      }

      final List<Map<String, dynamic>> pending = await SyncQueueManager.getAll();
      if (kDebugMode) debugPrint('🔄 Processing sync queue: ${pending.length} items');

      int successCount = 0;
      int failureCount = 0;
      int consecutiveNetworkFailures = 0;

      for (var item in pending) {
        if (consecutiveNetworkFailures >= 3) {
          if (kDebugMode) debugPrint('🛑 Circuit Breaker triggered. API seems down.');
          break; // Stop processing the queue
        }

        final actionId = item['action_id'];
        final action = item['action'];
        final status = item['status'];
        
        if (status == 'PARKED') continue; // Skip permanently failed items
        
        // Exponential backoff check
        final retries = item['retries'] ?? 0;
        final lastAttemptStr = item['last_attempt'];
        if (retries > 0 && lastAttemptStr != null) {
          final lastAttempt = DateTime.tryParse(lastAttemptStr);
          if (lastAttempt != null) {
            // 🛡️ FIX: previously this jumped straight to a 2-minute mandatory
            // wait after just the FIRST failure (1 << 1 minutes), then 4, then
            // 8... A single transient blip (a 5G handoff, one dropped packet)
            // would lock a sale out of retrying for 2+ minutes even though the
            // very next attempt would likely succeed instantly, which is what
            // produced sales that looked "stuck" for a long time on a
            // perfectly fine network. Give the first couple of retries a
            // short, second-scale wait, and only escalate to minutes-scale
            // backoff once several consecutive failures actually suggest a
            // real outage rather than one bad packet.
            final backoffSeconds = switch (retries) {
              1 => 15,
              2 => 45,
              3 => 120,
              _ => 60 * (1 << (retries - 3 > 3 ? 3 : retries - 3)), // caps at 8 min
            };
            if (DateTime.now().difference(lastAttempt).inSeconds < backoffSeconds) {
              continue; // Wait for backoff period
            }
          }
        }

        final data = Map<String, dynamic>.from(item['data'] ?? {});
        bool success = false;

        try {
          switch (action) {
            case 'sync_sale':
              success = await _syncSaleItem(data);
              break;

            case 'save_sale':
            case 'create_sale':
              success = await _syncSaleBatchItem(data);
              break;

            case 'sync_invoice_batch':
              success = await _syncInvoiceBatchItem(data);
              break;

            case 'update_payment':
            case 'update_invoice_payment':
              success = await _updatePaymentItem(data);
              break;
              
            case 'update_invoice_paid':
            case 'update_invoice_unpaid':
              success = await _updateInvoiceItem(data, action);
              break;
              
            case 'send_daily_email':
              success = await _sendEmailItem(data);
              break;
              
            case 'worker_profile':
              success = await syncWorkerProfile(data);
              break;

            case 'decrease_stock':
              success = await _decreaseStockItem(data);
              break;
              
            case 'update_local_product':
              success = await _updateLocalProductItem(data);
              break;

            case 'create_purchase_order':
              success = await _createPurchaseOrderItem(data);
              break;

            case 'update_purchase_order_status':
              success = await _updatePurchaseOrderStatusItem(data);
              break;

            case 'record_khata_payment':
              success = await _recordKhataPaymentItem(data);
              break;

            case 'save_customer':
            case 'create_customer':
              success = await _saveCustomerItem(data);
              break;

            default:
              if (kDebugMode) debugPrint('⚠️ Unknown action: $action');
              success = false;
          }

          if (success) {
            await SyncQueueManager.remove(actionId);
            successCount++;
            consecutiveNetworkFailures = 0; // Reset circuit breaker
            if (action == 'save_sale' || action == 'sync_sale') {
              final saleId = data['sale_id']?.toString() ?? data['invoice_number']?.toString() ?? '';
              if (saleId.isNotEmpty) {
                await SaleService.markSaleAsSynced(saleId);
                SyncService.triggerDashboardRefresh();
              }
            }
            if (action == 'create_purchase_order' || action == 'update_purchase_order_status') {
              SyncService.triggerDashboardRefresh();
            }
          } else {
            // Increment retry count
            item['retries'] = (item['retries'] ?? 0) + 1;
            item['last_attempt'] = DateTime.now().toIso8601String();
            // We DO NOT park sales anymore. Keep retrying until the internet successfully delivers them.
            if (kDebugMode) debugPrint('⚠️ Action $actionId failed, will retry later.');
            await SyncQueueManager.update(actionId, item);
            failureCount++;
            consecutiveNetworkFailures++;
          }
        } catch (e, stack) {
          await ErrorLogHelper.logException(e, stack,
            context: 'SyncService._processQueueImpl - action: $action',
            attributes: {'action_id': actionId, 'action': action},
          );
          failureCount++;
          consecutiveNetworkFailures++;
          
          // Update retry count
          item['retries'] = (item['retries'] ?? 0) + 1;
          item['last_attempt'] = DateTime.now().toIso8601String();
          // We DO NOT park sales anymore. Keep retrying until the internet successfully delivers them.
          await SyncQueueManager.update(actionId, item);
        }
      }

      _syncStatusController.add(await SyncQueueManager.getQueueSize());
      
      if (kDebugMode) {
        debugPrint('✅ Sync complete: $successCount succeeded, $failureCount failed');
      }
    } catch (e) {
      await ErrorLogHelper.logException(e, StackTrace.current, context: 'SyncService._processQueueImpl');
    }
  }

  /// Sync one or many line items for a single bill (idempotent).
  static Future<bool> _syncSaleBatchItem(Map<String, dynamic> data) async {
    // NEW LOGIC: Use the endpoint and payload structure if it exists
    if (data.containsKey('endpoint') && data.containsKey('payload')) {
      try {
        final token = await SecureTokenStorage.getToken() ?? '';
        final payload = Map<String, dynamic>.from(data['payload'] as Map);
        final saleId = data['sale_id']?.toString() ?? payload['invoice_number']?.toString() ?? '';
        final rawLines = payload['line_items'];
        if (saleId.isNotEmpty && rawLines is List && rawLines.isNotEmpty) {
          final lineItems = rawLines.map((e) => Map<String, dynamic>.from(e as Map)).toList();
          if (await syncViaLegacyAuthSales(
            saleId: saleId,
            lineItems: lineItems,
            token: token,
            businessDate: payload['business_date'] ?? payload['invoice_date'] ?? payload['sale_date'] ?? payload['date'],
          )) {
            return true;
          }
        }

        final res = await ApiClient.postJson(
          data['endpoint'],
          data['payload'],
          headers: {
            if (token.isNotEmpty) 'Authorization': 'Bearer $token',
          }
        ).timeout(const Duration(seconds: 15));
        
        return res.statusCode == 200 || res.statusCode == 201;
      } catch (e) {
        if (kDebugMode) debugPrint('⚠️ Offline Sale/Invoice Sync failed: $e');
        return false;
      }
    }
    // LEGACY: Use the full invoice payload if it exists
    if (data.containsKey('invoice_payload')) {
      try {
        final token = await SecureTokenStorage.getToken() ?? '';
        final res = await ApiClient.postJson(
          ApiClient.invoicesSync,
          data['invoice_payload'],
          headers: {
            if (token.isNotEmpty) 'Authorization': 'Bearer $token',
          }
        ).timeout(const Duration(seconds: 15));
        
        return res.statusCode == 200 || res.statusCode == 201;
      } catch (e) {
        if (kDebugMode) debugPrint('⚠️ Offline Sale Sync failed: $e');
        return false;
      }
    }

    // LEGACY FALLBACK: If old queue items still exist without invoice_payload
    final saleId = data['sale_id']?.toString() ?? '';
    final rawItems = data['items'];
    if (rawItems is List && rawItems.isNotEmpty) {
      int synced = 0;
      for (int i = 0; i < rawItems.length; i++) {
        final item = Map<String, dynamic>.from(rawItems[i] as Map);
        final price = double.tryParse(item['price']?.toString() ?? '0') ?? 0;
        final qty = double.tryParse(item['qty']?.toString() ?? item['quantity']?.toString() ?? '1') ?? 0;
        if (price <= 0 || qty <= 0) continue;
        final saleDate = data['business_date'] ??
          data['sale_date'] ??
          data['invoice_date'] ??
          data['date'];

        final body = {
          'product': item['product_name'] ?? item['product'] ?? 'Item',
          'price': item['price']?.toString() ?? '0',
          'quantity': item['qty']?.toString() ?? item['quantity']?.toString() ?? '1',
          'total': (price * qty).toString(),
          'sale_id': saleId,
          if (saleDate != null && saleDate.toString().isNotEmpty)
            'date': saleDate,
          'idempotency_key': data['idempotency_key'] ?? '${saleId}_item_$i',
        };
        if (await _syncSaleItem(body)) synced++;
      }
      return synced == rawItems.length;
    }
    return await _syncSaleItem(data);
  }

  /// Sync a single sale line
  static Future<bool> _syncSaleItem(Map<String, dynamic> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs?.getInt('user_id') ?? prefs?.getInt('userId');
      if (userId != null) data['user_id'] = userId;
      
      final token = await SecureTokenStorage.getToken() ?? '';
      if (token.isEmpty) return false;
      
      final Map<String, String> formBody = data.map((k, v) => MapEntry(k, v?.toString() ?? ''));
      final res = await ApiClient.postForm(ApiClient.salesEndpoint, formBody, headers: {
        'Authorization': 'Bearer $token',
      });
      
      return res.statusCode == 200 || res.statusCode == 201;
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error syncing sale: $e');
      return false;
    }
  }

  /// Update a single payment
  static Future<bool> _updatePaymentItem(Map<String, dynamic> data) async {
    try {
      final token = await SecureTokenStorage.getToken() ?? '';
      if (token.isEmpty) return false;
      
      final res = await ApiClient.putJson('${ApiClient.invoicesPrefix}/update_payment', data, headers: {
        'Authorization': 'Bearer $token',
      });
      
      return res.statusCode == 200;
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error updating payment: $e');
      return false;
    }
  }

  /// Update invoice status
  static Future<bool> _updateInvoiceItem(Map<String, dynamic> data, String action) async {
    try {
      final token = await SecureTokenStorage.getToken() ?? '';
      if (token.isEmpty) return false;
      
      final invoiceNumber = data['invoice_number'];
      final paymentStatus = data['payment_status'];
      
      final res = await ApiClient.putJson(
        '${ApiClient.invoicesPrefix}/number/$invoiceNumber',
        {
          'payment_status': paymentStatus,
          'paid_amount': data['paid_amount'] ?? data['amount'],
          'updated_at': DateTime.now().toIso8601String(),
        },
        headers: {'Authorization': 'Bearer $token'},
      );
      
      if (res.statusCode == 200) {
        if (kDebugMode) debugPrint('✅ Invoice $invoiceNumber marked as $paymentStatus');
        return true;
      } else {
        if (kDebugMode) debugPrint('❌ Failed to update invoice: ${res.statusCode}');
        return false;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error updating invoice: $e');
      return false;
    }
  }

  /// Send daily email
  static Future<bool> _sendEmailItem(Map<String, dynamic> data) async {
    try {
      final token = await SecureTokenStorage.getToken() ?? '';
      if (token.isEmpty) return false;
      
      final res = await ApiClient.postJson(
        '/api/email/send-summary',
        data,
        headers: {'Authorization': 'Bearer $token'},
      );
      
      if (res.statusCode == 200 || res.statusCode == 201) {
        if (kDebugMode) debugPrint('📧 Daily email sent: ${data['email']}');
        return true;
      }
      return false;
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error sending email: $e');
      return false;
    }
  }

  /// Decrease stock on backend
  static Future<bool> _decreaseStockItem(Map<String, dynamic> data) async {
    try {
      final token = await SecureTokenStorage.getToken() ?? '';
      if (token.isEmpty) return false;
      
      final productId = data['product_id'];
      
      final res = await ApiClient.putJson(
        '${ApiClient.inventoryPrefix}/products/$productId/decrease-stock',
        {
          'quantity': data['quantity'],
          'reason': 'SALE',
          'reference_id': data['reference_id'] ?? 'SALE_${DateTime.now().millisecondsSinceEpoch}',
        },
        headers: {'Authorization': 'Bearer $token'},
      );
      
      return res.statusCode == 200;
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error syncing stock decrease: $e');
      return false;
    }
  }

  /// Update un-synced local product
  static Future<bool> _updateLocalProductItem(Map<String, dynamic> data) async {
    try {
      final token = await SecureTokenStorage.getToken() ?? '';
      if (token.isEmpty) return false;
      
      final id = data['id'];
      final userId = data['user_id'];
      final payload = data['payload'];
      
      final res = await ApiClient.putJson(
        '${ApiClient.inventoryPrefix}/products/$id?user_id=$userId',
        payload,
        headers: {'Authorization': 'Bearer $token'},
      );
      
      return res.statusCode == 200 || res.statusCode == 201;
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error syncing local product update: $e');
      return false;
    }
  }

  /// Create a purchase order on the backend (queued for offline safety)
  static Future<bool> _createPurchaseOrderItem(Map<String, dynamic> data) async {
    try {
      final token = await SecureTokenStorage.getToken() ?? '';
      if (token.isEmpty) return false;

      final res = await ApiClient.postJson(
        '/purchase-orders/',
        data,
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 20));

      return res.statusCode == 200 || res.statusCode == 201;
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error creating purchase order: $e');
      return false;
    }
  }

  /// Update a purchase order's status (mark-delivered / cancel) on the backend
  static Future<bool> _updatePurchaseOrderStatusItem(Map<String, dynamic> data) async {
    try {
      final token = await SecureTokenStorage.getToken() ?? '';
      if (token.isEmpty) return false;

      final poId = data['po_id'];
      final action = data['po_action']; // 'mark-delivered' or 'cancel'

      final res = await ApiClient.postJson(
        '/purchase-orders/$poId/$action',
        {},
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 20));

      return res.statusCode == 200 || res.statusCode == 201;
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error updating purchase order status: $e');
      return false;
    }
  }

  /// 🔧 FIX (data loss): khata_page.dart's "Record Payment" flow previously
  /// had NO offline handling at all — on any network failure it just
  /// showed an error toast and the payment was gone, with no retry and
  /// nothing saved locally. For a money-recording feature in an
  /// offline-first app, that's a direct path to a shop owner believing
  /// they recorded a customer's payment when the backend never received
  /// it. This mirrors the same durable-retry pattern already used for
  /// sales and purchase orders.
  static Future<bool> _recordKhataPaymentItem(Map<String, dynamic> data) async {
    try {
      final token = await SecureTokenStorage.getToken() ?? '';
      if (token.isEmpty) return false;

      final res = await ApiClient.postJson(
        '/api/khata/record-payment',
        data,
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 20));

      return res.statusCode == 200 || res.statusCode == 201;
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error syncing khata payment: $e');
      return false;
    }
  }

  /// Fix Bug #5: Save offline customer to backend
  static Future<bool> _saveCustomerItem(Map<String, dynamic> data) async {
    try {
      final token = await SecureTokenStorage.getToken() ?? '';
      if (token.isEmpty) return false;

      final payload = {
        'name': data['name'] ?? data['customer_name'] ?? '',
        'phone': data['phone'] ?? data['phone_number'] ?? '',
        'address': data['address'] ?? '',
        'email': data['email'] ?? '',
      };

      final res = await ApiClient.postJson(
        ApiClient.customersPrefix,
        payload,
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 20));

      return res.statusCode == 200 || res.statusCode == 201;
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error syncing customer: $e');
      return false;
    }
  }

  /// Fetch authoritative server time to prevent device time manipulation fraud
  /// This ensures date-based records can't be corrupted by changing device clock
  static Future<DateTime> getAuthoritativeTime() async {
    try {
      // Try to get server time from backend
      // Format: GET /api/time -> {"timestamp": "2026-04-09T15:30:00Z"}
      final response = await http.get(
        Uri.parse('${ApiClient.baseUrl}/api/time'),
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        try {
          final json = jsonDecode(response.body) as Map<String, dynamic>;
          final serverTime = DateTime.parse(json['timestamp'] as String? ?? DateTime.now().toIso8601String());
          _lastServerTime = serverTime;
          _serverTimeOffset = serverTime.difference(DateTime.now());
          if (kDebugMode) debugPrint('✅ Server time synced: ${serverTime.toIso8601String()}');
          return serverTime;
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Failed to parse server time: $e');
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Server time fetch failed: $e');
    }
    
    // Fallback: use device time + last known offset (if any)
    if (_serverTimeOffset != null) {
      return DateTime.now().add(_serverTimeOffset!);
    }
    
    // Ultimate fallback: device time (less secure)
    return DateTime.now();
  }

  /// Use authoritative time for date boundaries to prevent fraud
  /// Call this when calculating daily totals, reconciliation dates, etc.
  static Future<DateTime> getDateBoundaryTime() => getAuthoritativeTime();

  /// Validate that device time hasn't drifted >5 minutes from server
  static Future<bool> isDeviceTimeValid() async {
    try {
      final serverTime = await getAuthoritativeTime();
      final deviceTime = DateTime.now();
      final drift = serverTime.difference(deviceTime).abs();
      
      if (drift.inMinutes > 5) {
        if (kDebugMode) debugPrint('🚨 Device time drift detected: ${drift.inMinutes} minutes');
        return false;  // Device time is too far off
      }
      return true;
    } catch (e) {
      return true;  // Can't validate, assume OK
    }
  }

  // ── NEW: Enterprise Grade Invoice Syncer ──
  static Future<bool> _syncInvoiceBatchItem(Map<String, dynamic> data) async {
    try {
      final token = await SecureTokenStorage.getToken() ?? '';
      final res = await ApiClient.postJson(
        ApiClient.invoicesSync, 
        data, 
        headers: {
          if (token.isNotEmpty) 'Authorization': 'Bearer $token',
        }
      ).timeout(const Duration(seconds: 15));
      
      return res.statusCode == 200 || res.statusCode == 201;
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Offline Invoice Batch Sync failed: $e');
      return false;
    }
  }

  /// Verify synchronization state: backend + pending = local
  static Future<Map<String, dynamic>> verifySyncState() async {
    try {
      // 1. Get local sales count
      final localSales = await LocalStorageService.loadSales();
      final localCount = localSales.length;
      
      // 2. Get pending sync count
      final pendingQueue = await SyncQueueManager.getAll();
      final pendingCount = pendingQueue.length;
      
      // 3. Try to get backend count (if online)
      int backendCount = 0;
      final token = await SecureTokenStorage.getToken() ?? '';
      bool online = false;
      try {
        final connection = await Connectivity().checkConnectivity();
        online = connection != ConnectivityResult.none;
      } catch (_) {}
      
      if (online && token.isNotEmpty) {
        try {
          // Try to fetch backend sales count
          final salesResponse = await ApiClient.getJson(ApiClient.salesEndpoint, headers: {
            'Authorization': 'Bearer $token',
          });
          if (salesResponse.statusCode == 200) {
            final salesData = jsonDecode(salesResponse.body);
            if (salesData is List) {
              backendCount = salesData.length;
            } else if (salesData is Map) {
              backendCount = (salesData['count'] as num?)?.toInt() ?? 0;
            }
          }
          
          // Also fetch invoices count
          final invoicesResponse = await ApiClient.getJson(ApiClient.invoicesList, headers: {
            'Authorization': 'Bearer $token',
          });
          if (invoicesResponse.statusCode == 200) {
            final invoicesData = jsonDecode(invoicesResponse.body);
            List<dynamic> invoiceList = [];
            if (invoicesData is List) {
              invoiceList = invoicesData;
            } else if (invoicesData is Map) {
              if (invoicesData.containsKey('invoices') && invoicesData['invoices'] is List) {
                invoiceList = invoicesData['invoices'] as List<dynamic>;
              } else if (invoicesData.containsKey('results') && invoicesData['results'] is List) {
                invoiceList = invoicesData['results'] as List<dynamic>;
              }
            }
            backendCount += invoiceList.length;
          }
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Could not get backend count for verification: $e');
        }
      }
      
      // 4. Verification logic
      bool verified = true;
      String verificationMessage = '';
      
      if (online && backendCount > 0) {
        // We have backend data - verify
        final expectedTotal = backendCount + pendingCount;
        if (localCount >= expectedTotal - 10 && localCount <= expectedTotal + 10) { // Allow small buffer
          verificationMessage = '✅ Sync verified: backend ($backendCount) + pending ($pendingCount) ≈ local ($localCount)';
        } else {
          verified = false;
          verificationMessage = '❌ Sync mismatch: backend ($backendCount) + pending ($pendingCount) != local ($localCount)';
        }
      } else {
        // Offline or no backend data - can't fully verify
        verificationMessage = 'ℹ️ Offline mode: local ($localCount) sales stored, $pendingCount pending';
      }
      
      if (kDebugMode) debugPrint(verificationMessage);
      
      return {
        'verified': verified,
        'message': verificationMessage,
        'local_count': localCount,
        'pending_count': pendingCount,
        'backend_count': backendCount,
        'online': online,
      };
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Sync verification failed: $e');
      return {
        'verified': false,
        'message': 'Verification failed: $e',
        'local_count': 0,
        'pending_count': 0,
        'backend_count': 0,
        'online': false,
      };
    }
  }

}