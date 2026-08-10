import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_state_reset.dart';
import 'account_data_sync_service.dart';
import 'customer_api_client.dart';
import 'google_auth_service.dart';
import 'local_storage_service.dart';
import 'online_orders_listener.dart';
import 'payment_detection_service.dart';
import 'payment_detection_system.dart';
import 'security_service.dart';
import 'sale_service.dart';
import 'secure_preferences_service.dart';
import 'secure_token_storage.dart';
import 'session_management.dart';
import 'sync_queue_manager.dart';
import 'sync_service.dart';
import 'user_data_clear_service.dart';
import 'scoped_shared_preferences.dart';

/// Single logout / session-isolation path for owner and customer flows.
/// NEVER delete sales, invoices, customers, products, inventory, or pending sync queue!
class SessionLogoutService {
  static bool _inProgress = false;

  static Future<void> _clearCore({bool notifyServer = true}) async {
    if (notifyServer) {
      try {
        await SessionManagementService.logout();
      } catch (e) {
        if (kDebugMode) debugPrint('⚠️ Server logout: $e');
      }
    }

    await OnlineOrdersListener.instance.stop();
    
    // 🔒 FIRST: Close all current user's Hive boxes to ensure data isolation.
    // Box names are already scoped per user (e.g. "sales_v2_$userId"), so
    // closing the current user's boxes is sufficient — the next user who
    // logs in resolves their own scoped box names and can never read this
    // user's data. DO NOT call clearOtherUserBoxes() here: it permanently
    // deletes other users' local Hive boxes from disk, including sales,
    // invoices, customers, and inventory that haven't synced to the server
    // yet. On a shared device (e.g. owner + cashier on one tablet), every
    // logout or "enter customer mode" was silently wiping the other
    // account's unsynced business data. Isolation does not require deletion.
    await LocalStorageService.closeUserBoxes();
    // Reset sync queue box reference to ensure new user gets their own queue
    await SyncQueueManager.resetBoxReference();
    
    // 🔒 SECURITY: Clear all scoped SharedPreferences data for current user
    await ScopedSharedPreferences.clearCurrentUserScopedData();
    await ScopedSharedPreferences.clearLegacyUnscopedKeys();
    
    // Use UserDataClearService which now preserves all business data in scoped boxes
    await UserDataClearService.clearAllUserData();
    await SecureTokenStorage.clearAll();
    await SecurePreferencesService.clearAllPaymentData();
    await SessionManagementService.clearTokens();
    // DO NOT clear sync queue! (it's user-scoped and will be reloaded for new user)
    // await SyncQueueManager.clearQueue();
    await AccountDataSyncService.clearAllCache();
    await GoogleAuthService.signOut();
    await SecurityService.clearMasterPinOnLogout();
    await PdsStateStore.clearAll();
    SaleService.clearInFlight();
    PaymentDetectionSystem.clearOnLogout();
    CustomerAPIClient.reset();
    AppStateReset.resetAll();
    // DO NOT clear sales boxes! (they're scoped per user)
    // await LocalStorageService.clearOrphanSalesBoxes();
    // await LocalStorageService.purgeLegacyUnscopedHiveBoxes();
  }

  /// Owner logout — use from every dashboard/settings logout button.
  static Future<void> performOwnerLogout({bool processQueueFirst = false}) async {
    if (_inProgress) {
      if (kDebugMode) debugPrint('⚠️ Logout already in progress');
      return;
    }
    _inProgress = true;
    try {
      if (processQueueFirst) {
        await SyncService.processQueueSafe();
      }
      await _clearCore(notifyServer: true);
    } finally {
      _inProgress = false;
    }
  }

  /// Account deletion / forced wipe (optional server notify).
  static Future<void> performFullLogout({bool notifyServer = true}) async {
    if (_inProgress) return;
    _inProgress = true;
    try {
      await _clearCore(notifyServer: notifyServer);
    } finally {
      _inProgress = false;
    }
  }

  /// Customer login: wipe owner tokens, Hive session prefs, and UPI/email leakage.
  static Future<void> enterCustomerMode({
    required String customerName,
    required String customerPhone,
  }) async {
    await _clearCore(notifyServer: false);

    final phoneDigits = customerPhone.replaceAll(RegExp(r'\D'), '');
    final email = phoneDigits.isNotEmpty
        ? '$phoneDigits@customer.local'
        : 'guest@customer.local';

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('role', 'customer');
    await prefs.setString('app_mode', 'customer');
    await prefs.setString('customer_name', customerName);
    await prefs.setString('customer_phone', customerPhone);
    await prefs.setString('customer_email', email);

    if (kDebugMode) debugPrint('✅ Customer mode — owner session cleared (business data preserved)');
  }

  /// Leaving customer flow back to owner login.
  static Future<void> exitCustomerMode() async {
    final prefs = await SharedPreferences.getInstance();
    const keys = [
      'role',
      'app_mode',
      'customer_name',
      'customer_phone',
      'customer_email',
      'last_online_order_id',
    ];
    for (final key in keys) {
      await prefs.remove(key);
    }
  }

  static Future<bool> isCustomerMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('role') == 'customer' ||
        prefs.getString('app_mode') == 'customer';
  }
}