import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'dart:convert';
import 'api_client.dart';
import 'app_localizations.dart';
import 'package:provider/provider.dart';
import 'language_provider.dart';
import 'otp_service.dart';

class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage>
    with TickerProviderStateMixin {
  final _emailController = TextEditingController();
  final _otpController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _isLoading = false;
  int _currentStep = 1; // 1: Email, 2: OTP, 3: New Password
  String _errorMessage = '';

  late AnimationController _bgController;
  late AnimationController _glowController;
  late Animation<double> _glowAnim;
  late AnimationController _gradientController;
  late Animation<Color?> _c1, _c2;

  @override
  void initState() {
    super.initState();
    _bgController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();

    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _glowAnim = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut),
    );

    _gradientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat(reverse: true);
    _c1 = ColorTween(
      begin: const Color(0xFF6366F1),
      end: const Color(0xFF8B5CF6),
    ).animate(_gradientController);
    _c2 = ColorTween(
      begin: const Color(0xFF8B5CF6),
      end: const Color(0xFF10B981),
    ).animate(_gradientController);
  }

  @override
  void dispose() {
    _bgController.dispose();
    _glowController.dispose();
    _gradientController.dispose();
    _emailController.dispose();
    _otpController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _sendResetEmail() async {
    final email = _emailController.text.trim();
    if (email.isEmpty ||
        !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      setState(() => _errorMessage = AppLocalizations.of(context).enterEmail);
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final result = await OTPService.sendOTPToEmail(email);
      if (result['success'] == true) {
        setState(() {
          _currentStep = 2;
          _errorMessage = '';
        });
      } else {
        setState(() => _errorMessage = result['message']?.toString() ?? 'Unable to send reset code');
      }
    } catch (e) {
      setState(() => _errorMessage = AppLocalizations.of(context).connectionError);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _verifyOtp() async {
    final otp = _otpController.text.trim();
    if (otp.length < 6) {
      setState(() => _errorMessage = 'Please enter a valid 6-digit OTP');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final result = await OTPService.verifyOTP(_emailController.text.trim(), otp);
      if (result['success'] == true) {
        setState(() => _currentStep = 3);
      } else {
        setState(() => _errorMessage = result['message']?.toString() ?? 'Invalid OTP');
      }
    } catch (_) {
      setState(() => _errorMessage = AppLocalizations.of(context).connectionError);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _resetPassword() async {
    final pass = _passwordController.text.trim();
    final confirm = _confirmPasswordController.text.trim();

    if (pass.isEmpty || pass.length < 6) {
      setState(() => _errorMessage = 'Password must be at least 6 characters');
      return;
    }
    if (pass != confirm) {
      setState(() => _errorMessage = 'Passwords do not match');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final response = await ApiClient.postForm('/auth/reset-password', {
        'email': _emailController.text.trim(),
        'otp': _otpController.text.trim(),
        'new_password': pass,
      });
      if (response.statusCode == 200) {
        setState(() => _currentStep = 4); // Success stage
      } else {
        final data = json.decode(response.body);
        setState(() => _errorMessage = data['detail']?.toString() ?? 'Reset failed');
      }
    } catch (_) {
      setState(() => _errorMessage = AppLocalizations.of(context).connectionError);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedBuilder(
        animation: _bgController,
        builder: (context, _) {
          return Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.topLeft,
                radius: 1.8,
                colors: [
                  const Color(0xFF0D0B2B),
                  const Color(0xFF12071F),
                  const Color(0xFF060D1F),
                ],
              ),
            ),
            child: Stack(
              children: [
                // Animated ambient orbs
                Positioned(
                  top: -80,
                  right: -80,
                  child: AnimatedBuilder(
                    animation: _glowAnim,
                    builder: (_, __) => Container(
                      width: 280,
                      height: 280,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF6366F1)
                                .withValues(alpha: 0.18 * _glowAnim.value),
                            blurRadius: 120,
                            spreadRadius: 60,
                          )
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  bottom: -60,
                  left: -60,
                  child: AnimatedBuilder(
                    animation: _glowAnim,
                    builder: (_, __) => Container(
                      width: 220,
                      height: 220,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF8B5CF6)
                                .withValues(alpha: 0.15 * _glowAnim.value),
                            blurRadius: 100,
                            spreadRadius: 50,
                          )
                        ],
                      ),
                    ),
                  ),
                ),

                // Back button + language selector
                Positioned(
                  top: 52,
                  left: 20,
                  right: 20,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Back
                      GestureDetector(
                        onTap: () => Navigator.of(context).pop(),
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.18),
                              width: 1,
                            ),
                            gradient: LinearGradient(
                              colors: [
                                Colors.white.withValues(alpha: 0.1),
                                Colors.white.withValues(alpha: 0.04),
                              ],
                            ),
                          ),
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                            child: Icon(
                              Icons.arrow_back_ios_new_rounded,
                              color: Colors.white.withValues(alpha: 0.85),
                              size: 18,
                            ),
                          ),
                        ),
                      ),
                      // Highlighted language button
                      _ResetLanguageButton(),
                    ],
                  ),
                ),

                // Main content
                Center(
                  child: SingleChildScrollView(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 24, vertical: 90),
                    child: _buildStageContent(),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildStageContent() {
    switch (_currentStep) {
      case 2:
        return _buildOtpState();
      case 3:
        return _buildNewPasswordState();
      case 4:
        return _buildSuccessState();
      case 1:
      default:
        return _buildEmailState();
    }
  }

  Widget _buildSuccessState() {
    return Column(
      children: [
        Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              colors: [Color(0xFF00C48C), Color(0xFF00E5A0)],
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF00C48C).withValues(alpha: 0.4),
                blurRadius: 40,
                spreadRadius: 8,
              )
            ],
          ),
          child: const Icon(Icons.check_circle_outline_rounded,
              color: Colors.white, size: 48),
        ),
        const SizedBox(height: 28),
        Text(
          'Password Reset!',
          style: GoogleFonts.poppins(
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Your password has been updated successfully. You can now login with your new password.',
          textAlign: TextAlign.center,
          style: GoogleFonts.poppins(
            fontSize: 14,
            color: Colors.white.withValues(alpha: 0.55),
            height: 1.6,
          ),
        ),
        const SizedBox(height: 40),
        GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: AnimatedBuilder(
            animation: _gradientController,
            builder: (context, _) => Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: LinearGradient(
                    colors: [_c1.value!, _c2.value!]),
                boxShadow: [
                  BoxShadow(
                    color: _c1.value!.withValues(alpha: 0.4),
                    blurRadius: 25,
                    spreadRadius: 2,
                    offset: const Offset(0, 8),
                  )
                ],
              ),
              child: Text(
                AppLocalizations.of(context).login,
                style: GoogleFonts.poppins(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(String title, String subtitle, IconData icon) {
    return Column(
      children: [
        AnimatedBuilder(
          animation: _glowAnim,
          builder: (_, __) => Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF6366F1).withValues(alpha: 0.45 * _glowAnim.value),
                  blurRadius: 35,
                  spreadRadius: 6,
                )
              ],
            ),
            child: Icon(icon, color: Colors.white, size: 42),
          ),
        ),
        const SizedBox(height: 28),
        Text(
          title,
          textAlign: TextAlign.center,
          style: GoogleFonts.poppins(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            color: Colors.white,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: GoogleFonts.poppins(
            fontSize: 13.5,
            color: Colors.white.withValues(alpha: 0.5),
            height: 1.6,
          ),
        ),
        const SizedBox(height: 30),
      ],
    );
  }

  Widget _buildError() {
    if (_errorMessage.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: Colors.red.withValues(alpha: 0.12),
          border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _errorMessage,
                style: GoogleFonts.poppins(
                  color: Colors.red.shade300,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmailState() {
    return Column(
      children: [
        _buildHeader(
          AppLocalizations.of(context).forgotPassword,
          AppLocalizations.of(context).enterCredentials,
          Icons.lock_reset_rounded,
        ),
        _buildError(),
        _buildInputField(
          controller: _emailController,
          hint: AppLocalizations.of(context).enterEmail,
          icon: Icons.email_outlined,
          type: TextInputType.emailAddress,
        ),
        const SizedBox(height: 28),
        _buildSubmitButton(
          label: 'SEND CODE',
          onTap: _sendResetEmail,
        ),
        const SizedBox(height: 22),
        GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: Text(
            AppLocalizations.of(context).signIn,
            style: GoogleFonts.poppins(
              color: const Color(0xFF818CF8),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOtpState() {
    return Column(
      children: [
        _buildHeader(
          'Verify Email',
          'Enter the 6-digit code sent to\n${_emailController.text}',
          Icons.mark_email_unread_rounded,
        ),

        _buildError(),
        _buildInputField(
          controller: _otpController,
          hint: 'Enter 6-digit OTP',
          icon: Icons.pin_rounded,
          type: TextInputType.number,
        ),
        const SizedBox(height: 28),
        _buildSubmitButton(
          label: 'VERIFY CODE',
          onTap: _verifyOtp,
        ),
        const SizedBox(height: 22),
        TextButton(
          onPressed: () => setState(() => _currentStep = 1),
          child: Text(
            'Change Email',
            style: GoogleFonts.poppins(
              color: const Color(0xFF818CF8),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNewPasswordState() {
    return Column(
      children: [
        _buildHeader(
          'New Password',
          'Create a strong password for your shop account',
          Icons.vpn_key_rounded,
        ),
        _buildError(),
        _buildInputField(
          controller: _passwordController,
          hint: 'New Password',
          icon: Icons.lock_outline_rounded,
          isPassword: true,
        ),
        const SizedBox(height: 16),
        _buildInputField(
          controller: _confirmPasswordController,
          hint: 'Confirm Password',
          icon: Icons.lock_clock_outlined,
          isPassword: true,
        ),
        const SizedBox(height: 28),
        _buildSubmitButton(
          label: 'RESET PASSWORD',
          onTap: _resetPassword,
        ),
      ],
    );
  }

  Widget _buildInputField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    TextInputType type = TextInputType.text,
    bool isPassword = false,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              colors: [
                Colors.white.withValues(alpha: 0.13),
                Colors.white.withValues(alpha: 0.05),
              ],
            ),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.12),
              width: 1,
            ),
          ),
          child: TextField(
            controller: controller,
            keyboardType: type,
            obscureText: isPassword,
            style: GoogleFonts.poppins(
              color: Colors.white,
              fontSize: 14,
            ),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: GoogleFonts.poppins(
                color: Colors.white.withValues(alpha: 0.38),
                fontSize: 14,
              ),
              prefixIcon: Icon(
                icon,
                color: const Color(0xFF6366F1).withValues(alpha: 0.8),
                size: 22,
              ),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20, vertical: 18),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSubmitButton({required String label, required VoidCallback onTap}) {
    return AnimatedBuilder(
      animation: _gradientController,
      builder: (context, _) => GestureDetector(
        onTap: _isLoading ? null : onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 17),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
                colors: [_c1.value!, _c2.value!]),
            boxShadow: [
              BoxShadow(
                color: _c1.value!.withValues(alpha: 0.45),
                blurRadius: 25,
                spreadRadius: 2,
                offset: const Offset(0, 8),
              )
            ],
          ),
          child: Center(
            child: _isLoading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : Text(
                    label,
                    style: GoogleFonts.poppins(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      letterSpacing: 2,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _ResetLanguageButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final languageProvider = Provider.of<LanguageProvider>(context);
    final currentCode = languageProvider.locale.languageCode;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.25),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: PopupMenuButton<String>(
        color: const Color(0xFF0F172A),
        onSelected: (code) => languageProvider.setLanguage(code),
        itemBuilder: (context) => LanguageProvider.languages
            .map(
              (lang) => PopupMenuItem<String>(
                value: lang['code']!,
                child: Row(
                  children: [
                    Text(
                      lang['nativeName']!,
                      style: const TextStyle(color: Colors.white),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      lang['name']!,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
                    ),
                    const Spacer(),
                    if (lang['code'] == currentCode)
                      const Icon(Icons.check,
                          size: 16, color: Colors.white70),
                  ],
                ),
              ),
            )
            .toList(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.language_rounded,
                  size: 18, color: Colors.white),
              const SizedBox(width: 6),
              Text(
                AppLocalizations.of(context).language,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 2),
              Icon(Icons.arrow_drop_down,
                  size: 18, color: Colors.white.withValues(alpha: 0.7)),
            ],
          ),
        ),
      ),
    );
  }
}
