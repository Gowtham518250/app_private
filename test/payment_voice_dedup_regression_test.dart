import 'package:flutter_test/flutter_test.dart';
import 'package:retail_mind/payment_detection_service.dart';
import 'package:retail_mind/payment_event.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the voice queue only speaks a duplicate payment fingerprint once', () async {
    PdsConfig.isVoiceEnabled = true;
    final spoken = <String>[];
    final queue = PriorityVoiceQueue();
    queue.getLanguage = () => VoiceLanguage.english;
    queue.onSpeak = spoken.add;

    final detectedAt = DateTime(2026, 10, 16, 12, 30);
    final event = PaymentEvent(
      amount: 500,
      timestamp: detectedAt,
      app: PaymentApp.phonePe,
      referenceId: 'UTR987654321',
      rawText: 'Ravi sent ₹500',
      decision: PaymentDecision.likely,
    );
    final ui = PaymentUiState(
      id: event.id,
      decision: event.decision,
      amount: event.amount,
      isFailed: false,
      detectedAt: detectedAt,
    );

    queue.enqueue(event, ui);
    queue.enqueue(event, ui); // Same event, duplicated source notification.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    queue.dispose();

    expect(spoken, hasLength(1));
  });
}
