import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Central app-wide language state.
///
/// The language chosen before login is stored as the device's preferred language.
/// Once an account is known, its language is stored separately so different
/// users of the same device keep their own preference.
class LanguageProvider extends ChangeNotifier {
  static const String _deviceLanguageKey = 'app_language';
  static const String _legacyLanguageKey = 'language_code';
  static const String _accountLanguagePrefix = 'retail_mind_language_';

  Locale _locale = const Locale('en');
  String? _activeAccountKey;
  bool _disposed = false;
  bool _explicitSelectionPendingAccountBinding = false;
  int _loadGeneration = 0;

  Locale get locale => _locale;
  String? get activeAccountKey => _activeAccountKey;

  LanguageProvider() {
    _loadSavedLanguage();
  }

  static const List<Map<String, String>> languages = [
    {'code': 'en', 'name': 'English', 'nativeName': 'English', 'flag': '🇮🇳'},
    {'code': 'te', 'name': 'Telugu', 'nativeName': 'తెలుగు', 'flag': '🇮🇳'},
    {'code': 'hi', 'name': 'Hindi', 'nativeName': 'हिन्दी', 'flag': '🇮🇳'},
    {'code': 'ta', 'name': 'Tamil', 'nativeName': 'தமிழ்', 'flag': '🇮🇳'},
    {'code': 'kn', 'name': 'Kannada', 'nativeName': 'ಕನ್ನಡ', 'flag': '🇮🇳'},
    {'code': 'ml', 'name': 'Malayalam', 'nativeName': 'മലയാളം', 'flag': '🇮🇳'},
    {'code': 'mr', 'name': 'Marathi', 'nativeName': 'मराठी', 'flag': '🇮🇳'},
    {'code': 'bn', 'name': 'Bengali', 'nativeName': 'বাংলা', 'flag': '🇮🇳'},
    {'code': 'gu', 'name': 'Gujarati', 'nativeName': 'ગુજરાતી', 'flag': '🇮🇳'},
    {'code': 'pa', 'name': 'Punjabi', 'nativeName': 'ਪੰਜਾਬੀ', 'flag': '🇮🇳'},
    {'code': 'or', 'name': 'Odia', 'nativeName': 'ଓଡ଼ିଆ', 'flag': '🇮🇳'},
    {'code': 'as', 'name': 'Assamese', 'nativeName': 'অসমীয়া', 'flag': '🇮🇳'},
    {'code': 'ur', 'name': 'Urdu', 'nativeName': 'اردو', 'flag': '🇮🇳'},
  ];

  static bool supports(String languageCode) =>
      languages.any((language) => language['code'] == languageCode);

  Future<void> _loadSavedLanguage() async {
    final generation = ++_loadGeneration;
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedAccountKey = _accountKeyFromPreferences(prefs);
      final accountLanguage = savedAccountKey == null
          ? null
          : prefs.getString('$_accountLanguagePrefix$savedAccountKey');
      final languageCode = _supportedOrEnglish(
        accountLanguage ??
            prefs.getString(_deviceLanguageKey) ??
            prefs.getString(_legacyLanguageKey) ??
            'en',
      );

      if (_disposed || generation != _loadGeneration) return;
      _activeAccountKey = savedAccountKey;
      _locale = Locale(languageCode);
      notifyListeners();
    } catch (_) {
      // The app can still start in English if preferences are unavailable.
    }
  }

  /// Immediately switches all locale-aware widgets and persists the choice.
  /// This also works before login, when only a device-level preference exists.
  Future<void> setLanguage(String languageCode) async {
    if (!supports(languageCode)) return;
    ++_loadGeneration; // Prevent a late initial load overwriting the selection.
    if (_activeAccountKey == null) {
      // A choice made on the login screen must take precedence when the next
      // authenticated account is bound, even if that account has an older
      // language preference saved from a previous session.
      _explicitSelectionPendingAccountBinding = true;
    }
    _locale = Locale(languageCode);
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_deviceLanguageKey, languageCode);
    await prefs.setString(_legacyLanguageKey, languageCode);
    if (_activeAccountKey != null) {
      await prefs.setString(
        '$_accountLanguagePrefix$_activeAccountKey',
        languageCode,
      );
      _explicitSelectionPendingAccountBinding = false;
    }
  }

  /// Binds the current preference to an authenticated account.
  ///
  /// Use distinct account types so an owner/customer with the same numeric ID
  /// cannot share a language preference by accident.
  Future<void> bindToAccount({
    required String accountType,
    required Object accountId,
  }) async {
    final normalizedType = accountType.trim().toLowerCase();
    final normalizedId = accountId.toString().trim();
    if (normalizedType.isEmpty || normalizedId.isEmpty || normalizedId == '0') {
      return;
    }

    final accountKey = '${normalizedType}_${normalizedId}';
    if (_activeAccountKey == accountKey &&
        !_explicitSelectionPendingAccountBinding) {
      return;
    }
    ++_loadGeneration;

    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('$_accountLanguagePrefix$accountKey');
    final explicitlySelected = _explicitSelectionPendingAccountBinding
        ? _locale.languageCode
        : null;
    final languageCode = _supportedOrEnglish(
      explicitlySelected ?? saved ?? prefs.getString(_deviceLanguageKey) ??
          prefs.getString(_legacyLanguageKey) ?? _locale.languageCode,
    );

    _activeAccountKey = accountKey;
    _locale = Locale(languageCode);
    // A first-time account inherits the currently selected language.
    if (saved == null || explicitlySelected != null) {
      await prefs.setString('$_accountLanguagePrefix$accountKey', languageCode);
    }
    _explicitSelectionPendingAccountBinding = false;
    await prefs.setString(_deviceLanguageKey, languageCode);
    await prefs.setString(_legacyLanguageKey, languageCode);
    notifyListeners();
  }

  /// Clears account binding without deleting the account's saved preference.
  /// The login screen returns to the last device-selected language.
  Future<void> unbindAccount() async {
    if (_activeAccountKey == null) return;
    ++_loadGeneration;
    _activeAccountKey = null;
    final prefs = await SharedPreferences.getInstance();
    final code = _supportedOrEnglish(
      prefs.getString(_deviceLanguageKey) ??
          prefs.getString(_legacyLanguageKey) ?? 'en',
    );
    _locale = Locale(code);
    notifyListeners();
  }

  String _supportedOrEnglish(String code) => supports(code) ? code : 'en';

  String? _accountKeyFromPreferences(SharedPreferences prefs) {
    final role = (prefs.getString('user_role') ??
            prefs.getString('role') ??
            '')
        .trim()
        .toLowerCase();
    final userType = (prefs.getString('user_type') ?? '').trim().toLowerCase();

    if (role == 'customer' || userType == 'customer' ||
        prefs.containsKey('customer_id')) {
      final customerId = prefs.getString('customer_id') ??
          prefs.getInt('customer_id')?.toString();
      if (customerId != null && customerId.trim().isNotEmpty &&
          customerId.trim() != '0') {
        return 'customer_${customerId.trim()}';
      }
    }

    final ownerId = prefs.getInt('user_id') ??
        prefs.getInt('userId') ??
        int.tryParse(prefs.getString('user_id') ?? '');
    if (ownerId != null && ownerId > 0) {
      final accountType = role == 'worker' ? 'worker' : 'owner';
      return '${accountType}_$ownerId';
    }
    return null;
  }

  @override
  void dispose() {
    _disposed = true;
    ++_loadGeneration;
    super.dispose();
  }
}
