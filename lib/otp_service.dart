import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_client.dart';
import 'email_sender_service.dart';

/// Frontend-owned OTP generation, Gmail delivery and local verification.
///
/// The backend is used only after the user has locally verified the OTP to
/// obtain a short-lived, one-time password-reset authorization token.
class OTPService {
  static const _storage = FlutterSecureStorage();

  static const _kEmail = 'password_reset_email';
  static const _kOtpHash = 'password_reset_otp_hash';
  static const _kOtpCreatedAt = 'password_reset_otp_created_at';
  static const _kChallengeId = 'password_reset_challenge_id';
  static const _kRegistrationSecret = 'password_reset_registration_secret';
  static const _kResetToken = 'password_reset_reset_token';
  static const _kAttempts = 'password_reset_otp_attempts';

  static const Duration _otpValidity = Duration(minutes: 10);
  static const int _maxLocalAttempts = 5;

  static String _generateSecureOTP() {
    return (Random.secure().nextInt(900000) + 100000).toString();
  }

  static String _hashOtp(String otp) {
    return sha256.convert(utf8.encode(otp)).toString();
  }

  static Future<void> _clearOtpOnly() async {
    await _storage.delete(key: _kOtpHash);
    await _storage.delete(key: _kOtpCreatedAt);
    await _storage.delete(key: _kAttempts);
  }

  static Future<void> clearResetState() async {
    for (final key in const [
      _kEmail,
      _kOtpHash,
      _kOtpCreatedAt,
      _kChallengeId,
      _kRegistrationSecret,
      _kResetToken,
      _kAttempts,
    ]) {
      await _storage.delete(key: key);
    }
  }

  static Future<Map<String, dynamic>> sendOTPToEmail(
    String email, {
    String? title,
    String? bodyText,
  }) async {
    final normalizedEmail = email.trim().toLowerCase();
    if (normalizedEmail.isEmpty) {
      return {'success': false, 'message': 'Email is required'};
    }

    try {
      await clearResetState();

      final startResponse = await ApiClient.postJson(
        '/api/auth-hardened/password-reset/start',
        {'email': normalizedEmail},
      );

      if (startResponse.statusCode != 200) {
        return {
          'success': false,
          'message': 'Unable to start the secure password reset. Please try again.',
        };
      }

      final startData = jsonDecode(startResponse.body);
      final challengeId = startData['challenge_id']?.toString() ?? '';
      final registrationSecret = startData['registration_secret']?.toString() ?? '';
      final confirmationUrl = startData['confirmation_url']?.toString() ?? '';

      if (challengeId.isEmpty || registrationSecret.isEmpty || confirmationUrl.isEmpty) {
        return {
          'success': false,
          'message': 'Secure reset challenge could not be created.',
        };
      }

      final otp = _generateSecureOTP();
      final otpHash = _hashOtp(otp);
      final createdAt = DateTime.now().millisecondsSinceEpoch;

      await _storage.write(key: _kEmail, value: normalizedEmail);
      await _storage.write(key: _kOtpHash, value: otpHash);
      await _storage.write(key: _kOtpCreatedAt, value: createdAt.toString());
      await _storage.write(key: _kChallengeId, value: challengeId);
      await _storage.write(key: _kRegistrationSecret, value: registrationSecret);
      await _storage.write(key: _kAttempts, value: '0');

      final registerResponse = await ApiClient.postJson(
        '/api/auth-hardened/password-reset/register-otp',
        {
          'challenge_id': challengeId,
          'registration_secret': registrationSecret,
          'otp_hash': otpHash,
        },
      );

      if (registerResponse.statusCode != 200) {
        await clearResetState();
        return {
          'success': false,
          'message': 'Unable to register the password-reset verification.',
        };
      }

      final emailSent = await EmailSenderService.sendOTPEmail(
        recipientEmail: normalizedEmail,
        otp: otp,
        userName: 'Owner',
        title: title ?? '🔐 Password Reset',
        bodyText: bodyText ??
            'Use the OTP below to reset your Retail Mind owner password. Also confirm the email using the secure button below.',
        confirmationUrl: confirmationUrl,
      );

      if (!emailSent) {
        await clearResetState();
        return {
          'success': false,
          'message':
              'Failed to send OTP. Check the Gmail SMTP credentials configured for the app.',
        };
      }

      if (kDebugMode) {
        debugPrint('✅ Secure frontend OTP sent to $normalizedEmail');
      }

      return {
        'success': true,
        'message': 'OTP sent. Open the email, confirm the email link, then enter the OTP.',
      };
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Secure OTP send failed: $e');
      return {'success': false, 'message': 'Failed to start password reset: $e'};
    }
  }

  static Future<Map<String, dynamic>> verifyOTP(
    String email,
    String enteredOTP,
  ) async {
    final normalizedEmail = email.trim().toLowerCase();
    final code = enteredOTP.trim();

    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      return {'success': false, 'message': 'OTP must be 6 digits'};
    }

    final storedEmail = await _storage.read(key: _kEmail);
    final storedHash = await _storage.read(key: _kOtpHash);
    final createdAtRaw = await _storage.read(key: _kOtpCreatedAt);
    final challengeId = await _storage.read(key: _kChallengeId);
    final attemptsRaw = await _storage.read(key: _kAttempts);

    if (storedEmail == null || storedHash == null || createdAtRaw == null || challengeId == null) {
      return {'success': false, 'message': 'No OTP pending. Request a new code.'};
    }

    if (storedEmail != normalizedEmail) {
      return {'success': false, 'message': 'The OTP belongs to a different email address.'};
    }

    final createdAt = int.tryParse(createdAtRaw);
    if (createdAt == null) {
      await clearResetState();
      return {'success': false, 'message': 'Reset verification state is invalid.'};
    }

    if (DateTime.now().millisecondsSinceEpoch - createdAt > _otpValidity.inMilliseconds) {
      await clearResetState();
      return {'success': false, 'message': 'OTP expired. Request a new code.'};
    }

    final attempts = int.tryParse(attemptsRaw ?? '0') ?? 0;
    if (attempts >= _maxLocalAttempts) {
      await clearResetState();
      return {'success': false, 'message': 'Too many OTP attempts. Request a new code.'};
    }

    final enteredHash = _hashOtp(code);
    if (!_constantTimeEquals(storedHash, enteredHash)) {
      await _storage.write(key: _kAttempts, value: '${attempts + 1}');
      final left = _maxLocalAttempts - attempts - 1;
      return {
        'success': false,
        'message': left > 0
            ? 'Invalid OTP. $left attempt(s) remaining.'
            : 'Invalid OTP. Request a new code.',
      };
    }

    // Local verification succeeded. Now require the independent mailbox
    // confirmation and let the backend issue the short-lived reset token.
    final authorizeResponse = await ApiClient.postJson(
      '/api/auth-hardened/password-reset/authorize',
      {
        'challenge_id': challengeId,
        'email': normalizedEmail,
        'otp': code,
      },
    );

    if (authorizeResponse.statusCode != 200) {
      try {
        final data = jsonDecode(authorizeResponse.body);
        final message = data['detail']?.toString() ?? 'Reset authorization failed';
        return {'success': false, 'message': message};
      } catch (_) {
        return {'success': false, 'message': 'Reset authorization failed'};
      }
    }

    final data = jsonDecode(authorizeResponse.body);
    final resetToken = data['reset_token']?.toString() ?? '';
    if (resetToken.isEmpty) {
      return {'success': false, 'message': 'Reset authorization token was not issued.'};
    }

    await _storage.write(key: _kResetToken, value: resetToken);
    await _clearOtpOnly();

    return {
      'success': true,
      'message': 'OTP verified and reset authorization granted.',
      'token': resetToken,
    };
  }

  static Future<bool> _hasStoredResetToken() async {
    final token = await _storage.read(key: _kResetToken);
    return token != null && token.isNotEmpty;
  }

  static Future<String?> getResetToken() async {
    return _storage.read(key: _kResetToken);
  }

  static Future<Map<String, dynamic>> resendOTP(String email) async {
    return sendOTPToEmail(
      email,
      title: '🔄 Retail Mind Password Reset',
      bodyText: 'A new password-reset code was requested. Use the OTP below and confirm the secure email link.',
    );
  }

  static Future<int> getRemainingTime() async {
    final createdAtRaw = await _storage.read(key: _kOtpCreatedAt);
    if (createdAtRaw == null) return 0;
    final createdAt = int.tryParse(createdAtRaw);
    if (createdAt == null) return 0;
    final remaining = _otpValidity - Duration(milliseconds: DateTime.now().millisecondsSinceEpoch - createdAt);
    return remaining.isNegative ? 0 : remaining.inSeconds;
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}

