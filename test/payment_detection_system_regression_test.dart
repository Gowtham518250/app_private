import 'package:flutter_test/flutter_test.dart';
import 'package:retail_mind/payment_detection_system.dart';

void main() {
  group('Legacy payment notification parser regressions', () {
    test('currency amount wins over an earlier account or UTR number', () {
      expect(
        PaymentDetectionSystem.debugExtractNotificationAmount(
          'A/c 9876543210 credited Rs. 1,250.00',
        ),
        1250.0,
      );
    });

    test('parses Indian lakh grouped notification amount', () {
      expect(
        PaymentDetectionSystem.debugExtractNotificationAmount(
          'Payment received INR 1,25,000.00',
        ),
        125000.0,
      );
    });

    test('parses explicitly labelled amount without currency marker', () {
      expect(
        PaymentDetectionSystem.debugExtractNotificationAmount(
          'Amount credited: 12,345.67',
        ),
        12345.67,
      );
    });

    test('distinguishes money sent to the merchant from money sent to the user', () {
      expect(
        PaymentDetectionSystem.debugNotificationPaymentType('You sent ₹500 to Shop'),
        'PAID',
      );
      expect(
        PaymentDetectionSystem.debugNotificationPaymentType('Anita sent you ₹500'),
        'RECEIVED',
      );
      expect(
        PaymentDetectionSystem.debugNotificationPaymentType('₹500 credited to your account'),
        'RECEIVED',
      );
    });
  });
}
