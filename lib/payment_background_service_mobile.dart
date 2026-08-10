// dart:async import removed — Timer was removed in Issue 4.1 fix.
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:flutter_background_service_ios/flutter_background_service_ios.dart';
import 'package:permission_handler/permission_handler.dart';
import 'payment_announcement_service.dart';
import 'payment_detection_service.dart';

@pragma('vm:entry-point')
Future<bool> onStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();

  var hasNotificationPermission = true;
  try {
    final status = await Permission.notification.status;
    hasNotificationPermission = status.isGranted;
  } catch (_) {
    hasNotificationPermission = false;
  }

  if (service is AndroidServiceInstance && hasNotificationPermission) {
    service.setForegroundNotificationInfo(
      title: "Retail Mind",
      content: "Listening for payments...",
    );
  }

  try {
    await PaymentAnnouncementService().init();

    final prefs = await SharedPreferences.getInstance();
    final langCode = prefs.getString('payment_sound_lang') ?? 'en-US';

    final pds = PaymentDetectionService();
    pds.setLanguage(PaymentDetectionService.mapLanguage(langCode));

    pds.onSpeak = (text) async {
      final prefs = await SharedPreferences.getInstance();
      final lang = prefs.getString('payment_sound_lang') ?? 'en-US';
      PaymentAnnouncementService().speakSimple(text, lang);
    };

    await pds.start();
    debugPrint('✅ Background payment services initialized');
  } catch (e) {
    debugPrint('⚠️ Background service init error: $e');
    return false;
  }

  // FIX (Issue 4.1): Removed Timer.periodic(1 second) that was calling
  // service.invoke('update') every second, causing constant CPU wake locks
  // and significant battery drain. The PaymentDetectionService is
  // event-driven (SMS/notifications), so no polling timer is required.

  return true;
}

Future<void> initializeBackgroundService() async {
  try {
    final service = FlutterBackgroundService();

    // Check notification permission on Android 13+ to avoid CannotPostForegroundServiceNotificationException
    // We only check the status; we do not call request() from here because this code can run in the background without UI context.
    var isForeground = true;
    try {
      if (Platform.isAndroid) {
        final status = await Permission.notification.status;
        if (!status.isGranted) {
          isForeground = false; // Run in background-only mode if permission is not granted yet
          debugPrint('⚠️ Notification permission not granted yet. Starting service in background-only mode to avoid crash.');
        }
      }
    } catch (pe) {
      isForeground = false; // Safe fallback
      debugPrint('⚠️ Permission check failed: $pe');
    }

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: true,
        isForegroundMode: false, // Hardcoded to false to prevent CannotPostForegroundServiceNotificationException
        notificationChannelId: 'payment_detection_channel',
        initialNotificationTitle: 'Retail Mind',
        initialNotificationContent: 'Starting payment listener...',
        foregroundServiceNotificationId: 888,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: true,
        onForeground: onStart,
        onBackground: onStart,
      ),
    );

    await service.startService();
    debugPrint('✅ Background service started successfully (foreground=$isForeground)');
  } catch (e) {
    debugPrint('⚠️ Failed to start background service: $e');
    await _initializeFallback();
  }
}

Future<void> _initializeFallback() async {
  try {
    await PaymentAnnouncementService().init();

    final prefs = await SharedPreferences.getInstance();
    final langCode = prefs.getString('payment_sound_lang') ?? 'en-US';

    final pds = PaymentDetectionService();
    pds.setLanguage(PaymentDetectionService.mapLanguage(langCode));

    pds.onSpeak = (text) async {
      final prefs = await SharedPreferences.getInstance();
      final lang = prefs.getString('payment_sound_lang') ?? 'en-US';
      PaymentAnnouncementService().speakSimple(text, lang);
    };

    await pds.start();
    debugPrint('✅ Payment services initialized (fallback mode)');
  } catch (e) {
    debugPrint('⚠️ Failed fallback initialization: $e');
  }
}
