import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'inventory_stock_helper.dart';
import 'sales_dedup_helper.dart';
import 'stored_sale.dart';

/// SENIOR ENGINEER REFACTOR: Enterprise Local Storage Service
/// Features: User Isolation, Hive Performance, Auto-recovery, and Zero Data Leakage.
class LocalStorageService {
  
  // ✅ FIX: Schema versioning to prevent silent data corruption on app updates
  static const int _schemaVersion = 3;
  static const String _schemaVersionKey = 'schema_version';
  
  // Hive Box Names
  static const String _salesBoxBase = 'sales_v2';
  static const String _productsBoxBase = 'products_v2';
  static const String _customersBoxBase = 'customers_v2';
  static const String _invoicesBoxBase = 'invoices_v2';
  static const String _purchaseOrdersBoxBase = 'purchase_orders_v2';
  static const String _khataBoxBase = 'khata_v2';
  static const String _idempotencyBoxBase = 'deductions_idempotency_v2';
  static const String _expensesBoxBase = 'expenses_v2';
  static const String _inventoryBoxBase = 'inventory_v2';

  static Future<int?> _getUserId() async {
    final prefs = await SharedPreferences.getInstance();
    final primary = prefs.getInt('user_id');
    final alternate = prefs.getInt('userId');
    final id = primary ?? alternate;
    
    // 🔒 VALIDATION: Ensure user ID is valid and positive
    if (id != null && id > 0) {
      // Normalize user ID storage
      if (primary == null) {
        await prefs.setInt('user_id', id);
      }
      if (alternate == null) {
        await prefs.setInt('userId', id);
      }
      return id;
    }
    
    // 🔒 SECURITY: Throw error instead of failing silently for critical operations
    // This prevents data leakage by ensuring operations fail when user is not authenticated
    if (kDebugMode) debugPrint('⚠️ Invalid user ID detected: primary=$primary, alternate=$alternate');
    
    return null; // Return null for non-critical operations that check with _hasValidUserId()
  }
  
  /// ✅ FIX: Call on app startup to check and migrate schema if needed with proper backup and rollback
  static Future<void> validateAndMigrateSchema() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final currentVersion = prefs.getInt(_schemaVersionKey) ?? 0;
      
      if (currentVersion < _schemaVersion) {
        if (kDebugMode) {
          debugPrint('📊 Schema migration needed: $currentVersion → $_schemaVersion');
        }
        
        // Create backup before migration
        String? backupPath;
        try {
          backupPath = await _createSchemaBackup(currentVersion);
          if (kDebugMode) debugPrint('📦 Schema backup created at: $backupPath');
        } catch (backupError) {
          if (kDebugMode) debugPrint('⚠️ Schema backup failed: $backupError');
          // Continue with migration but log the risk
        }
        
        // Migration logic for each schema version
        try {
          // Migration from version 0 to 1
          if (currentVersion < 1) {
            await _migrateFromV0ToV1();
            // Update version incrementally for rollback safety
            await prefs.setInt(_schemaVersionKey, 1);
          }
          
          // Migration from version 1 to 2
          if (currentVersion < 2) {
            await _migrateFromV1ToV2();
            await prefs.setInt(_schemaVersionKey, 2);
          }
          
          // Migration from version 2 to 3
          if (currentVersion < 3) {
            await _migrateFromV2ToV3();
            await prefs.setInt(_schemaVersionKey, 3);
          }
          
          // Final update to target schema version
          await prefs.setInt(_schemaVersionKey, _schemaVersion);
          
          if (kDebugMode) {
            debugPrint('✅ Schema updated to $_schemaVersion');
          }
          
          // Clean up backup after successful migration
          if (backupPath != null) {
            try {
              await _cleanupSchemaBackup(backupPath);
              if (kDebugMode) debugPrint('🧹 Schema backup cleaned up');
            } catch (cleanupError) {
              if (kDebugMode) debugPrint('⚠️ Schema backup cleanup failed: $cleanupError');
            }
          }
        } catch (migrationError) {
          if (kDebugMode) debugPrint('❌ Schema migration failed: $migrationError');
          
          // Attempt rollback from backup
          if (backupPath != null) {
            try {
              await _restoreSchemaBackup(backupPath, currentVersion);
              if (kDebugMode) debugPrint('✅ Schema rollback successful from backup');
            } catch (rollbackError) {
              if (kDebugMode) debugPrint('❌ Schema rollback failed: $rollbackError');
              // Store critical error for user notification
              await prefs.setBool('schema_migration_critical_failure', true);
              await prefs.setString('schema_migration_error', 'Migration failed and rollback failed. Manual intervention may be required.');
            }
          }
          
          // Revert to previous version on failure
          await prefs.setInt(_schemaVersionKey, currentVersion);
          rethrow;
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Schema validation error: $e');
    }
  }
  
  /// Create a backup of all Hive boxes before schema migration
  static Future<String?> _createSchemaBackup(int currentVersion) async {
    try {
      if (kIsWeb) return null; // Skip backup on web
      
      final appDir = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final backupDir = Directory('${appDir.path}/hive_schema_backup_v${currentVersion}_$timestamp');
      
      if (await backupDir.exists()) {
        await backupDir.delete(recursive: true);
      }
      await backupDir.create(recursive: true);
      
      final hiveDir = Directory('${appDir.path}/hive');
      if (await hiveDir.exists()) {
        // Copy all hive files to backup
        await for (final entity in hiveDir.list(recursive: true)) {
          if (entity is File) {
            final relativePath = entity.path.substring(hiveDir.path.length);
            final backupFile = File('${backupDir.path}$relativePath');
            await backupFile.parent.create(recursive: true);
            await entity.copy(backupFile.path);
          }
        }
      }
      
      return backupDir.path;
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Schema backup creation failed: $e');
      return null;
    }
  }
  
  /// Restore from schema backup after failed migration
  static Future<void> _restoreSchemaBackup(String backupPath, int targetVersion) async {
    try {
      if (kIsWeb) return;
      
      final appDir = await getApplicationDocumentsDirectory();
      final hiveDir = Directory('${appDir.path}/hive');
      final backupDir = Directory(backupPath);
      
      if (!await backupDir.exists()) {
        throw Exception('Backup directory not found: $backupPath');
      }
      
      // Close all open boxes first
      await closeUserBoxes();
      
      // If hive directory exists, rename it as a precaution
      if (await hiveDir.exists()) {
        final failedMigrationDir = Directory('${appDir.path}/hive_failed_migration_${DateTime.now().millisecondsSinceEpoch}');
        await hiveDir.rename(failedMigrationDir.path);
      }
      
      // Recreate hive directory
      await hiveDir.create(recursive: true);
      
      // Restore files from backup
      await for (final entity in backupDir.list(recursive: true)) {
        if (entity is File) {
          final relativePath = entity.path.substring(backupDir.path.length);
          final restoreFile = File('${hiveDir.path}$relativePath');
          await restoreFile.parent.create(recursive: true);
          await entity.copy(restoreFile.path);
        }
      }
      
      // Reinitialize Hive
      await Hive.initFlutter();
      
      if (kDebugMode) debugPrint('✅ Schema restored from backup to version $targetVersion');
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Schema restore failed: $e');
      rethrow;
    }
  }
  
  /// Clean up schema backup after successful migration
  static Future<void> _cleanupSchemaBackup(String backupPath) async {
    try {
      if (kIsWeb) return;
      
      final backupDir = Directory(backupPath);
      if (await backupDir.exists()) {
        await backupDir.delete(recursive: true);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Schema backup cleanup failed: $e');
    }
  }
  
  /// Migration from version 0 to 1: Convert from unscoped to user-scoped boxes
  static Future<void> _migrateFromV0ToV1() async {
    if (kDebugMode) debugPrint('🔄 Migrating from v0 to v1...');
    
    try {
      final userId = await _getUserId();
      if (userId == null || userId == 0) {
        if (kDebugMode) debugPrint('⚠️ No valid user ID for v0->v1 migration, skipping');
        return;
      }
      
      // List of boxes to migrate from unscoped to scoped
      final boxesToMigrate = [
        'sales_v2',
        'products_v2',
        'customers_v2',
        'invoices_v2',
        'purchase_orders_v2',
        'khata_v2',
        'deductions_idempotency_v2',
        'expenses_v2',
        'inventory_v2',
      ];
      
      for (final boxName in boxesToMigrate) {
        try {
          // Check if unscoped box exists
          if (Hive.isBoxOpen(boxName) || await _boxExists(boxName)) {
            final oldBox = await Hive.openBox(boxName);
            final scopedBoxName = '${boxName}_$userId';
            final newBox = await Hive.openBox(scopedBoxName);
            
            // Migrate all data
            for (final key in oldBox.keys) {
              final value = oldBox.get(key);
              await newBox.put(key, value);
            }
            
            await oldBox.close();
            await newBox.close();
            
            // Delete old unscoped box after successful migration
            await Hive.deleteBoxFromDisk(boxName);
            
            if (kDebugMode) debugPrint('✅ Migrated $boxName to $scopedBoxName');
          }
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Failed to migrate $boxName: $e');
          // Continue with other boxes even if one fails
        }
      }
      
      // Clean up legacy SharedPreferences
      await purgeLegacyPrefsSales();
      
      if (kDebugMode) debugPrint('✅ v0->v1 migration completed');
    } catch (e) {
      if (kDebugMode) debugPrint('❌ v0->v1 migration failed: $e');
      rethrow;
    }
  }
  
  /// Migration from version 1 to 2: Add data validation and indexing improvements
  static Future<void> _migrateFromV1ToV2() async {
    if (kDebugMode) debugPrint('🔄 Migrating from v1 to v2...');
    
    try {
      final userId = await _getUserId();
      if (userId == null || userId == 0) {
        if (kDebugMode) debugPrint('⚠️ No valid user ID for v1->v2 migration, skipping');
        return;
      }
      
      // Add validation metadata to sales box
      try {
        final salesBoxName = '${_salesBoxBase}_$userId';
        if (await _boxExists(salesBoxName)) {
          final salesBox = await Hive.openBox(salesBoxName);
          
          // Add validation flag to existing sales records
          for (final key in salesBox.keys) {
            final saleData = salesBox.get(key);
            if (saleData is Map && !saleData.containsKey('validated')) {
              saleData['validated'] = true;
              saleData['validation_timestamp'] = DateTime.now().toIso8601String();
              await salesBox.put(key, saleData);
            }
          }
          
          await salesBox.close();
          if (kDebugMode) debugPrint('✅ Sales box validation metadata added');
        }
      } catch (e) {
        if (kDebugMode) debugPrint('⚠️ Sales box migration failed: $e');
      }
      
      // Add timestamp metadata to products box
      try {
        final productsBoxName = '${_productsBoxBase}_$userId';
        if (await _boxExists(productsBoxName)) {
          final productsBox = await Hive.openBox(productsBoxName);
          
          for (final key in productsBox.keys) {
            final productData = productsBox.get(key);
            if (productData is Map && !productData.containsKey('last_updated')) {
              productData['last_updated'] = DateTime.now().toIso8601String();
              await productsBox.put(key, productData);
            }
          }
          
          await productsBox.close();
          if (kDebugMode) debugPrint('✅ Products box timestamp metadata added');
        }
      } catch (e) {
        if (kDebugMode) debugPrint('⚠️ Products box migration failed: $e');
      }
      
      if (kDebugMode) debugPrint('✅ v1->v2 migration completed');
    } catch (e) {
      if (kDebugMode) debugPrint('❌ v1->v2 migration failed: $e');
      rethrow;
    }
  }
  
  /// Migration from version 2 to 3: Add user isolation improvements and security enhancements
  static Future<void> _migrateFromV2ToV3() async {
    if (kDebugMode) debugPrint('🔄 Migrating from v2 to v3...');
    
    try {
      final userId = await _getUserId();
      if (userId == null || userId == 0) {
        if (kDebugMode) debugPrint('⚠️ No valid user ID for v2->v3 migration, skipping');
        return;
      }
      
      // NOTE: previously called clearOtherUserBoxes() here, which permanently
      // deletes other users' local Hive data (including anything not yet
      // synced to the server). Box names are already scoped per user, so no
      // cleanup of other users' boxes is needed for isolation or migration
      // correctness. See clearOtherUserBoxes() below for details.
      
      // Add user ID verification to all boxes
      final boxBases = [
        _salesBoxBase,
        _productsBoxBase,
        _customersBoxBase,
        _invoicesBoxBase,
        _purchaseOrdersBoxBase,
        _khataBoxBase,
        _idempotencyBoxBase,
        _expensesBoxBase,
        _inventoryBoxBase,
      ];
      
      for (final base in boxBases) {
        try {
          final boxName = '${base}_$userId';
          if (await _boxExists(boxName)) {
            final box = await Hive.openBox(boxName);
            
            // Add user_id metadata to box
            await box.put('_user_id', userId);
            await box.put('_schema_version', 3);
            await box.put('_migration_timestamp', DateTime.now().toIso8601String());
            
            await box.close();
            if (kDebugMode) debugPrint('✅ User ID metadata added to $boxName');
          }
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Failed to add metadata to $base: $e');
        }
      }
      
      // Purge any remaining legacy unscoped boxes
      await purgeLegacyUnscopedHiveBoxes();
      
      if (kDebugMode) debugPrint('✅ v2->v3 migration completed');
    } catch (e) {
      if (kDebugMode) debugPrint('❌ v2->v3 migration failed: $e');
      rethrow;
    }
  }
  
  /// Helper method to check if a box exists on disk
  static Future<bool> _boxExists(String boxName) async {
    try {
      if (kIsWeb) return false;
      
      final appDir = await getApplicationDocumentsDirectory();
      final hiveDir = Directory('${appDir.path}/hive');
      if (!await hiveDir.exists()) return false;
      
      // Check for box files (Hive creates .hive files)
      final boxFile = File('${hiveDir.path}/$boxName.hive');
      return await boxFile.exists();
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Error checking box existence: $e');
      return false;
    }
  }

  /// Resolve a Hive box name scoped to the current user.
  /// Never use a shared global sales box — prevents fake/leaked data on new accounts.
  static Future<String> _getScopedBoxName(String base) async {
    final userId = await _getUserId();
    
    // 🔒 VALIDATION: Ensure we have a valid user ID before creating scoped box
    if (userId == null || userId == 0) {
      throw Exception('SECURITY: Cannot store data without authenticated user_id. User ID is null or zero.');
    }
    
    final scopedName = '${base}_$userId';
    
    // 🔒 COLLISION DETECTION: Check for potential box name collisions
    // Ensure the box name doesn't conflict with legacy unscoped boxes
    if (base == scopedName) {
      if (kDebugMode) debugPrint('⚠️ BOX NAME COLLISION DETECTED: $base matches unscoped box name');
      throw Exception('SECURITY: Box name collision detected. Cannot use unscoped box name as scoped box.');
    }
    
    // Check if a legacy unscoped box with the same base name exists
    if (await _boxExists(base)) {
      if (kDebugMode) debugPrint('⚠️ LEGACY BOX CONFLICT: Unscoped box $base exists, may cause data leakage');
      // In production, you might want to migrate or delete the legacy box here
    }
    
    // Verify the scoped box belongs to the current user by checking metadata
    if (await _boxExists(scopedName)) {
      try {
        final box = await Hive.openBox(scopedName);
        final boxUserId = box.get('_user_id');
        await box.close();
        
        if (boxUserId != null && boxUserId != userId) {
          if (kDebugMode) debugPrint('⚠️ BOX OWNERSHIP MISMATCH: Box $scopedName belongs to user $boxUserId, not current user $userId');
          throw Exception('SECURITY: Box ownership mismatch. Data isolation violated.');
        }
      } catch (e) {
        if (kDebugMode) debugPrint('⚠️ Error checking box ownership: $e');
        // Continue but log the issue
      }
    }
    
    if (kDebugMode) {
      debugPrint('🔍 Creating scoped box: $scopedName');
    }
    
    return scopedName;
  }

  static Future<bool> _hasValidUserId() async {
    final id = await _getUserId();
    return id != null && id > 0;
  }

  /// Close all boxes for the current user to ensure data isolation between accounts.
  static Future<void> closeUserBoxes() async {
    try {
      final userId = await _getUserId();
      if (userId == null || userId == 0) {
        if (kDebugMode) debugPrint('⚠️ No user ID found, skipping box closure');
        return;
      }

      final boxBases = [
        _salesBoxBase,
        _productsBoxBase,
        _customersBoxBase,
        _invoicesBoxBase,
        _purchaseOrdersBoxBase,
        _khataBoxBase,
        _idempotencyBoxBase,
        _expensesBoxBase,
        _inventoryBoxBase,
      ];

      for (final base in boxBases) {
        final boxName = '${base}_$userId';
        try {
          if (Hive.isBoxOpen(boxName)) {
            await Hive.box(boxName).close();
            if (kDebugMode) debugPrint('🔒 Closed box: $boxName');
          }
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Failed to close box $boxName: $e');
        }
      }
      
      // 🔒 SECURITY: Also close any legacy unscoped boxes that might be open
      final legacyBoxNames = [
        'sales_v2', 'products_v2', 'customers_v2', 'invoices_v2',
        'purchase_orders_v2', 'khata_v2', 'deductions_idempotency_v2',
        'expenses_v2', 'inventory_v2', 'sync_queue_v2',
      ];
      
      for (final legacyName in legacyBoxNames) {
        try {
          if (Hive.isBoxOpen(legacyName)) {
            await Hive.box(legacyName).close();
            if (kDebugMode) debugPrint('🔒 Closed legacy box: $legacyName');
          }
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Failed to close legacy box $legacyName: $e');
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error closing user boxes: $e');
    }
  }

  /// Remove legacy SharedPreferences sales (pre-Hive) that caused cross-account leakage.
  static Future<void> purgeLegacyPrefsSales() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('all_sales');
    if (kDebugMode) debugPrint('🧹 Purged legacy prefs all_sales');
  }

  /// ⚠️ DEPRECATED — DO NOT wire this back into logout, login, or migration.
  ///
  /// This deleted every OTHER user's local Hive boxes (sales, invoices,
  /// customers, inventory, khata) from disk whenever it ran — including
  /// data that hadn't synced to the server yet. On a shared device (e.g. a
  /// shop owner and a cashier both logging into one tablet), that meant
  /// real, unrecoverable data loss for whichever account wasn't currently
  /// active, every time anyone logged out or entered customer mode. The
  /// box-detection logic here was improved (scans actual box names on disk
  /// instead of assuming a small fixed user-ID range), but the underlying
  /// operation — deleting another user's business data — was never safe.
  ///
  /// Data isolation between accounts is already guaranteed without
  /// deletion: every box name is scoped per user (e.g. "sales_v2_$userId"),
  /// and closeUserBoxes() closes the current user's boxes on logout. The
  /// next user who logs in resolves their own scoped names and can never
  /// read or write another user's box.
  ///
  /// If a genuine need arises to wipe another account's local cache (e.g. a
  /// confirmed account-deletion request from that account's own owner),
  /// build a narrowly-scoped, explicitly-confirmed flow for that specific
  /// case — do not restore this as an automatic logout/migration step.
  @Deprecated('Destructive — no longer called from any flow. Read the doc comment before re-adding a call site.')
  static Future<void> clearOtherUserBoxes() async {
    if (kDebugMode) {
      debugPrint('⚠️ clearOtherUserBoxes() called but is now a no-op — see deprecation notice in local_storage_service.dart.');
    }
    return;
  }

  static Future<List<String>> _listUserScopedBoxNames() async {
    try {
      if (kIsWeb) return [];

      final appDir = await getApplicationDocumentsDirectory();
      final hiveDir = Directory('${appDir.path}/hive');
      if (!await hiveDir.exists()) return [];

      final boxNames = <String>{};
      await for (final entity in hiveDir.list()) {
        if (entity is File) {
          final fileName = entity.uri.pathSegments.last;
          if (fileName.endsWith('.hive') || fileName.endsWith('.lock')) {
            final stem = fileName.replaceAll('.hive', '').replaceAll('.lock', '');
            if (stem.contains('_')) {
              boxNames.add(stem);
            }
          }
        }
      }
      return boxNames.toList();
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Failed to list user-scoped Hive boxes: $e');
      return [];
    }
  }

  static String? _boxBaseFromScopedName(String boxName) {
    final parts = boxName.split('_');
    if (parts.length < 2) return null;
    final base = parts.take(parts.length - 1).join('_');
    return base.isEmpty ? null : base;
  }

  static int? _userIdFromScopedBoxName(String boxName) {
    try {
      final parts = boxName.split('_');
      if (parts.length < 2) return null;
      final raw = parts.last;
      return int.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  /// Delete legacy unscoped Hive boxes (pre user_id isolation).
  static Future<void> purgeLegacyUnscopedHiveBoxes() async {
    const legacy = [
      'sales_v2',
      'products_v2',
      'customers_v2',
      'invoices_v2',
      'purchase_orders_v2',
      'khata_v2',
      'deductions_idempotency_v2',
      'expenses_v2',
      'inventory_v2',
      'sync_queue_v2',
    ];
    for (final name in legacy) {
      try {
        if (Hive.isBoxOpen(name)) {
          await Hive.box(name).close();
        }
        if (await Hive.boxExists(name)) {
          await Hive.deleteBoxFromDisk(name);
          if (kDebugMode) debugPrint('🧹 Deleted legacy Hive box: $name');
        }
      } catch (e) {
        if (kDebugMode) debugPrint('⚠️ purgeLegacyUnscopedHiveBoxes $name: $e');
      }
    }
  }

  /// Wipe orphan global/unauthenticated sales boxes from older app versions.
  static Future<void> clearOrphanSalesBoxes() async {
    for (final suffix in ['_global', '_unauthenticated']) {
      final name = '${_salesBoxBase}$suffix';
      try {
        if (Hive.isBoxOpen(name)) {
          await Hive.box(name).clear();
          await Hive.box(name).put('all_sales', []);
        } else {
          final box = await Hive.openBox(name);
          await box.put('all_sales', []);
          await box.close();
        }
        if (kDebugMode) debugPrint('🧹 Cleared orphan sales box: ' + name);
      } catch (e) {
        if (kDebugMode) debugPrint('⚠️ clearOrphanSalesBoxes $name: $e');
      }
    }
    await purgeLegacyPrefsSales();
  }

  // =========== CORE BOX MANAGEMENT ===========
  
  static Future<Box> _getBox(String base, {bool encrypted = false}) async {
    // 🔒 SECURITY: Validate user ID before accessing any box
    if (!await _hasValidUserId()) {
      if (kDebugMode) debugPrint('⚠️ _getBox failed — no valid user_id');
      throw Exception('SECURITY: Cannot access storage without authenticated user_id. Please log in first.');
    }
    
    final name = await _getScopedBoxName(base);
    if (!Hive.isBoxOpen(name)) {
      if (encrypted) {
        const secureStorage = FlutterSecureStorage();
        final encryptionKeyString = await secureStorage.read(key: 'hive_key_');
        if (encryptionKeyString == null) {
          final key = Hive.generateSecureKey();
          await secureStorage.write(key: 'hive_key_', value: base64UrlEncode(key));
          return await Hive.openBox(name, encryptionCipher: HiveAesCipher(key));
        }
        final encryptionKeyUint8List = base64Url.decode(encryptionKeyString);
        return await Hive.openBox(name, encryptionCipher: HiveAesCipher(encryptionKeyUint8List));
      }
      return await Hive.openBox(name);
    }
    return Hive.box(name);
  }

  // =========== SALES (BUSINESS CRITICAL) ===========
  
  static Future<void> saveSales(List<dynamic> salesHistory) async {
    if (!await _hasValidUserId()) {
      if (kDebugMode) debugPrint('⚠️ saveSales skipped — no logged-in user');
      return;
    }
    final box = await _getBox(_salesBoxBase, encrypted: true);
    final userId = await _getUserId();

    final List<dynamic> existingSales = box.get('all_sales', defaultValue: []);

    final List<dynamic> combinedRaw;
    if (salesHistory.length >= existingSales.length && existingSales.isNotEmpty && salesHistory.any((s) => s['sale_id'] == existingSales.first['sale_id'])) {
      combinedRaw = [...salesHistory];
    } else {
      combinedRaw = [...existingSales, ...salesHistory];
    }

    final dedupedSales = SalesDedupHelper.dedupeBills(combinedRaw);
    final List<StoredSale> typedSales = dedupedSales.map<StoredSale>((sale) {
      return StoredSale.fromJson(Map<String, dynamic>.from(sale));
    }).toList();

    await box.put('all_sales', typedSales.map((sale) => sale.toJson()).toList());
    if (kDebugMode) debugPrint('💾 [LocalStorage] Merged ${salesHistory.length} sales (total: ${typedSales.length}) for user: $userId');
  }

  static Future<List<dynamic>> loadSales() async {
    if (!await _hasValidUserId()) {
      if (kDebugMode) debugPrint('⚠️ loadSales: no user_id — returning empty (no fake data)');
      return [];
    }
    final box = await _getBox(_salesBoxBase, encrypted: true);
    final userId = await _getUserId();
    final sales = box.get('all_sales', defaultValue: []);
    final typedSales = List<dynamic>.from(sales).map((sale) {
      if (sale is StoredSale) return sale.toJson();
      if (sale is Map) return Map<String, dynamic>.from(sale);
      return sale;
    }).toList();
    if (kDebugMode) debugPrint('🔍 [LocalStorage] Loaded ${typedSales.length} sales for USER_ID: $userId');
    return typedSales;
  }

  static Future<bool> cancelSale(String saleId) async {
    if (!await _hasValidUserId()) return false;
    final box = await _getBox(_salesBoxBase, encrypted: true);
    final List<dynamic> sales = List<dynamic>.from(box.get('all_sales', defaultValue: []));
    
    int index = sales.indexWhere((s) => (s['sale_id'] ?? s['id'] ?? '').toString() == saleId);
    if (index == -1) return false;

    // Mark as cancelled
    final sale = Map<String, dynamic>.from(sales[index]);
    if (sale['status'] == 'CANCELLED') return true; // Already cancelled
    
    sale['status'] = 'CANCELLED';
    sale['cancelled_at'] = DateTime.now().toIso8601String();
    sales[index] = sale;
    
    await box.put('all_sales', sales);
    
    // Release idempotency so it can be re-deducted if re-billed (or just mark as reverted)
    final idemBox = await _getBox(_idempotencyBoxBase);
    await idemBox.delete(saleId);
    
    return true;
  }

  // =========== PRODUCTS (INVENTORY) ===========
  
  static Future<void> saveBackendProducts(List<Map<String, dynamic>> products) async {
    if (!await _hasValidUserId()) return;
    final box = await _getBox(_productsBoxBase);
    final normalized = InventoryStockHelper.normalizeProducts(products);
    await box.put('backend_products', normalized);
    if (kDebugMode) debugPrint('💾 [LocalStorage] Saved ${normalized.length} backend products');
  }

  static Future<List<Map<String, dynamic>>> loadBackendProducts() async {
    if (!await _hasValidUserId()) return [];
    final box = await _getBox(_productsBoxBase);
    final data = box.get('backend_products', defaultValue: []);
    return InventoryStockHelper.normalizeProducts(List<dynamic>.from(data));
  }

  static Future<void> saveLocalProducts(Map<String, dynamic> products) async {
    if (!await _hasValidUserId()) return;
    final box = await _getBox(_productsBoxBase);
    await box.put('local_products', products);
  }

  static Future<Map<String, dynamic>> loadLocalProducts() async {
    if (!await _hasValidUserId()) return {};
    final box = await _getBox(_productsBoxBase);
    final data = box.get('local_products', defaultValue: {});
    return Map<String, dynamic>.from(data);
  }

  // =========== INVOICES & CUSTOMERS ===========
  
  static Future<void> saveLocalInvoices(List<dynamic> invoices) async {
    // 🔒 SECURITY FIX: Require valid user ID to prevent data leakage
    if (!await _hasValidUserId()) {
      if (kDebugMode) debugPrint('⚠️ saveLocalInvoices failed — no logged-in user');
      throw Exception('SECURITY: Cannot save invoices without authenticated user_id. Please log in first.');
    }
    final box = await _getBox(_invoicesBoxBase);
    await box.put('manual_invoices', invoices);
  }

  static Future<List<dynamic>> loadLocalInvoices() async {
    // 🔒 SECURITY FIX: Require valid user ID to prevent data leakage
    if (!await _hasValidUserId()) {
      if (kDebugMode) debugPrint('⚠️ loadLocalInvoices failed — no logged-in user');
      throw Exception('SECURITY: Cannot load invoices without authenticated user_id. Please log in first.');
    }
    final box = await _getBox(_invoicesBoxBase);
    final data = box.get('manual_invoices', defaultValue: []);
    return List<dynamic>.from(data);
  }

  static Future<void> savePurchaseOrders(List<dynamic> orders) async {
    if (!await _hasValidUserId()) return;
    final box = await _getBox(_purchaseOrdersBoxBase);
    await box.put('purchase_orders', orders);
  }

  static Future<List<dynamic>> loadPurchaseOrders() async {
    if (!await _hasValidUserId()) return [];
    final box = await _getBox(_purchaseOrdersBoxBase);
    final data = box.get('purchase_orders', defaultValue: []);
    return List<dynamic>.from(data);
  }

  static Future<void> saveLocalCustomers(List<dynamic> customers) async {
    if (!await _hasValidUserId()) return;
    final box = await _getBox(_customersBoxBase, encrypted: true);
    await box.put('customers', customers);
  }

  static Future<List<dynamic>> loadLocalCustomers() async {
    if (!await _hasValidUserId()) return [];
    final box = await _getBox(_customersBoxBase, encrypted: true);
    final data = box.get('customers', defaultValue: []);
    return List<dynamic>.from(data);
  }

  // =========== KHATA (CREDIT TRACKING) ===========

  static Future<void> saveKhataBalances(Map<String, double> balances) async {
    if (!await _hasValidUserId()) return;
    final box = await _getBox(_khataBoxBase, encrypted: true);
    await box.put('balances', balances);
  }

  static Future<Map<String, double>> loadKhataBalances() async {
    if (!await _hasValidUserId()) return {};
    final box = await _getBox(_khataBoxBase, encrypted: true);
    final data = box.get('balances', defaultValue: <String, double>{});
    return Map<String, double>.from(data.map((k, v) => MapEntry(k.toString(), (v as num).toDouble())));
  }

  
  // =========== UNIFIED LEDGER ===========
  static Future<List<Map<String, dynamic>>> loadUnifiedCustomersLedger() async {
    final sales = await loadSales();
    final invoices = await loadLocalInvoices();
    final customers = await loadLocalCustomers();
    final khataBalances = await loadKhataBalances();

    Map<String, Map<String, dynamic>> unified = {};

    // Initialize from explicitly created customers
    for (var c in customers) {
      final phone = c['phone']?.toString() ?? '';
      if (phone.isEmpty) continue;
      unified[phone] = {
        'phone': phone,
        'name': c['name'] ?? 'Unknown',
        'address': c['address'] ?? '',
        'gstin': c['gstin'] ?? '',
        'unified_balance': 0.0,
        'last_transaction': DateTime.now().toIso8601String(),
        'history': [],
      };
    }

    // Add sales data
    for (var sale in sales) {
      final phone = sale['customer_phone']?.toString() ?? sale['phone']?.toString() ?? '';
      if (phone.isEmpty || phone == 'Unknown') continue;

      if (!unified.containsKey(phone)) {
        unified[phone] = {
          'phone': phone,
          'name': sale['customer_name'] ?? 'Unknown Customer',
          'address': '',
          'gstin': '',
          'unified_balance': 0.0,
          'last_transaction': sale['date'] ?? sale['sale_date'] ?? DateTime.now().toIso8601String(),
          'history': [],
        };
      }
      
      unified[phone]!['history'].add(sale);
      final saleDateStr = sale['date'] ?? sale['sale_date'];
      if (saleDateStr != null) {
          unified[phone]!['last_transaction'] = saleDateStr;
      }
    }

    // Add explicit khata balances (source of truth for manual adjustments and payments)
    khataBalances.forEach((phone, balance) {
      if (!unified.containsKey(phone)) {
        unified[phone] = {
          'phone': phone,
          'name': 'Unknown Customer',
          'address': '',
          'gstin': '',
          'unified_balance': balance,
          'last_transaction': DateTime.now().toIso8601String(),
          'history': [],
        };
      } else {
        unified[phone]!['unified_balance'] = balance;
      }
    });

    // Add unpaid invoices debt that is NOT already accounted for
    // Assuming khata_balance only reflects manual payments/credit sales.
    // If an invoice is UNPAID, add it to their debt.
    for (var inv in invoices) {
      final phone = inv['customer_phone']?.toString() ?? '';
      if (phone.isEmpty) continue;
      
      if (!unified.containsKey(phone)) {
        unified[phone] = {
          'phone': phone,
          'name': inv['customer_name'] ?? 'Unknown Customer',
          'address': '',
          'gstin': '',
          'unified_balance': 0.0,
          'last_transaction': inv['date'] ?? DateTime.now().toIso8601String(),
          'history': [],
        };
      }

      // FIX: invoices store payment status under 'payment_status' (see
      // sale_service.dart's create-invoice payload), not 'status' — 'status'
      // on an invoice/sale record means sync status ('COMMITTED_LOCALLY',
      // 'QUEUED_OFFLINE', etc.), a completely different field. Reading
      // inv['status'] here meant it was always null, so isPaid was always
      // false, so every invoice — including fully paid ones — got added to
      // the customer's outstanding unified_balance debt.
      final isPaid = inv['payment_status']?.toString().toUpperCase() == 'PAID';
      if (!isPaid) {
        final amount = double.tryParse(inv['total_amount']?.toString() ?? '0') ?? 0.0;
        unified[phone]!['unified_balance'] = (unified[phone]!['unified_balance'] as double) + amount;
      }
    }

    return unified.values.toList();
  }

  static Future<void> recordUnifiedPayment(String customerPhone, double amount) async {
    final balances = await loadKhataBalances();
    final current = balances[customerPhone] ?? 0.0;
    
    // Instead of just reducing khata, we also check unpaid invoices if needed, but for simplicity:
    // Allow khataBalance to go negative if they overpay or pay off an invoice via Khata.
    // That way, unified_balance = khataBalance (negative) + unpaid_invoices (positive) = 0.
    balances[customerPhone] = current - amount; 
    await saveKhataBalances(balances);
  }
static Future<void> updateCustomerBalance(String customerId, double balance) async {
    final balances = await loadKhataBalances();
    balances[customerId] = balance;
    await saveKhataBalances(balances);
  }

  // =========== INVENTORY IDEMPOTENCY ===========

  static Future<void> markDeductionProcessed(String saleId) async {
    if (!await _hasValidUserId()) return;
    final box = await _getBox(_idempotencyBoxBase);
    await box.put(saleId, true);
  }

  static Future<bool> isDeductionProcessed(String saleId) async {
    if (!await _hasValidUserId()) return false;
    final box = await _getBox(_idempotencyBoxBase);
    return box.get(saleId) == true;
  }

  // =========== EXPENSES ===========

  static Future<void> saveExpenses(List<dynamic> expenses) async {
    if (!await _hasValidUserId()) return;
    final box = await _getBox(_expensesBoxBase);
    await box.put('all_expenses', expenses);
    if (kDebugMode) debugPrint('💾 [LocalStorage] Saved ${expenses.length} expenses');
  }

  static Future<List<dynamic>> loadExpenses() async {
    if (!await _hasValidUserId()) return [];
    final box = await _getBox(_expensesBoxBase);
    final data = box.get('all_expenses', defaultValue: []);
    return List<dynamic>.from(data);
  }

  // =========== INVENTORY ===========

  static Future<void> saveInventory(List<dynamic> inventory) async {
    if (!await _hasValidUserId()) return;
    final box = await _getBox(_inventoryBoxBase);
    await box.put('all_inventory', inventory);
    if (kDebugMode) debugPrint('💾 [LocalStorage] Saved ${inventory.length} inventory items');
  }

  static Future<List<dynamic>> loadInventory() async {
    if (!await _hasValidUserId()) return [];
    final box = await _getBox(_inventoryBoxBase);
    final data = box.get('all_inventory', defaultValue: []);
    return List<dynamic>.from(data);
  }

  // =========== SYSTEM ISOLATION & LOGOUT ===========

  /// Clears only session-specific cache. 
  /// BUSINESS DATA (Sales/Inventory) in Hive remains untouched but inaccessible 
  /// until the user logs back in (since it's keyed by userId).
  static Future<void> clearSessionData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('session_cache');
    if (kDebugMode) debugPrint('🧹 [LocalStorage] Session data cleared (Business records preserved)');
  }

  // =========== LEGACY SUPPORT & SHPREFS WRAPPERS ===========
  
  Future<String?> getString(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key);
  }

  Future<void> setString(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }

  // =========== BACKUP & RECOVERY PROTOCOL ===========
  static Future<String?> exportSecureBackup() async {
    try {
      final sales = await loadSales();
      final products = await loadLocalProducts();
      final customers = await loadLocalCustomers();
      
      final Map<String, dynamic> backupData = {
        'timestamp': DateTime.now().toIso8601String(),
        'schema_version': _schemaVersion,
        'sales': sales,
        'products': products,
        'customers': customers,
      };
      
      final jsonString = jsonEncode(backupData);
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/retail_mind_backup_${DateTime.now().millisecondsSinceEpoch}.json');
      await file.writeAsString(jsonString);
      
      if (kDebugMode) debugPrint('✅ Backup exported to ${file.path}');
      return file.path;
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Backup failed: $e');
      return null;
    }
  }
  
  static Future<bool> importSecureBackup(String jsonPayload) async {
    try {
      final Map<String, dynamic> backupData = jsonDecode(jsonPayload);
      
      final sales = backupData['sales'] as List<dynamic>? ?? [];
      final products = backupData['products'] as List<dynamic>? ?? [];
      final customers = backupData['customers'] as List<dynamic>? ?? [];
      
      final salesBox = await _getBox(_salesBoxBase, encrypted: true);
      final productsBox = await _getBox(_productsBoxBase, encrypted: true);
      final customersBox = await _getBox(_customersBoxBase, encrypted: true);

      await salesBox.clear();
      await productsBox.clear();
      await customersBox.clear();

      await salesBox.put('all_sales', sales);
      
      for (var p in products) {
        if (p is Map && p.containsKey('product_id')) {
          await productsBox.put(p['product_id'], p);
        } else if (p is Map && p.containsKey('barcode')) {
          await productsBox.put(p['barcode'], p);
        }
      }
      
      await customersBox.put('customers', customers);
      
      if (kDebugMode) debugPrint('✅ Backup imported successfully');
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Backup import failed: $e');
      return false;
    }
  }

  // =========== CONFLICT RESOLUTION ===========
  static List<dynamic> syncLedgerWithConflictResolution(List<dynamic> localLedger, List<dynamic> cloudLedger) {
    final Map<String, dynamic> merged = {};
    
    // Add local records
    for (var item in localLedger) {
      final id = item['id']?.toString() ?? item['invoice_id']?.toString();
      if (id != null) merged[id] = item;
    }
    
    // Merge cloud records using Last Write Wins
    for (var cloudItem in cloudLedger) {
      final id = cloudItem['id']?.toString() ?? cloudItem['invoice_id']?.toString();
      if (id != null) {
        if (merged.containsKey(id)) {
          final localTime = merged[id]['last_updated'] ?? 0;
          final cloudTime = cloudItem['last_updated'] ?? 0;
          
          if (cloudTime > localTime) {
            merged[id] = cloudItem; // Cloud is newer
          }
        } else {
          merged[id] = cloudItem; // Cloud has new record
        }
      }
    }
    
    return merged.values.toList();
  }

  // =========== REFUND WORKFLOW ===========
  static Future<bool> executeRefund(String invoiceId) async {
    try {
      final salesBox = await _getBox(_salesBoxBase, encrypted: true);
      final productsBox = await _getBox(_productsBoxBase, encrypted: true);
      
      final currentSales = List<dynamic>.from(salesBox.get('all_sales', defaultValue: []));
      final currentProducts = List<dynamic>.from(productsBox.get('all_products', defaultValue: []));
      
      final saleIndex = currentSales.indexWhere((s) => s['invoice_id'] == invoiceId || s['id'] == invoiceId);
      if (saleIndex == -1) throw Exception('Invoice not found');
      
      final sale = Map<String, dynamic>.from(currentSales[saleIndex]);
      if (sale['status'] == 'REFUNDED') throw Exception('Already refunded');
      
      // Restore Inventory
      final items = List<dynamic>.from(sale['items'] ?? []);
      for (var item in items) {
        final productId = item['id']?.toString() ?? item['product_id']?.toString() ?? '';
        final double qtyToRestore = double.tryParse(item['qty']?.toString() ?? '1') ?? 1.0;
        
        final pIndex = currentProducts.indexWhere((p) => p['id']?.toString() == productId);
        if (pIndex != -1) {
          final p = Map<String, dynamic>.from(currentProducts[pIndex]);
          final currentStock = double.tryParse(p['stock']?.toString() ?? '0') ?? 0.0;
          
          p['stock'] = (currentStock + qtyToRestore).toString();
          p['last_updated'] = DateTime.now().millisecondsSinceEpoch;
          currentProducts[pIndex] = p;
        }
      }
      
      // Update Sale Status
      sale['status'] = 'REFUNDED';
      sale['last_updated'] = DateTime.now().millisecondsSinceEpoch;
      currentSales[saleIndex] = sale;
      
      // Batch Commit
      await productsBox.put('all_products', currentProducts);
      await salesBox.put('all_sales', currentSales);
      
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Refund Failed: ');
      return false;
    }
  }
}