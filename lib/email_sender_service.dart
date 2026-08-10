import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'email_secrets_defaults.dart';

/// Frontend Gmail SMTP — same flow as your previous working build.
class EmailSenderService {
  static const _secureStorage = FlutterSecureStorage(
    wOptions: WindowsOptions(useBackwardCompatibility: true),
  );

  static const _kSenderEmail = 'sender_email';
  static const _kAppPassword = 'app_password';

  static String _senderEmail = '';
  static String _appPassword = '';

  static String _fallbackSender() =>
      emailSecretsSender.trim().isNotEmpty ? emailSecretsSender.trim() : '';

  static String _fallbackPassword() =>
      emailSecretsAppPassword.replaceAll(RegExp(r'\s+'), '');

  static Future<void> _loadCredentials() async {
    _senderEmail =
        (await _secureStorage.read(key: _kSenderEmail)) ?? _fallbackSender();
    _appPassword =
        (await _secureStorage.read(key: _kAppPassword)) ?? _fallbackPassword();
  }

  static Future<void> initialize() async {
    try {
      if (kDebugMode) debugPrint('🔄 Email Service: Initializing...');
      await _loadCredentials();

      if (_senderEmail.isNotEmpty && _appPassword.isNotEmpty) {
        if (kDebugMode) debugPrint('✅ Email service initialized');
        if (kDebugMode) debugPrint('   📧 Sender: $_senderEmail');
        if (kDebugMode) {
          debugPrint(
            '   🔐 Password: ${_appPassword.replaceRange(5, _appPassword.length - 2, "***")}',
          );
        }
      } else {
        if (kDebugMode) {
          debugPrint('⚠️ Email credentials missing — use dart-define (EMAIL_SENDER, EMAIL_APP_PASSWORD) or Email Setup UI');
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error loading email credentials: $e');
    }
  }

  static Future<bool> isConfigured() async {
    await initialize();
    return _senderEmail.isNotEmpty && _appPassword.isNotEmpty;
  }

  static Future<String?> getSenderEmail() async {
    await _loadCredentials();
    return _senderEmail.isEmpty ? null : _senderEmail;
  }

  static Future<bool> setCredentials({
    required String email,
    required String password,
  }) async {
    final normalizedEmail = email.trim().toLowerCase();
    final normalizedPassword = password.replaceAll(RegExp(r'\s+'), '');
    if (normalizedEmail.isEmpty || normalizedPassword.isEmpty) return false;

    try {
      await _secureStorage.write(key: _kSenderEmail, value: normalizedEmail);
      await _secureStorage.write(key: _kAppPassword, value: normalizedPassword);
      _senderEmail = normalizedEmail;
      _appPassword = normalizedPassword;
      if (kDebugMode) debugPrint('✅ Credentials stored securely');
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error storing credentials: $e');
      return false;
    }
  }

  static Future<bool> sendOTPEmail({
    required String recipientEmail,
    required String otp,
    required String userName,
    String title = '🔐 Password Reset',
    String bodyText = 'You requested to reset your password. Use the OTP below:',
  }) async {
    final email =
        (await _secureStorage.read(key: _kSenderEmail)) ?? _fallbackSender();
    final password =
        (await _secureStorage.read(key: _kAppPassword)) ?? _fallbackPassword();

    if (email.isEmpty || password.isEmpty) {
      if (kDebugMode) debugPrint('Email not configured.');
      return false;
    }

    _senderEmail = email;
    _appPassword = password;

    try {
      if (kDebugMode) debugPrint('📧 Sending OTP to: $recipientEmail');

      final smtpServer = gmail(_senderEmail, _appPassword);

      final htmlBody = '''<html>
  <body style="font-family: Arial, sans-serif; background-color: #f5f5f5; padding: 20px;">
    <div style="max-width: 500px; margin: 0 auto; background-color: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1);">
      <h2 style="color: #333; text-align: center;">$title</h2>
      <p style="color: #666; font-size: 16px;">Hi $userName,</p>
      <p style="color: #666; font-size: 14px;">$bodyText</p>
      <div style="background-color: #6366F1; color: white; padding: 20px; text-align: center; border-radius: 8px; margin: 20px 0;">
        <p style="font-size: 24px; font-weight: bold; letter-spacing: 3px; margin: 0;">$otp</p>
      </div>
      <p style="color: #999; font-size: 12px;">⏱️ This OTP is valid for 10 minutes.</p>
      <p style="color: #999; font-size: 12px;">If you didn't request this, please ignore this email.</p>
      <hr style="border: none; border-top: 1px solid #eee; margin: 20px 0;">
      <p style="color: #999; font-size: 11px; text-align: center;">© 2026 AI Shop</p>
    </div>
  </body>
</html>''';

      final message = Message()
        ..from = Address(_senderEmail, 'AI Shop')
        ..recipients.add(recipientEmail)
        ..subject = '$title OTP'
        ..html = htmlBody;

      final sendReport = await send(message, smtpServer);
      if (kDebugMode) debugPrint('✅ OTP Email sent: $sendReport');
      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('❌ Email sending failed: $e');
        if (e.toString().contains('Authentication failed')) {
          debugPrint('   Check Gmail App Password (2FA + new app password).');
        }
      }
      return false;
    }
  }

  static Future<bool> sendStockAlertEmail({
    required String recipientEmail,
    required String productName,
    required int currentStock,
    required int minStock,
  }) async {
    final email =
        (await _secureStorage.read(key: _kSenderEmail)) ?? _fallbackSender();
    final password =
        (await _secureStorage.read(key: _kAppPassword)) ?? _fallbackPassword();

    if (email.isEmpty || password.isEmpty) return false;

    _senderEmail = email;
    _appPassword = password;

    try {
      final smtpServer = gmail(_senderEmail, _appPassword);
      final htmlBody = '''<html>
  <body style="font-family: Arial, sans-serif; background-color: #f5f5f5; padding: 20px;">
    <div style="max-width: 500px; margin: 0 auto; background-color: white; padding: 30px; border-radius: 8px;">
      <h2 style="color: #FF6B35; text-align: center;">⚠️ Low Stock Alert</h2>
      <p>Product <strong>$productName</strong>: $currentStock left (min $minStock)</p>
    </div>
  </body>
</html>''';

      final message = Message()
        ..from = Address(_senderEmail, 'AI Shop Inventory')
        ..recipients.add(recipientEmail)
        ..subject = '⚠️ Low Stock Alert: $productName'
        ..html = htmlBody;

      await send(message, smtpServer);
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Stock alert email failed: $e');
      return false;
    }
  }

  /// Test email configuration by sending a test email
  static Future<Map<String, dynamic>> testEmailConfiguration({
    required String recipientEmail,
  }) async {
    await initialize();
    
    if (_senderEmail.isEmpty || _appPassword.isEmpty) {
      return {
        'success': false,
        'message': 'Email credentials not configured. Use dart-define (EMAIL_SENDER, EMAIL_APP_PASSWORD) or Email Setup UI',
      };
    }
    
    try {
      if (kDebugMode) debugPrint('📧 Testing email configuration...');
      if (kDebugMode) debugPrint('   Sender: $_senderEmail');
      
      final smtpServer = gmail(_senderEmail, _appPassword);
      
      final testOtp = '123456'; // Test OTP
      final htmlBody = '''<html>
  <body style="font-family: Arial, sans-serif; background-color: #f5f5f5; padding: 20px;">
    <div style="max-width: 500px; margin: 0 auto; background-color: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1);">
      <h2 style="color: #10B981; text-align: center;">✅ Email Configuration Test</h2>
      <p style="color: #666; font-size: 16px;">Hi,</p>
      <p style="color: #666; font-size: 14px;">This is a test email to verify your AI Shop email configuration is working correctly.</p>
      <div style="background-color: #6366F1; color: white; padding: 20px; text-align: center; border-radius: 8px; margin: 20px 0;">
        <p style="font-size: 24px; font-weight: bold; letter-spacing: 3px; margin: 0;">$testOtp</p>
      </div>
      <p style="color: #10B981; font-size: 14px;">✅ If you received this email, your configuration is working!</p>
      <hr style="border: none; border-top: 1px solid #eee; margin: 20px 0;">
      <p style="color: #999; font-size: 11px; text-align: center;">© 2026 AI Shop - Configuration Test</p>
    </div>
  </body>
</html>''';

      final message = Message()
        ..from = Address(_senderEmail, 'AI Shop Test')
        ..recipients.add(recipientEmail)
        ..subject = '✅ AI Shop Email Configuration Test'
        ..html = htmlBody;

      final sendReport = await send(message, smtpServer);
      if (kDebugMode) debugPrint('✅ Test email sent successfully: $sendReport');
      
      return {
        'success': true,
        'message': 'Test email sent successfully to $recipientEmail',
        'details': sendReport.toString(),
      };
    } catch (e) {
      if (kDebugMode) {
        debugPrint('❌ Test email failed: $e');
        if (e.toString().contains('Authentication failed')) {
          debugPrint('   ❌ Authentication failed - check Gmail App Password');
          debugPrint('   ℹ️ Enable 2FA on your Gmail account');
          debugPrint('   ℹ️ Generate an App Password: Google Account > Security > 2-Step Verification > App Passwords');
        }
      }
      return {
        'success': false,
        'message': 'Failed to send test email: $e',
        'troubleshooting': 'Check Gmail App Password and ensure 2FA is enabled',
      };
    }
  }
}
