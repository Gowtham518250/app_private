import 'package:flutter_test/flutter_test.dart';
import 'package:retail_mind/payment_detection_service.dart';

void main() {
  group('Payment amount normalization regressions', () {
    test('parses Indian lakh-grouped amount', () {
      expect(
        PaymentDetectionService.debugExtractAmount(
          'INR 1,25,000.00 credited to your account',
        ),
        125000.00,
      );
    });

    test('parses Western comma-grouped amount', () {
      expect(
        PaymentDetectionService.debugExtractAmount(
          '₹1,250.00 received in your account',
        ),
        1250.00,
      );
    });

    test('parses amount after credit wording without currency symbol', () {
      expect(
        PaymentDetectionService.debugExtractAmount(
          'Amount credited 12,345.67 to your account',
        ),
        12345.67,
      );
    });

    test('does not classify a debit as an incoming credit', () {
      expect(
        PaymentDetectionService.debugClassify('Rs. 1,250 spent at AMAZON'),
        'debit',
      );
    });

    test('keeps a genuine credit message in the payment pipeline', () {
      expect(
        PaymentDetectionService.debugClassify(
          'INR 1,25,000.00 credited to your account',
        ),
        'passed',
      );
      expect(
        PaymentDetectionService.debugHasIncomingCreditContext(
          'Received INR 1,25,000.00 in your account',
        ),
        isTrue,
      );
      expect(
        PaymentDetectionService.debugHasIncomingCreditContext(
          'Your payment is pending; please pay Rs. 1,250',
        ),
        isFalse,
      );
    });
  });
}
