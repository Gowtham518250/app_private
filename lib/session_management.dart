/// Session Management Service
/// 7-day auto-login with RefreshToken
/// Prevents data loss on logout/login
/// Syncs offline data when online
/// Auto-logout on session expiration

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synchronized/synchronized.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart' as flutter_secure_storage;
import 'package:cloud_firestore/cloud_firestore.dart' as cloud_firestore;
import 'api_client.dart';
import 'sync_queue_manager.dart';
import 'secure_token_storage.dart';
import 'error_log_helper.dart';
import 'user_data_clear_service.dart';
import 'scoped_shared_preferences.dart';
import 'secure_preferences_service.dart';

class SessionManagementService {
  static const String _refreshTokenKey = 'refresh_token';
  static const String _accessTokenKey = 'access_token';
  static const String _refreshTokenExpiryKey = 'refresh_token_expiry';
  static const String _deviceIdKey = 'device_id';
  static const String _userIdKey = 'user_id';
  static const String _userNameKey = 'user_name';
  static const String _userEmailKey = 'user_email';
  static const String _sessionTimeKey = 'session_time';
  static const String _identityVerifiedKeyPrefix = 'identity_verified_';
  static const String _identityVerifiedRoleKeyPrefix = 'identity_verified_role_';
  static const String _identityVerifiedAtKeyPrefix = 'identity_verified_at_';

  static final Lock _sessionLock = Lock();
  // Refresh has its own lock: autoLogin calls saveTokens, which takes
  // _sessionLock. Sharing the same lock here deadlocked every successful refresh.
  static final Lock _autoLoginLock = Lock();

  static Timer? _sessionExpiryTimer;
  static const Duration _sessionCheckInterval = Duration(hours: 1);
  static const Duration _maxSessionDuration = Duration(days: 7);
  // Refresh the rotating seven-day refresh token before it expires. Waiting
  // until _maxSessionDuration is crossed is too late for the backend's TTL.
  static const Duration _refreshBeforeExpiry = Duration(hours: 12);

  static void startSessionExpiryMonitoring() {
    _sessionExpiryTimer?.cancel();
    // Run once immediately: otherwise a user opening the app shortly before
    // the refresh token expires could wait an hour for the first timer tick.
    unawaited(_checkAndHandleSessionExpiry());
    _sessionExpiryTimer = Timer.periodic(_sessionCheckInterval, (_) async {
      await _checkAndHandleSessionExpiry();
    });
    if (kDebugMode) debugPrint('🔔 Session expiry monitoring started - hybrid mode (online enforcement, offline grace)');
  }

  static void stopSessionExpiryMonitoring() {
    _sessionExpiryTimer?.cancel();
    _sessionExpiryTimer = null;
    if (kDebugMode) debugPrint('🔔 Session expiry monitoring stopped');
  }

  static Future<void> _checkAndHandleSessionExpiry() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sessionTime = prefs.getInt(_sessionTimeKey);

      if (sessionTime == null) {
        if (kDebugMode) debugPrint('🔔 No session time found, skipping expiry check');
        return;
      }

      final sessionDateTime = DateTime.fromMillisecondsSinceEpoch(sessionTime);
      final now = DateTime.now();
      final sessionAge = now.difference(sessionDateTime);

      final refreshDueAt = _maxSessionDuration - _refreshBeforeExpiry;
      if (sessionAge >= refreshDueAt) {
        final refreshToken = await SecureTokenStorage.getRefreshToken();
        var refreshTokenRejected = false;

        if (refreshToken != null && refreshToken.isNotEmpty) {
          final refreshed = await autoLogin().timeout(
            const Duration(seconds: 12),
            onTimeout: () => null,
          );
          if (refreshed?['success'] == true) {
            if (kDebugMode) debugPrint('🔔 Session proactively renewed before refresh-token expiry');
            return;
          }

          // A transient network/5xx/timeout failure leaves the refresh token
          // intact. Retry at the next health tick; never sign out due only to
          // a temporary backend outage.
          final remainingRefreshToken = await SecureTokenStorage.getRefreshToken();
          if (remainingRefreshToken != null && remainingRefreshToken.isNotEmpty) {
            if (kDebugMode) debugPrint('🔔 Session refresh unavailable; retaining tokens for a later retry');
            return;
          }

          // autoLogin clears secure credentials for a rejected/revoked token.
          refreshTokenRejected = true;
        } else if (sessionAge <= _maxSessionDuration) {
          // Older installs may not have a refresh token. Keep an otherwise
          // valid local session until its existing seven-day limit, but do not
          // pretend it has been extended.
          if (kDebugMode) debugPrint('🔔 No refresh token available yet; retaining session until local expiry');
          return;
        }

        if (sessionAge <= _maxSessionDuration && !refreshTokenRejected) {
          return;
        }

        final connectivityResult = await Connectivity().checkConnectivity();
        final isOnline = connectivityResult != ConnectivityResult.none;
        if (kDebugMode) {
          debugPrint(isOnline
              ? '🔔 Session expired and refresh credentials are invalid - enforcing logout'
              : '🔔 Session expired offline with no usable refresh token - enforcing local expiry');
        }
        await performSecureLogout(reason: isOnline ? 'Session expired' : 'Session expired offline');
      } else {
        if (kDebugMode) debugPrint('🔔 Session still valid (${sessionAge.inDays} days old)');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Session expiry check error: $e');
    }
  }

  static Future<void> performSecureLogout({String? reason}) async {
    try {
      if (kDebugMode) debugPrint('🔔 Performing secure logout${reason != null ? ': $reason' : ''}');
      stopSessionExpiryMonitoring();
      await clearAllSessionData();
      if (reason != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('logout_reason', reason);
      }
      if (kDebugMode) debugPrint('✅ Secure logout completed');
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Secure logout error: $e');
    }
  }

  static Future<void> clearAllSessionData() async {
    try {
      await SecureTokenStorage.clearAll();
      await SecurePreferencesService.clearAllPaymentData();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_refreshTokenKey);
      await prefs.remove(_accessTokenKey);
      await prefs.remove(_refreshTokenExpiryKey);
      await prefs.remove(_userIdKey);
      await prefs.remove(_userNameKey);
      await prefs.remove(_userEmailKey);
      await prefs.remove(_sessionTimeKey);
      if (kDebugMode) debugPrint('✅ All session data cleared');
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error clearing session data: $e');
    }
  }

  static Future<String> getDeviceId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      String? deviceId = prefs.getString(_deviceIdKey);

      if (deviceId == null || deviceId.isEmpty || deviceId == 'flutter_app') {
        if (kDebugMode) debugPrint('🔍 Generating platform-specific device ID');
        String platformDeviceId;
        try {
          final secureRandom = math.Random.secure();
          final timestamp = DateTime.now().microsecondsSinceEpoch;
          final randomBytes = List<int>.generate(16, (_) => secureRandom.nextInt(256));
          final combined = '$timestamp:$randomBytes';
          final hash = _generateHash(combined);
          platformDeviceId = 'RM_SECURE_${hash.substring(0, 32)}';
          if (kDebugMode) debugPrint('✅ Generated secure device ID');
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Platform device ID generation failed: $e');
          final random = math.Random().nextInt(999999);
          final ts = DateTime.now().microsecondsSinceEpoch;
          platformDeviceId = 'RM_SECURE_${ts}_$random';
        }
        deviceId = platformDeviceId;
        await prefs.setString(_deviceIdKey, deviceId);
      }
      return deviceId;
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Error getting device ID: $e');
      final random = math.Random().nextInt(999999);
      final ts = DateTime.now().microsecondsSinceEpoch;
      return 'RM_SECURE_${ts}_$random';
    }
  }

  static String _generateHash(String input) {
    var hash = 0;
    for (var i = 0; i < input.length; i++) {
      hash = ((hash << 5) - hash) + input.codeUnitAt(i);
      hash = hash & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  static Future<void> saveTokens({
    String? refreshToken,
    required String accessToken,
    required String deviceId,
    required int userId,
    required String userName,
    required String userEmail,
  }) async {
    return await _sessionLock.synchronized(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final expiryDate = DateTime.now().add(_maxSessionDuration);
        await ScopedSharedPreferences.setCurrentUserId(userId);
        try {
          await SecureTokenStorage.saveUserId(userId);
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Error saving scoped user id: $e');
          ErrorLogHelper.logException(e, StackTrace.current, context: 'saveTokens: userId');
        }
        if (refreshToken != null && refreshToken.isNotEmpty) {
          try {
            await SecureTokenStorage.saveRefreshToken(refreshToken);
          } catch (e) {
            if (kDebugMode) debugPrint('⚠️ Error saving refresh token: $e');
            ErrorLogHelper.logException(e, StackTrace.current, context: 'saveTokens: refresh');
          }
        }
        try {
          await SecureTokenStorage.saveToken(accessToken);
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Error saving access token: $e');
          ErrorLogHelper.logException(e, StackTrace.current, context: 'saveTokens: access');
        }
        try {
          await prefs.setString(_deviceIdKey, deviceId);
          await prefs.setString(_refreshTokenExpiryKey, expiryDate.toIso8601String());
          await prefs.setInt(_sessionTimeKey, DateTime.now().millisecondsSinceEpoch);
          await prefs.setInt(_userIdKey, userId);
          await prefs.setString(_userNameKey, userName);
          await prefs.setString(_userEmailKey, userEmail);
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Error saving user data to prefs: $e');
          ErrorLogHelper.logException(e, StackTrace.current, context: 'saveTokens: prefs');
        }
        startSessionExpiryMonitoring();
        if (kDebugMode) debugPrint('✅ Tokens saved successfully with scoped user ID: $userId');
      } catch (e, st) {
        if (kDebugMode) debugPrint('❌ Error saving tokens: $e');
        ErrorLogHelper.logException(e, st, context: 'saveTokens');
      }
    });
  }

  /// Identity verification is deliberately separate from login/session validity.
  /// A valid refresh token never grants Owner/Staff access by itself.
  /// The state is user-scoped and survives an app restart, but logout and a
  /// new login session clear it.
  // Verification is valid only for the current app process.
  // It intentionally does not survive a force-close/restart.
  static final Map<int, String> _processIdentityVerification = <int, String>{};

  static String _identityVerificationKey(int userId) =>
      '$_identityVerifiedKeyPrefix$userId';

  static String _identityVerificationRoleKey(int userId) =>
      '$_identityVerifiedRoleKeyPrefix$userId';

  static String _identityVerificationAtKey(int userId) =>
      '$_identityVerifiedAtKeyPrefix$userId';

  static Future<void> clearIdentityVerification({int? userId}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final resolvedUserId = userId ??
          prefs.getInt(_userIdKey) ??
          prefs.getInt('userId') ??
          0;
      if (resolvedUserId <= 0) return;
      _processIdentityVerification.remove(resolvedUserId);
      await prefs.remove(_identityVerificationKey(resolvedUserId));
      await prefs.remove(_identityVerificationRoleKey(resolvedUserId));
      await prefs.remove(_identityVerificationAtKey(resolvedUserId));
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Failed to clear identity verification: $e');
    }
  }

  static Future<void> markIdentityVerified({
    required int userId,
    required String role,
  }) async {
    try {
      if (userId <= 0) return;
      final normalizedRole = role.trim().toUpperCase();
      _processIdentityVerification[userId] = normalizedRole;

      // Remove any legacy persisted verification state.
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_identityVerificationKey(userId));
      await prefs.remove(_identityVerificationRoleKey(userId));
      await prefs.remove(_identityVerificationAtKey(userId));

      if (kDebugMode) {
        debugPrint('✅ Identity verified for current app process: user $userId as $normalizedRole');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Failed to save identity verification: $e');
    }
  }

  static Future<bool> isIdentityVerified({
    required int userId,
    required String role,
  }) async {
    try {
      if (userId <= 0) return false;
      return _processIdentityVerification[userId] == role.trim().toUpperCase();
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Identity verification check failed: $e');
      return false;
    }
  }

  static Future<void> initializeSession({
    required int userId,
    required String accessToken,
    String? refreshToken,
    required String userName,
    required String userEmail,
    required String role,
    String deviceId = 'flutter_app',
  }) async {
    if (kDebugMode) debugPrint('🔐 Initializing session for user ID $userId');
    // A fresh login session must pass identity verification again.
    await clearIdentityVerification(userId: userId);
    await SecureTokenStorage.clearAll();
    await saveTokens(
      refreshToken: refreshToken,
      accessToken: accessToken,
      deviceId: deviceId,
      userId: userId,
      userName: userName,
      userEmail: userEmail,
    );
    final prefs = await SharedPreferences.getInstance();
    if (role.isNotEmpty) {
      await prefs.setString('user_role', role);
    }
  }

  static Future<Map<String, dynamic>?> autoLogin() async {
    return await _autoLoginLock.synchronized(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final refreshToken = await SecureTokenStorage.getRefreshToken();
        final deviceId = prefs.getString(_deviceIdKey);
        if (refreshToken == null || refreshToken.isEmpty) {
          if (kDebugMode) debugPrint('⚠️ No saved refresh token');
          return null;
        }
        final deviceFingerprint = await getDeviceId();
        try {
          final response = await ApiClient.postJson(
            ApiClient.sessionRefresh,
            {
              'refresh_token': refreshToken,
              'device_id': deviceFingerprint,
            },
          ).timeout(const Duration(seconds: 10));
          if (response.statusCode == 200) {
            final decoded = jsonDecode(response.body);
            if (decoded is! Map<String, dynamic>) {
              if (kDebugMode) debugPrint('⚠️ Refresh endpoint returned an invalid response');
              return null;
            }
            final data = decoded;
            final accessToken = (data['access_token'] ?? data['token'])?.toString().trim() ?? '';
            final rawUserId = data['user_id'] ?? data['id'] ?? await getCurrentUserId();
            final userId = int.tryParse(rawUserId?.toString() ?? '') ?? 0;
            if (accessToken.isEmpty || userId <= 0) {
              // Never overwrite a usable saved token with an empty token or ID.
              if (kDebugMode) debugPrint('⚠️ Refresh response omitted access token or valid user ID');
              return null;
            }
            final rotatedRefreshToken =
                (data['refresh_token'] ?? refreshToken).toString();
            await saveTokens(
              refreshToken: rotatedRefreshToken,
              accessToken: accessToken,
              deviceId: deviceId ?? 'flutter_app',
              userId: userId,
              userName: data['user_name']?.toString() ?? prefs.getString(_userNameKey) ?? '',
              userEmail: data['email']?.toString() ?? prefs.getString(_userEmailKey) ?? '',
            );
            // saveTokens intentionally catches storage errors; verify persistence
            // before reporting the refresh as successful.
            final persistedAccessToken = await SecureTokenStorage.getToken();
            final persistedRefreshToken = await SecureTokenStorage.getRefreshToken();
            if (persistedAccessToken != accessToken ||
                persistedRefreshToken != rotatedRefreshToken) {
              if (kDebugMode) debugPrint('⚠️ Refreshed credentials failed storage verification');
              return null;
            }
            if (kDebugMode) debugPrint('✅ Auto-login successful');
            return {
              'success': true,
              'user_id': userId,
              'user_name': data['user_name'] ?? prefs.getString(_userNameKey),
              'email': data['email'] ?? prefs.getString(_userEmailKey),
              'message': data['message'],
            };
          }
          if (response.statusCode == 401 || response.statusCode == 403) {
            if (kDebugMode) debugPrint('⚠️ Token refresh failed with auth error: ${response.statusCode}');
            await clearTokens();
          } else {
            if (kDebugMode) debugPrint('⚠️ Token refresh failed (non-auth error): ${response.statusCode}');
          }
          return null;
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Error calling refresh endpoint: $e');
          ErrorLogHelper.logException(e, StackTrace.current, context: 'autoLogin: API call');
          return null;
        }
      } catch (e, st) {
        if (kDebugMode) debugPrint('❌ Critical error in auto-login: $e');
        ErrorLogHelper.logException(e, st, context: 'autoLogin: critical');
        return null;
      }
    });
  }

  static Future<String?> getAccessToken() async {
    try {
      return await SecureTokenStorage.getToken();
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Error getting access token: $e');
      return null;
    }
  }

  static Future<bool> isTokenValid() async {
    try {
      final accessToken = await getAccessToken();
      if (accessToken == null || accessToken.isEmpty) {
        if (kDebugMode) debugPrint('⚠️ No access token available');
        return false;
      }
      final isValid = await SecureTokenStorage.isSessionValid();
      if (!isValid) {
        if (kDebugMode) debugPrint('⚠️ Session timestamp expired (older than 7 days)');
      }
      return isValid;
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Error in isTokenValid: $e');
      return false;
    }
  }

  static Future<Map<String, dynamic>?> getUserInfo() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getInt(_userIdKey);
      final userName = prefs.getString(_userNameKey);
      final userEmail = prefs.getString(_userEmailKey);
      if (userId != null) {
        return {
          'user_id': userId,
          'user_name': userName,
          'email': userEmail,
        };
      }
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Error getting user info: $e');
      return null;
    }
  }

  static Future<int?> getCurrentUserId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(_userIdKey) ?? prefs.getInt('userId');
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Error getting current user ID: $e');
      return null;
    }
  }

  static Future<void> logout() async {
    try {
      stopSessionExpiryMonitoring();
      final accessToken = await getAccessToken();
      if (accessToken != null && accessToken.isNotEmpty) {
        try {
          await ApiClient.postJson(ApiClient.sessionLogout, {
            'access_token': accessToken,
          }).timeout(const Duration(seconds: 5));
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Server logout notification failed: $e');
        }
      }
      await clearTokens();
      if (kDebugMode) debugPrint('✅ Logout completed');
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error logging out: $e');
      ErrorLogHelper.logException(e, StackTrace.current, context: 'logout');
    }
  }

  static Future<bool> logoutAllDevices() async {
    try {
      final response = await ApiClient.postJson(ApiClient.sessionLogoutAll, {}).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        await clearTokens();
        await UserDataClearService.clearAllUserData();
        // 🔧 FIX: Do NOT clear pending sync queue - preserves offline sales/invoices
        // await SyncQueueManager.clearQueue();
        // await SyncQueueManager.resetBoxReference();
        if (kDebugMode) debugPrint('✅ Logged out from all devices (sync queue preserved)');
        return true;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Error calling logoutAll endpoint: $e');
    }
    return false;
  }

  static Future<void> clearTokens() async {
    return await _sessionLock.synchronized(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        try {
          await SecureTokenStorage.clearRefreshToken();
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Error clearing refresh token: $e');
        }
        try {
          await SecureTokenStorage.clearToken();
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Error clearing access token: $e');
        }
        try {
          await prefs.remove(_refreshTokenKey);
          await prefs.remove(_accessTokenKey);
          await prefs.remove('user_id');
          await prefs.remove('userId');
          await prefs.remove('is_staff_mode');
          await prefs.remove('auth_token');
          await prefs.remove(_deviceIdKey);
          await prefs.remove(_refreshTokenExpiryKey);
          await prefs.remove(_sessionTimeKey);
          await prefs.remove(_userIdKey);
          await prefs.remove('current_scoped_user_id');
          await prefs.remove(_userNameKey);
          await prefs.remove(_userEmailKey);
          try {
            await SecureTokenStorage.clearUserId();
          } catch (e) {
            if (kDebugMode) debugPrint('⚠️ Error clearing secure user id: $e');
          }
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Error clearing SharedPreferences: $e');
          ErrorLogHelper.logException(e, StackTrace.current, context: 'clearTokens: prefs');
        }
        try {
          const _secureStorage = flutter_secure_storage.FlutterSecureStorage();
          await _secureStorage.delete(key: 'sender_email');
          await _secureStorage.delete(key: 'app_password');
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Error clearing email secrets: $e');
        }
        try {
          await cloud_firestore.FirebaseFirestore.instance.terminate();
          await cloud_firestore.FirebaseFirestore.instance.clearPersistence();
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Error terminating Firestore: $e');
        }
        if (kDebugMode) debugPrint('✅ Tokens cleared');
      } catch (e, st) {
        if (kDebugMode) debugPrint('❌ Error clearing tokens: $e');
        ErrorLogHelper.logException(e, st, context: 'clearTokens');
      }
    });
  }

  static Future<void> queueOfflineSale({
    required Map<String, dynamic> saleData,
  }) async {
    try {
      await SyncQueueManager.enqueue('create_sale', saleData);
      if (kDebugMode) debugPrint('📦 Diverted legacy sale to SyncQueueManager.');
    } catch (e) {
      if (kDebugMode) debugPrint('Error queuing offline sale: $e');
    }
  }

  static Future<String> _offlineQueueKey() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getInt('user_id') ?? prefs.getInt('userId') ?? 0;
    return userId > 0 ? 'offline_queue_$userId' : 'offline_queue_unauthenticated';
  }

  static Future<int> syncOfflineQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = await _offlineQueueKey();
      var queue = prefs.getStringList(key) ?? [];
      if (queue.isEmpty) {
        final legacy = prefs.getStringList('offline_queue');
        if (legacy != null && legacy.isNotEmpty) {
          queue = List<String>.from(legacy);
          await prefs.setStringList(key, queue);
          await prefs.remove('offline_queue');
        }
      }
      if (queue.isEmpty) return 0;
      int synced = 0;
      final remaining = <String>[];
      for (final item in queue) {
        try {
          final data = jsonDecode(item);
          if (data['type'] == 'sale') {
            final response = await ApiClient.postJson('/api/sales/create', data['data']);
            if (response.statusCode == 200 || response.statusCode == 201) {
              synced++;
              continue;
            }
          }
          remaining.add(item);
        } catch (_) {
          remaining.add(item);
        }
      }
      if (remaining.isEmpty) {
        await prefs.remove(key);
      } else {
        await prefs.setStringList(key, remaining);
      }
      return synced;
    } catch (e) {
      return 0;
    }
  }

  static Future<int> getPendingOfflineItems() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = await _offlineQueueKey();
      return prefs.getStringList(key)?.length ?? 0;
    } catch (e) {
      return 0;
    }
  }

  static Future<DateTime?> getTokenExpiry() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final expiryStr = prefs.getString(_refreshTokenExpiryKey);
      if (expiryStr != null) {
        return DateTime.parse(expiryStr);
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  static Future<bool> isTokenExpiringSoon() async {
    try {
      final expiry = await getTokenExpiry();
      if (expiry == null) return false;
      final hoursUntilExpiry = expiry.difference(DateTime.now()).inHours;
      return hoursUntilExpiry < 24;
    } catch (e) {
      return false;
    }
  }
}
