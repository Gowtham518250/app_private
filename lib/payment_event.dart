// =============================================================================
// payment_event.dart  –  V5 MERCHANT GRADE
// Immutable data model for every detected payment event.
// Fingerprint uses UTR as primary key; falls back to stable hash.
// =============================================================================

import 'dart:convert';
import 'package:crypto/crypto.dart';

enum PaymentApp {
  googlePay, phonePe, paytm, amazonPay, bhim, whatsappPay, cred, payzapp,
  icici, sbiYono, axis, hdfc, bankSms, bankApp, unknown,
}

enum PaymentDecision { confirmed, likely, rejected }

enum ConfidenceTier { high, medium, low, rejected }

class PaymentEvent {
  final double amount;
  final DateTime timestamp;
  final PaymentApp app;
  final String? payerName;
  final String? referenceId;
  final String? vpa;
  final String? accountSuffix;
  final String? bankName;
  final String id;
  final PaymentDecision decision;
  final bool isFailed;
  final bool isDuplicate;
  final bool isPartialPayment;
  final double remainingAmount;
  final String rawText;
  final double confidenceScore;
  final String detectionSource;
  final String? saleId;
  final int version;
  final DateTime updatedAt;

  PaymentEvent({
    required this.amount,
    required this.timestamp,
    required this.app,
    this.payerName,
    this.referenceId,
    this.vpa,
    this.accountSuffix,
    this.bankName,
    this.isFailed = false,
    this.isDuplicate = false,
    this.isPartialPayment = false,
    this.remainingAmount = 0.0,
    this.rawText = '',
    this.confidenceScore = 0.0,
    this.detectionSource = 'notification',
    this.saleId,
    this.version = 1,
    DateTime? updatedAt,
    String? id,
    this.decision = PaymentDecision.confirmed,
  }) : id = id ?? _genId(),
       updatedAt = updatedAt ?? DateTime.now();

  static String _genId() => 'pmt_${DateTime.now().microsecondsSinceEpoch}';

  /// Stable idempotency key.
  ///
  /// A UTR is authoritative when present. Without a UTR, notifications for
  /// the same transaction can come from different sources (UPI app, bank SMS,
  /// accessibility). The fallback therefore deliberately excludes source/app
  /// family and uses a short time bucket. This prevents the same payment from
  /// being counted once per source while still allowing a later same-amount
  /// payment to be accepted.
  String get fingerprint {
    final ref = referenceId?.trim();
    if (ref != null && ref.isNotEmpty) {
      return 'utr_${amount.toStringAsFixed(2)}_${ref.toUpperCase()}';
    }

    final utc = timestamp.toUtc();
    final bucket = utc.millisecondsSinceEpoch ~/ const Duration(minutes: 2).inMilliseconds;
    final normalizedPayer = (payerName ?? '').trim().toLowerCase();
    final normalizedVpa = (vpa ?? '').trim().toLowerCase();

    // Keep stable identity fields when available. Do not include raw text or
    // detectionSource: both vary between notification/SMS/accessibility copies.
    final payload = [
      amount.toStringAsFixed(2),
      bucket.toString(),
      normalizedPayer,
      normalizedVpa,
      (accountSuffix ?? '').trim().toLowerCase(),
    ].join('|');

    return 'hash_${sha256.convert(utf8.encode(payload)).toString()}';
  }

  ConfidenceTier get confidenceTier {
    if (confidenceScore >= 0.75) return ConfidenceTier.high;
    if (confidenceScore >= 0.50) return ConfidenceTier.medium;
    if (confidenceScore >= 0.35) return ConfidenceTier.low;
    return ConfidenceTier.rejected;
  }

  String get appDisplayName {
    const names = {
      PaymentApp.googlePay: 'Google Pay',
      PaymentApp.phonePe: 'PhonePe',
      PaymentApp.paytm: 'Paytm',
      PaymentApp.amazonPay: 'Amazon Pay',
      PaymentApp.whatsappPay: 'WhatsApp Pay',
      PaymentApp.bhim: 'BHIM UPI',
      PaymentApp.cred: 'CRED',
      PaymentApp.payzapp: 'PayZapp',
      PaymentApp.icici: 'ICICI iMobile',
      PaymentApp.sbiYono: 'SBI YONO',
      PaymentApp.axis: 'Axis Mobile',
      PaymentApp.hdfc: 'HDFC Bank',
      PaymentApp.bankSms: 'Bank SMS',
      PaymentApp.bankApp: 'Bank App',
    };
    return names[app] ?? 'UPI App';
  }

  String get amountDisplay =>
      amount % 1 == 0 ? '₹${amount.toInt()}' : '₹${amount.toStringAsFixed(2)}';

  PaymentEvent copyWith({
    double? amount,
    DateTime? timestamp,
    PaymentApp? app,
    String? payerName,
    String? referenceId,
    String? vpa,
    String? accountSuffix,
    String? bankName,
    bool? isFailed,
    bool? isDuplicate,
    bool? isPartialPayment,
    double? remainingAmount,
    String? rawText,
    double? confidenceScore,
    String? detectionSource,
    String? id,
    PaymentDecision? decision,
    String? saleId,
    int? version,
    DateTime? updatedAt,
  }) {
    return PaymentEvent(
      amount: amount ?? this.amount,
      timestamp: timestamp ?? this.timestamp,
      app: app ?? this.app,
      payerName: payerName ?? this.payerName,
      referenceId: referenceId ?? this.referenceId,
      vpa: vpa ?? this.vpa,
      accountSuffix: accountSuffix ?? this.accountSuffix,
      bankName: bankName ?? this.bankName,
      isFailed: isFailed ?? this.isFailed,
      isDuplicate: isDuplicate ?? this.isDuplicate,
      isPartialPayment: isPartialPayment ?? this.isPartialPayment,
      remainingAmount: remainingAmount ?? this.remainingAmount,
      rawText: rawText ?? this.rawText,
      confidenceScore: confidenceScore ?? this.confidenceScore,
      detectionSource: detectionSource ?? this.detectionSource,
      id: id ?? this.id,
      decision: decision ?? this.decision,
      saleId: saleId ?? this.saleId,
      version: version ?? this.version,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'amount': amount,
        'timestamp': timestamp.toIso8601String(),
        'app': app.name,
        'payerName': payerName,
        'referenceId': referenceId,
        'vpa': vpa,
        'accountSuffix': accountSuffix,
        'bankName': bankName,
        'isFailed': isFailed,
        'isDuplicate': isDuplicate,
        'isPartialPayment': isPartialPayment,
        'remainingAmount': remainingAmount,
        'confidenceScore': confidenceScore,
        'confidenceTier': confidenceTier.name,
        'detectionSource': detectionSource,
        'fingerprint': fingerprint,
        'decision': decision.name,
        'sale_id': saleId,
        'version': version,
        'updated_at': updatedAt.toIso8601String(),
      };

  factory PaymentEvent.fromJson(Map<String, dynamic> json) => PaymentEvent(
        id: json['id'],
        amount: (json['amount'] as num).toDouble(),
        timestamp: DateTime.parse(json['timestamp']),
        app: PaymentApp.values.firstWhere(
          (e) => e.name == json['app'],
          orElse: () => PaymentApp.unknown,
        ),
        payerName: json['payerName'],
        referenceId: json['referenceId'],
        vpa: json['vpa'],
        accountSuffix: json['accountSuffix'],
        bankName: json['bankName'],
        isFailed: json['isFailed'] ?? false,
        isDuplicate: json['isDuplicate'] ?? false,
        isPartialPayment: json['isPartialPayment'] ?? false,
        remainingAmount: (json['remainingAmount'] as num?)?.toDouble() ?? 0.0,
        rawText: json['rawText'] ?? '',
        confidenceScore: (json['confidenceScore'] as num?)?.toDouble() ?? 0.0,
        detectionSource: json['detectionSource'] ?? 'notification',
        decision: PaymentDecision.values.firstWhere(
          (e) => e.name == json['decision'],
          orElse: () => PaymentDecision.confirmed,
        ),
        saleId: json['sale_id'],
        version: json['version'] ?? 1,
        updatedAt: json['updated_at'] != null
            ? DateTime.parse(json['updated_at'])
            : null,
      );

  @override
  String toString() =>
      'PaymentEvent($amountDisplay via $appDisplayName'
      '${payerName != null ? " from $payerName" : ""}'
      '${referenceId != null ? " UTR:$referenceId" : ""}'
      ' conf:${(confidenceScore * 100).toStringAsFixed(0)}%)';
}

enum FraudVerdict {
  clean,
  softPenaltyStructure,
  softPenaltyUtr,
  softPenaltyVpa,
  hardBlockUnicode,
  hardBlockHtmlScript,
  hardBlockCyrillic,
  hardBlockFutureTense,
  hardBlockContradiction,
  hardBlockAmountCap,
  hardBlockSenderSpoofed,
  bankVerifyFailed,
}

class FraudAnalysis {
  final FraudVerdict verdict;
  final double riskScore;
  final String? reason;
  final bool isHardBlock;

  const FraudAnalysis({
    required this.verdict,
    required this.riskScore,
    this.reason,
    this.isHardBlock = false,
  });

  static const FraudAnalysis clean = FraudAnalysis(
    verdict: FraudVerdict.clean,
    riskScore: 0.0,
    reason: 'Payment looks legitimate',
    isHardBlock: false,
  );

  Map<String, dynamic> toJson() => {
        'verdict': verdict.name,
        'riskScore': riskScore,
        'reason': reason,
        'isHardBlock': isHardBlock,
      };
}
