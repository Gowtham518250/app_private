import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_localizations.dart';
import 'utils/free_translator_service.dart';

/// Runtime translation fallback for UI copy not present in the bundled
/// AppLocalizations catalogue. Bundled translations are always preferred;
/// remote translations are cached so previously seen strings can work offline.
class LiveTranslationService {
  LiveTranslationService._();

  static final Map<String, String> _memoryCache = <String, String>{};
  static final Map<String, Future<String>> _inFlight = <String, Future<String>>{};
  static final List<_TranslationTask> _queue = <_TranslationTask>[];
  static bool _draining = false;
  static const int _maxConcurrent = 3;
  static int _activeCount = 0;

  static String? bundledTranslation(String text, String languageCode) =>
      AppLocalizations.translateRawText(text, languageCode);

  static bool shouldTranslate(String text, String languageCode) {
    final value = text.trim();
    if (languageCode == 'en' || value.isEmpty || value.length > 240) return false;
    if (!RegExp(r'[A-Za-z]').hasMatch(value)) return false;
    if (RegExp(r'^(?:https?://|www\.)', caseSensitive: false).hasMatch(value)) {
      return false;
    }
    if (RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value)) return false;
    if (RegExp(r'^\+?[\d\s().-]{7,}$').hasMatch(value)) return false;
    // Do not send obvious account references, UPI IDs, SKU-like codes, or
    // interpolation templates to the external fallback translator.
    if (value.contains('@') ||
        RegExp(r'\b[A-Z]{2,}[-_]?\d{3,}\b').hasMatch(value) ||
        RegExp(r'\{[^}]+\}').hasMatch(value)) {
      return false;
    }
    // Values already displayed in a native script are assumed to be
    // user-entered data, or already translated copy.
    if (RegExp(r'[\u0900-\u0DFF\u0B80-\u0DFF]').hasMatch(value)) {
      return false;
    }
    return true;
  }

  static Future<String> translate(String text, String languageCode) async {
    final raw = text;
    final local = bundledTranslation(raw, languageCode);
    if (local != null && local.trim().isNotEmpty) return local;
    if (!shouldTranslate(raw, languageCode)) return raw;

    final digest = sha256.convert(utf8.encode(raw.trim())).toString();
    final key = 'live_translation_${languageCode}_$digest';
    final memoryKey = '$languageCode:$digest';
    final memoryHit = _memoryCache[memoryKey];
    if (memoryHit != null) return memoryHit;

    final pending = _inFlight[memoryKey];
    if (pending != null) return pending;

    final task = _TranslationTask(
      raw: raw,
      languageCode: languageCode,
      memoryKey: memoryKey,
      persistentKey: key,
    );
    final future = task.completer.future;
    _inFlight[memoryKey] = future;
    _queue.add(task);
    unawaited(_drain());
    return future;
  }

  static Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty && _activeCount < _maxConcurrent) {
        final task = _queue.removeAt(0);
        _activeCount++;
        unawaited(_runTask(task));
      }
    } finally {
      _draining = false;
    }
  }

  static Future<void> _runTask(_TranslationTask task) async {
    var result = task.raw;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(task.persistentKey);
      if (saved != null && saved.isNotEmpty) {
        result = saved;
      } else {
        final translated = await FreeTranslatorService.translate(
          task.raw,
          from: 'auto',
          to: task.languageCode,
        ).timeout(const Duration(seconds: 5));
        if (translated.trim().isNotEmpty) result = translated.trim();
        if (result != task.raw) {
          await prefs.setString(task.persistentKey, result);
        }
      }
    } catch (_) {
      // Offline, unsupported language, quota or service error: retain the
      // original copy instead of blocking a screen or breaking navigation.
    } finally {
      _memoryCache[task.memoryKey] = result;
      _inFlight.remove(task.memoryKey);
      task.completer.complete(result);
      _activeCount--;
      unawaited(_drain());
    }
  }

  @visibleForTesting
  static void clearMemoryCacheForTests() {
    _memoryCache.clear();
    _inFlight.clear();
    _queue.clear();
  }
}

class _TranslationTask {
  final String raw;
  final String languageCode;
  final String memoryKey;
  final String persistentKey;
  final Completer<String> completer = Completer<String>();

  _TranslationTask({
    required this.raw,
    required this.languageCode,
    required this.memoryKey,
    required this.persistentKey,
  });
}
