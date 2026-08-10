import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:synchronized/synchronized.dart';
import 'local_storage_service.dart';

class SyncQueueManager {
  static const String _queueBoxName = 'sync_queue_secure_v3';
  static Box? _box;
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  // 🔒 CRITICAL: Lock for queue operations to prevent race conditions
  static final _queueLock = Lock();

  // 🔒 CRITICAL: Enhanced sync lock with timeout and deadlock prevention
  static bool isSyncing = false;
  static DateTime? _syncStartTime;
  static const Duration _syncTimeout = Duration(minutes: 5); // 5 minute sync timeout
  static Timer? _syncTimeoutTimer;

  /// Set sync lock with timeout protection
  static Future<bool> _setSyncLock() async {
    if (isSyncing) {
      // Check if sync has been running too long (deadlock detection)
      if (_syncStartTime != null && 
          DateTime.now().difference(_syncStartTime!) > _syncTimeout) {
        if (kDebugMode) debugPrint('⚠️ Sync timeout detected, forcing lock reset');
        await _clearSyncLock();
      } else {
        if (kDebugMode) debugPrint('⚠️ Sync already in progress');
        return false;
      }
    }
    
    isSyncing = true;
    _syncStartTime = DateTime.now();
    
    // Set timeout timer to prevent deadlocks
    _syncTimeoutTimer?.cancel();
    _syncTimeoutTimer = Timer(_syncTimeout, () async {
      if (kDebugMode) debugPrint('⚠️ Sync timeout, forcing lock reset');
      await _clearSyncLock();
    });
    
    if (kDebugMode) debugPrint('🔒 Sync lock set');
    return true;
  }
  
  /// Clear sync lock safely
  static Future<void> _clearSyncLock() async {
    isSyncing = false;
    _syncStartTime = null;
    _syncTimeoutTimer?.cancel();
    _syncTimeoutTimer = null;
    if (kDebugMode) debugPrint('🔓 Sync lock cleared');
  }
  
  /// 🔒 DATA VALIDATION: Validate queue data before queuing
  static bool _validateQueueData(String action, Map<String, dynamic> data) {
    try {
      // Validate action is not empty
      if (action.isEmpty) {
        if (kDebugMode) debugPrint('⚠️ Empty action in queue data');
        return false;
      }
      
      // Validate data is not empty
      if (data.isEmpty) {
        if (kDebugMode) debugPrint('⚠️ Empty data in queue');
        return false;
      }
      
      // Action-specific validation
      switch (action) {
        case 'save_sale':
          // Validate sale data has required fields
          if (!data.containsKey('sale_id') || data['sale_id'] == null) {
            if (kDebugMode) debugPrint('⚠️ Missing sale_id in save_sale data');
            return false;
          }
          break;
        case 'save_customer':
          // Validate customer data has required fields
          if (!data.containsKey('customer_id') && !data.containsKey('phone')) {
            if (kDebugMode) debugPrint('⚠️ Missing customer identification in save_customer data');
            return false;
          }
          break;
        case 'update_inventory':
          // Validate inventory data has required fields
          if (!data.containsKey('product_id') || data['product_id'] == null) {
            if (kDebugMode) debugPrint('⚠️ Missing product_id in update_inventory data');
            return false;
          }
          break;
      }
      
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Queue data validation error: $e');
      return false;
    }
  }
  
  static Future<List<int>> _getHiveKey() async {
    const keyStr = 'hive_encryption_key';
    String? stored = await _secureStorage.read(key: keyStr);
    if (stored == null) {
      final key = Hive.generateSecureKey();
      await _secureStorage.write(key: keyStr, value: base64UrlEncode(key));
      return key;
    }
    return base64Url.decode(stored);
  }

  static Future<Box> _getBox() async {
    return await _queueLock.synchronized(() async {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getInt('user_id') ?? prefs.getInt('userId');
      final String scopedName = (userId == null || userId == 0)
          ? '${_queueBoxName}_unauthenticated'
          : '${_queueBoxName}_$userId';

      if (_box != null && _box!.isOpen && _box!.name == scopedName) return _box!;

      final key = await _getHiveKey();
      _box = await Hive.openBox(scopedName, encryptionCipher: HiveAesCipher(key));

      // Auto-recover any sales saved while app was stuck in unauthenticated state
      if (userId != null && userId > 0) {
        try {
          final unauthName = '${_queueBoxName}_unauthenticated';
          final unauthBox = await Hive.openBox(unauthName, encryptionCipher: HiveAesCipher(key));
          if (unauthBox.isNotEmpty) {
            if (kDebugMode) debugPrint('📦 [SyncQueue] Recovering ${unauthBox.length} items from unauthenticated queue');
            for (final k in unauthBox.keys) {
              await _box!.put(k, unauthBox.get(k));
            }
            await unauthBox.clear();
          }
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ [SyncQueue] Error recovering unauth queue: $e');
        }
      }

      return _box!;
    });
  }

  /// Add item to sync queue with data validation
  static Future<void> enqueue(String action, Map<String, dynamic> data) async {
    await _queueLock.synchronized(() async {
      try {
        // 🔒 DATA VALIDATION: Validate data before queuing
        if (!_validateQueueData(action, data)) {
          if (kDebugMode) debugPrint('⚠️ Invalid queue data for action: $action');
          return;
        }

        final box = await _getBox();

        // Prevent unbounded queue growth (OOM protection)
        if (box.length >= 500) {
          if (kDebugMode) debugPrint('📦 [SyncQueue] Queue limit reached (500). Dropping oldest item.');
          if (box.isNotEmpty) {
            await box.delete(box.keys.first);
          }
        }

        // 🔧 FIX: Check if sale_id already exists in queue (idempotency)
        if (action == 'save_sale' && data.containsKey('sale_id')) {
          final saleId = data['sale_id'].toString();
          Map<String, dynamic>? existing;
          try {
            existing = box.values.cast<Map<String, dynamic>>().firstWhere(
              (item) => item['action'] == 'save_sale' &&
                         item['data']['sale_id']?.toString() == saleId,
            );
          } catch (e) {
            existing = null;
          }
          if (existing != null) {
            if (kDebugMode) debugPrint('📦 [SyncQueue] Sale $saleId already in queue - skipping duplicate');
            return;
          }
        }

        // Generate unique Action ID
        final String actionId = sha256.convert(utf8.encode('$action${json.encode(data)}${DateTime.now().microsecondsSinceEpoch}')).toString().substring(0, 16);

        final item = {
          'action_id': actionId,
          'action': action,
          'data': data,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'retries': 0,
        };

        await box.put(actionId, item);
        if (kDebugMode) debugPrint('📦 [SyncQueue] Queued: $action ($actionId)');
      } catch (e) {
        if (kDebugMode) debugPrint('❌ [SyncQueue] Enqueue Error: $e');
      }
    });
  }

  /// Get the oldest item from queue
  static Future<Map<String, dynamic>?> peek() async {
    return await _queueLock.synchronized(() async {
      try {
        final box = await _getBox();
        if (box.isEmpty) return null;

        // Hive values are not necessarily ordered by insertion if we use keys
        // But we can get the first one
        return Map<String, dynamic>.from(box.values.first);
      } catch (e) {
        return null;
      }
    });
  }

  /// Remove item by ID
  static Future<void> remove(String actionId) async {
    await _queueLock.synchronized(() async {
      final box = await _getBox();
      await box.delete(actionId);
    });
  }

  /// Update item (e.g. increment retries)
  static Future<void> update(String actionId, Map<String, dynamic> item) async {
    await _queueLock.synchronized(() async {
      final box = await _getBox();
      await box.put(actionId, item);
    });
  }

  /// Get all pending items
  static Future<List<Map<String, dynamic>>> getAll() async {
    return await _queueLock.synchronized(() async {
      final box = await _getBox();
      return box.values.map((e) => Map<String, dynamic>.from(e)).toList();
    });
  }

  static Future<int> getQueueSize() async {
    return await _queueLock.synchronized(() async {
      final box = await _getBox();
      return box.length;
    });
  }

  static Future<void> clearQueue() async {
    await _queueLock.synchronized(() async {
      try {
        final box = await _getBox();
        await box.clear();
      } catch (e) {
        if (kDebugMode) debugPrint('⚠️ clearQueue: $e');
      }
    });
  }

  /// Drop cached box handle so next enqueue opens the correct user-scoped box.
  static Future<void> resetBoxReference() async {
    await _queueLock.synchronized(() async {
      if (_box != null && _box!.isOpen) {
        try {
          await _box!.close();
        } catch (_) {}
      }
      _box = null;
    });
  }

  /// Dispose resources - called during app shutdown
  static Future<void> dispose() async {
    await _queueLock.synchronized(() async {
      try {
        // Cancel sync timeout timer
        _syncTimeoutTimer?.cancel();
        _syncTimeoutTimer = null;

        // Clear sync lock
        await _clearSyncLock();

        // Close box if open
        if (_box != null && _box!.isOpen) {
          try {
            await _box!.close();
          } catch (_) {}
        }
        _box = null;

        if (kDebugMode) debugPrint('✅ SyncQueueManager disposed');
      } catch (e) {
        if (kDebugMode) debugPrint('⚠️ Error disposing SyncQueueManager: $e');
      }
    });
  }
}
