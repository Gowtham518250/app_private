import 'dart:math';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'email_sender_service.dart';
import 'api_client.dart';

/// OTP Service: Frontend-only OTP generation via Gmail SMTP
class OTPService {
  static String? _lastLocalOTP;
  static DateTime? _lastOtpTime;
  static const Duration _otpValidity = Duration(minutes: 10);

  static String _generateLocalOTP() {
    return (Random.secure().nextInt(900000) + 100000).toString();
  }

  /// Send OTP strictly via local SMTP using Gmail credentials
  static Future<Map<String, dynamic>> sendOTPToEmail(
    String email, {
    String? title,
    String? bodyText,
  }) async {
    return _sendOTPViaSMTP(email, title, bodyText);
  }

  /// Internal method to handle SMTP sending
  static Future<Map<String, dynamic>> _sendOTPViaSMTP(
    String email,
    String? title,
    String? bodyText,
  ) async {
    try {
      final otp = _generateLocalOTP();
      _lastLocalOTP = otp;
      _lastOtpTime = DateTime.now();

      final emailSent = await EmailSenderService.sendOTPEmail(
        recipientEmail: email.trim(),
        otp: otp,
        userName: 'User',
        title: title ?? '🔐 Email Verification',
        bodyText: bodyText ?? 'Use the OTP below to verify your identity:',
      );

      if (emailSent) {
        if (kDebugMode) debugPrint('✅ SMTP OTP sent successfully');
        return {
          'success': true,
          'message': 'OTP sent to $email',
          'backend': false,
          if (kDebugMode) 'debugOtp': otp,
        };
      }

      return {
        'success': false,
        'message':
            'Failed to send OTP. Use dart-define (EMAIL_SENDER, EMAIL_APP_PASSWORD) or open Email Setup.',
        if (kDebugMode) 'debugOtp': otp,
      };
    } catch (e) {
      return {'success': false, 'message': 'Failed to send OTP: $e'};
    }
  }

  /// Verify OTP purely locally (frontend-only verification)
  static Future<Map<String, dynamic>> verifyOTP(String email, String enteredOTP) async {
    return _verifyOTPLocally(enteredOTP);
  }

  /// Internal local verification logic (Fallback only if backend is unreachable)
  static Future<Map<String, dynamic>> _verifyOTPLocally(String enteredOTP) async {
    final code = enteredOTP.trim();
    if (code.length != 6) {
      return {'success': false, 'message': 'OTP must be 6 digits'};
    }

    if (_lastLocalOTP == null || _lastOtpTime == null) {
      return {'success': false, 'message': 'No OTP pending. Request a new code.'};
    }

    if (DateTime.now().difference(_lastOtpTime!) > _otpValidity) {
      _lastLocalOTP = null;
      _lastOtpTime = null;
      return {'success': false, 'message': 'OTP expired. Request a new code.'};
    }

    if (_lastLocalOTP == code) {
      _lastLocalOTP = null;
      _lastOtpTime = null;
      return {'success': true, 'message': 'OTP verified locally', 'token': 'local_verified'};
    }

    return {'success': false, 'message': 'Invalid OTP'};
  }

  static Future<Map<String, dynamic>> resendOTP(String email) async {
    return sendOTPToEmail(
      email,
      title: '🔄 Resend OTP',
      bodyText: 'You requested a new OTP. Use the code below:',
    );
  }

  static Future<int> getRemainingTime() async {
    if (_lastOtpTime == null) return 0;
    final left = _otpValidity - DateTime.now().difference(_lastOtpTime!);
    return left.isNegative ? 0 : left.inSeconds;
  }
}
