import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter/services.dart';
import 'package:notification_listener_service/notification_listener_service.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../commission_dashboard_page.dart';
import '../../retail_intelligence_page.dart';
import '../../bank_recon_page.dart';
import '../../payment_detection_service.dart';

/// Compact Quick Actions Widget.
///
/// Payment Detection is intentionally ALWAYS visible. Its availability state
/// must never remove the control from the dashboard: the owner needs a way to
/// inspect/enable/re-enable detection even after Android permissions change.
class CompactQuickActions extends StatefulWidget {
  const CompactQuickActions({super.key});

  @override
  State<CompactQuickActions> createState() => _CompactQuickActionsState();
}

class _CompactQuickActionsState extends State<CompactQuickActions>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _openPaymentDetectionControl() async {
    _triggerHapticFeedback();

    bool notificationAccess = false;
    bool smsAccess = false;
    try {
      notificationAccess = await NotificationListenerService.isPermissionGranted();
    } catch (_) {}
    try {
      smsAccess = (await Permission.sms.status).isGranted;
    } catch (_) {}

    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.notifications_active_rounded,
                        color: Color(0xFF4F46E5)),
                    const SizedBox(width: 10),
                    Text(
                      'Payment Detection',
                      style: GoogleFonts.poppins(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  notificationAccess && smsAccess
                      ? 'Enabled — payment detection can listen for supported payment notifications and SMS.'
                      : 'Not fully enabled. Turn on the missing Android permissions below.',
                  style: GoogleFonts.poppins(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 16),
                _statusRow('Notification access', notificationAccess),
                const SizedBox(height: 8),
                _statusRow('SMS permission', smsAccess),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.settings_rounded),
                    label: Text(
                      notificationAccess && smsAccess
                          ? 'Open Payment Detection Settings'
                          : 'Open Android App Settings',
                    ),
                    onPressed: () async {
                      Navigator.of(sheetContext).pop();
                      if (!(notificationAccess && smsAccess)) {
                        try {
                          await openAppSettings();
                        } catch (_) {}
                      } else {
                        try {
                          await PaymentDetectionService().ensureChannelsRunning();
                        } catch (_) {}
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _statusRow(String label, bool enabled) {
    return Row(
      children: [
        Icon(
          enabled ? Icons.check_circle_rounded : Icons.error_outline_rounded,
          size: 20,
          color: enabled ? const Color(0xFF10B981) : const Color(0xFFF59E0B),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        Text(
          enabled ? 'Enabled' : 'Needs setup',
          style: GoogleFonts.poppins(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: enabled ? const Color(0xFF059669) : const Color(0xFFD97706),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text(
              'Quick Actions',
              style: GoogleFonts.poppins(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade600,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                _buildQuickActionChip(
                  icon: Icons.fingerprint,
                  label: 'Biometric',
                  color: const Color(0xFF4F46E5),
                  onTap: () {
                    _triggerHapticFeedback();
                    Navigator.pushNamed(
                      context,
                      '/owner-biometric-register',
                      arguments: const {'fromDashboard': true},
                    );
                  },
                ),
                _buildQuickActionChip(
                  icon: Icons.psychology,
                  label: 'AI Hub',
                  color: const Color(0xFF7C3AED),
                  onTap: () {
                    _triggerHapticFeedback();
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const RetailIntelligencePage(),
                      ),
                    );
                  },
                ),
                _buildQuickActionChip(
                  icon: Icons.account_balance_wallet_rounded,
                  label: 'Reconcile',
                  color: const Color(0xFF0F766E),
                  onTap: () {
                    _triggerHapticFeedback();
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const BankReconPage(),
                      ),
                    );
                  },
                ),
                _buildQuickActionChip(
                  icon: Icons.notifications_active_rounded,
                  label: 'Payment',
                  color: const Color(0xFF059669),
                  onTap: _openPaymentDetectionControl,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                _buildQuickActionChip(
                  icon: Icons.attach_money,
                  label: 'Commission',
                  color: const Color(0xFF10B981),
                  onTap: () {
                    _triggerHapticFeedback();
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const CommissionDashboardPage(),
                      ),
                    );
                  },
                ),
                const Spacer(),
                const Spacer(),
                const Spacer(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActionChip({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        onTapDown: (_) => _controller.forward(),
        onTapUp: (_) {
          _controller.reverse();
          onTap();
        },
        onTapCancel: () => _controller.reverse(),
        child: ScaleTransition(
          scale: _scaleAnimation,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: color.withValues(alpha: 0.3),
              ),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.1),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: color, size: 18),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: GoogleFonts.poppins(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _triggerHapticFeedback() {
    HapticFeedback.lightImpact();
  }
}
