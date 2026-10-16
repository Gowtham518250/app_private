import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:retail_mind/language_provider.dart';
import 'package:retail_mind/live_translation_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('login language selection overrides the previous account preference', () async {
    SharedPreferences.setMockInitialValues({
      'retail_mind_language_owner_42': 'hi',
      'app_language': 'en',
      'language_code': 'en',
    });

    final provider = LanguageProvider();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await provider.setLanguage('te');
    await provider.bindToAccount(accountType: 'owner', accountId: 42);

    expect(provider.locale.languageCode, 'te');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('retail_mind_language_owner_42'), 'te');

    provider.dispose();
  });

  test('all configured app languages are accepted', () {
    for (final code in <String>[
      'en', 'te', 'hi', 'ta', 'kn', 'ml', 'mr', 'bn', 'gu', 'pa', 'or', 'as', 'ur',
    ]) {
      expect(LanguageProvider.supports(code), isTrue, reason: 'Expected $code to be supported');
    }
  });

  test('financial values and backend error messages bypass live translation', () {
    expect(LiveTranslationService.shouldTranslate('₹150 received', 'te'), isFalse);
    expect(LiveTranslationService.shouldTranslate('Error: authentication failed', 'te'), isFalse);
    expect(LiveTranslationService.shouldTranslate('Payment of $250 received', 'hi'), isFalse);
  });
}
