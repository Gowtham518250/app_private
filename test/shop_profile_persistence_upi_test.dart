import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:retail_mind/shop_profile_persistence_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'user_id': 42});
  });

  group('First-save UPI persistence regressions', () {
    test('persists a flat UPI ID immediately', () async {
      await ShopProfilePersistenceService.saveProfileLocally({
        'shop_name': 'Test Shop',
        'primary_upi_id': 'testshop@upi',
      });

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('primary_upi_id'), 'testshop@upi');
      expect(prefs.getString('upi_id'), 'testshop@upi');
      expect(prefs.getString('shop_profile_cache_42'), isNotNull);
    });

    test('unwraps data.profile and falls back when primary UPI is blank', () async {
      await ShopProfilePersistenceService.saveProfileLocally({
        'data': {
          'profile': {'primary_upi_id': ''},
          'settings': {'upi_id': 'firstsave@upi'},
        },
      });

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('primary_upi_id'), 'firstsave@upi');
      expect(prefs.getString('upi_id'), 'firstsave@upi');
    });

    test('restores UPI from wrapped profile and settings response', () async {
      await ShopProfilePersistenceService.applyProfileToPrefs({
        'data': {
          'profile': {'primary_upi_id': ''},
          'settings': {'upi_id': 'restored@upi'},
        },
      });

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('primary_upi_id'), 'restored@upi');
      expect(prefs.getString('upi_id'), 'restored@upi');
    });
  });
}
