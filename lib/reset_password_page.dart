import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_client.dart';
import 'app_localizations.dart';
import 'dart:convert';
import 'email_sender_service.dart';

class ResetPasswordPage extends StatefulWidget {
  const ResetPasswordPage({super.key});

  @override
  State<ResetPasswordPage> createState() => _ResetPasswordPageState();
}

class _ResetPasswordPageState extends State<ResetPasswordPage> {
  final TextEditingController emailController = TextEditingController();
  final TextEditingController otpController = TextEditingController();
  final TextEditingController newPasswordController = TextEditingController();
  final TextEditingController confirmPasswordController = TextEditingController();

  bool isLoading = false;
  bool otpSent = false;
  bool showPassword = false;
  String errorMessage = '';
  String successMessage = '';

  @override
  void dispose() {
    emailController.dispose();
    otpController.dispose();
    newPasswordController.dispose();
    confirmPasswordController.dispose();
    super.dispose();
  }

  /// Step 1: Request password reset OTP to email
  Future<void> sendResetOTP() async {
    if (emailController.text.isEmpty) {
      setState(() => errorMessage = 'Please enter email');
      return;
    }

    setState(() {
      isLoading = true;
      errorMessage = '';
      successMessage = '';
    });

    try {
      final response = await ApiClient.postJson(
        '/auth/forgot-password',
        {'email': emailController.text.trim()},
      );

      if (response.statusCode == 200) {
        // Extract OTP from response
        final responseData = json.decode(response.body);
        final otp = responseData['otp']?.toString() ?? '';
        
        // 🔐 Do NOT print or display OTP - send it ONLY to email
        // Send OTP via email using Frontend
        if (otp.isNotEmpty) {
          final emailSent = await EmailSenderService.sendOTPEmail(
            recipientEmail: emailController.text.trim(),
            otp: otp,
            userName: 'User',
          );

          if (emailSent) {
            setState(() {
              otpSent = true;
              successMessage = '✅ OTP sent to ${emailController.text.trim()}. Check inbox/spam.';
              isLoading = false;
            });
          } else {
            setState(() {
              successMessage = '⚠️ OTP generated but email failed. Check console.';
              otpSent = true;
              isLoading = false;
            });
          }
        }
      } else if (response.statusCode == 404) {
        setState(() {
          errorMessage = '❌ Email not found. Please register first.';
          isLoading = false;
        });
      } else {
        setState(() {
          errorMessage = '❌ Failed to send OTP. Try again.';
          isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        errorMessage = '❌ Error: $e';
        isLoading = false;
      });
    }
  }

  /// Step 2: Verify OTP and reset password
  Future<void> resetPassword() async {
    String email = emailController.text.trim();
    String otp = otpController.text.trim();
    String newPass = newPasswordController.text;
    String confirmPass = confirmPasswordController.text;

    if (email.isEmpty || otp.isEmpty || newPass.isEmpty || confirmPass.isEmpty) {
      setState(() => errorMessage = 'All fields are required');
      return;
    }

    if (newPass != confirmPass) {
      setState(() => errorMessage = '❌ Passwords do not match');
      return;
    }

    if (newPass.length < 6) {
      setState(() => errorMessage = '❌ Password must be at least 6 characters');
      return;
    }

    setState(() {
      isLoading = true;
      errorMessage = '';
      successMessage = '';
    });

    try {
      final response = await ApiClient.postJson(
        '/auth/reset-password',
        {
          'email': email,
          'otp': otp,
          'new_password': newPass,
        },
      );

      if (response.statusCode == 200) {
        setState(() => successMessage = '✅ Password reset successful! Redirecting to login...');
        
        // Wait 2 seconds then redirect to login
        await Future.delayed(const Duration(seconds: 2));
        if (mounted) {
          Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
        }
      } else if (response.statusCode == 400) {
        setState(() => errorMessage = '❌ Invalid OTP or expired. Request a new one.');
      } else {
        setState(() => errorMessage = '❌ Password reset failed. Try again.');
      }
    } catch (e) {
      setState(() => errorMessage = '❌ Error: $e');
    } finally {
      if (mounted) {
        setState(() => isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reset Password'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            const SizedBox(height: 20),
            Text(
              'Forgot Password?',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Enter your email to receive a password reset code',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),

            // Error Message
            if (errorMessage.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 16.0),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
                    border: Border.all(color: Colors.red),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    errorMessage,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              ),

            // Success Message
            if (successMessage.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 16.0),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.1),
                    border: Border.all(color: Colors.green),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    successMessage,
                    style: const TextStyle(color: Colors.green),
                  ),
                ),
              ),

            // Step 1: Email Input
            if (!otpSent) ...[
              TextField(
                controller: emailController,
                decoration: InputDecoration(
                  labelText: 'Email Address',
                  prefixIcon: const Icon(Icons.email),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  enabled: !isLoading,
                ),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: isLoading ? null : sendResetOTP,
                icon: const Icon(Icons.send),
                label: isLoading ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ) : const Text('Send Reset Code'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ],

            // Step 2: OTP & Password Reset
            if (otpSent) ...[
              // Email display (read-only)
              TextField(
                controller: emailController,
                decoration: InputDecoration(
                  labelText: 'Email Address',
                  prefixIcon: const Icon(Icons.email),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  enabled: false,
                ),
                readOnly: true,
              ),
              const SizedBox(height: 16),

              // OTP Input
              TextField(
                controller: otpController,
                decoration: InputDecoration(
                  labelText: 'Enter Reset Code (OTP)',
                  prefixIcon: const Icon(Icons.code),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  enabled: !isLoading,
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 16),

              // New Password
              TextField(
                controller: newPasswordController,
                obscureText: !showPassword,
                decoration: InputDecoration(
                  labelText: 'New Password',
                  prefixIcon: const Icon(Icons.lock),
                  suffixIcon: IconButton(
                    icon: Icon(showPassword ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => showPassword = !showPassword),
                  ),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  enabled: !isLoading,
                ),
              ),
              const SizedBox(height: 16),

              // Confirm Password
              TextField(
                controller: confirmPasswordController,
                obscureText: !showPassword,
                decoration: InputDecoration(
                  labelText: 'Confirm Password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(showPassword ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => showPassword = !showPassword),
                  ),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  enabled: !isLoading,
                ),
              ),
              const SizedBox(height: 24),

              // Reset Button
              ElevatedButton.icon(
                onPressed: isLoading ? null : resetPassword,
                icon: isLoading ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ) : const Icon(Icons.check),
                label: const Text('Reset Password'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
              const SizedBox(height: 12),

              // Request new OTP
              TextButton(
                onPressed: isLoading ? null : () => setState(() {
                  otpSent = false;
                  otpController.clear();
                  newPasswordController.clear();
                  confirmPasswordController.clear();
                  errorMessage = '';
                  successMessage = '';
                }),
                child: const Text('Request a new code?'),
              ),
            ],

            const SizedBox(height: 32),

            // Back to Login
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Back to Login'),
            ),
          ],
        ),
      ),
    );
  }
}
