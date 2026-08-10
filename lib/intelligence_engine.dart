// =============================================================================
// intelligence_engine.dart  —  V8 HUMAN-LIKE VOICE SYSTEM
// Analytics, anomaly detection, adaptive behavior, and voice queries.
//
// FEATURES
// ─────────
//  INTEL-1  Daily ledger: tracks total, count, per-hour buckets.
//  INTEL-2  Anomaly detection: large transaction, rapid-repeat pattern.
//  INTEL-3  Voice query responses: "How much today?", "How many payments?".
//  INTEL-4  Adaptive behavior flags: noisy environment → louder/clearer.
//  INTEL-5  Smart burst summarizer replaces simple count+total with
//           narrative like "5 payments, busiest since noon."
// =============================================================================

import 'language_engine.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Transaction record
// ─────────────────────────────────────────────────────────────────────────────

class TxRecord {
  final double       amount;
  final String?      payerName;
  final PaymentMethod method;
  final DateTime     time;
  final bool         isPartial;

  const TxRecord({
    required this.amount,
    this.payerName,
    required this.method,
    required this.time,
    this.isPartial = false,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Anomaly types
// ─────────────────────────────────────────────────────────────────────────────

enum AnomalyType {
  largeTx,
  rapidRepeat,
  firstOfDay,
  quietPeriodBroken,
}

class AnomalyEvent {
  final AnomalyType type;
  final TxRecord    tx;
  final String?     detail;
  const AnomalyEvent({required this.type, required this.tx, this.detail});
}

// ─────────────────────────────────────────────────────────────────────────────
// Daily ledger
// ─────────────────────────────────────────────────────────────────────────────

class DailyLedger {
  final DateTime      date;
  double              totalAmount   = 0.0;
  int                 txCount       = 0;
  final List<TxRecord> _records     = [];
  final List<int>     _hourBuckets  = List.filled(24, 0);

  DailyLedger(this.date);

  void record(TxRecord tx) {
    totalAmount += tx.amount;
    txCount++;
    _records.add(tx);
    _hourBuckets[tx.time.hour]++;
  }

  int get peakHour => _hourBuckets.indexOf(
      _hourBuckets.reduce((a, b) => a > b ? a : b));

  double get averageAmount =>
      txCount == 0 ? 0.0 : totalAmount / txCount;

  List<double> lastAmounts(int n) =>
      _records.reversed.take(n).map((r) => r.amount).toList();

  List<TxRecord> recentRecords(int minutes) {
    final cutoff = DateTime.now().subtract(Duration(minutes: minutes));
    return _records.where((r) => r.time.isAfter(cutoff)).toList();
  }

  DateTime? get lastTxTime =>
      _records.isEmpty ? null : _records.last.time;
}

// ─────────────────────────────────────────────────────────────────────────────
// IntelligenceEngine
// ─────────────────────────────────────────────────────────────────────────────

class IntelligenceEngine {
  DailyLedger _ledger = DailyLedger(DateTime.now());

  double _largeTxMultiplier   = 5.0;
  double _largeTxAbsolute     = 5000;
  int    _rapidRepeatWindow   = 120;
  int    _rapidRepeatMinCount = 5;

  bool isNoisyEnvironment = false;

  // ─ RUSH DETECTION (sentiment-aware tone feature)
  bool _isInRushMode = false;
  DateTime? _rushModeSetAt;
  final Duration _rushModeTimeout = const Duration(seconds: 20);
  final Duration _rushTapWindow = const Duration(seconds: 10);
  final int _rushTapThreshold = 2; // 2+ transactions in 10 sec = rush

  AnomalyEvent? recordTransaction(TxRecord tx) {
    _rolloverIfNewDay();
    _updateRushMode(); // Check if rush mode should expire
    final isFirst = _ledger.txCount == 0;
    _ledger.record(tx);
    _detectRush(tx); // Check if new transaction triggers rush mode

    if (isFirst) {
      return AnomalyEvent(type: AnomalyType.firstOfDay, tx: tx);
    }

    final last = _ledger.lastTxTime;
    if (last != null && tx.time.difference(last).inMinutes > 30) {
      return AnomalyEvent(
        type:   AnomalyType.quietPeriodBroken,
        tx:     tx,
        detail: '${tx.time.difference(last).inMinutes} minutes gap',
      );
    }

    if (_isRapidRepeat(tx)) {
      return AnomalyEvent(type: AnomalyType.rapidRepeat, tx: tx);
    }

    if (_isLargeTx(tx)) {
      return AnomalyEvent(
        type:   AnomalyType.largeTx,
        tx:     tx,
        detail: 'avg ₹${_ledger.averageAmount.toStringAsFixed(0)}',
      );
    }

    return null;
  }

  bool _isLargeTx(TxRecord tx) {
    if (tx.amount >= _largeTxAbsolute) return true;
    final avg = _ledger.averageAmount;
    return avg > 0 && tx.amount >= avg * _largeTxMultiplier;
  }

  bool _isRapidRepeat(TxRecord tx) {
    final recent = _ledger.recentRecords(_rapidRepeatWindow ~/ 60);
    final sameAmt = recent.where((r) => r.amount == tx.amount).length;
    return sameAmt >= _rapidRepeatMinCount;
  }

  void _rolloverIfNewDay() {
    final today = DateTime.now();
    if (today.day != _ledger.date.day ||
        today.month != _ledger.date.month) {
      _ledger = DailyLedger(today);
    }
  }

  String queryDailyTotal(String language) {
    _rolloverIfNewDay();
    final lang   = LanguageEngine().resolve(language);
    final total  = _ledger.totalAmount.toInt().toString();
    final count  = _ledger.txCount;
    return lang.dailySummary(total, count);
  }

  String queryPeakHour() {
    final h = _ledger.peakHour;
    final amPm = h >= 12 ? 'PM' : 'AM';
    final hour = h > 12 ? h - 12 : (h == 0 ? 12 : h);
    return 'Peak hour today: $hour $amPm';
  }

  double get adaptiveVolume => isNoisyEnvironment ? 1.0 : 1.0;

  double noiseAdjustedRate(double baseRate) =>
      isNoisyEnvironment ? (baseRate * 0.88).clamp(0.3, 1.0) : baseRate;

  String? smartBurstSummary({
    required int    count,
    required double total,
    required String language,
  }) {
    if (count < 3) return null;

    final lang      = LanguageEngine().resolve(language);
    final peakHour  = _ledger.peakHour;
    final nowHour   = DateTime.now().hour;
    final isPeak    = nowHour == peakHour;
    final totalStr  = total.toInt().toString();

    if (isPeak) {
      switch (lang.langKey) {
        case 'hi':  return '$count भुगतान एक साथ, ${nHi(totalStr)} रुपये';
        case 'ta':  return '$count பேமெண்ட் ஒரே நேரத்தில், ${nTa(totalStr)} மொத்தம்';
        case 'te':  return '$count పేమెంట్లు ఒకేసారి, ${nTe(totalStr)} మొత్తం';
        default:    return '$count payments together, $totalStr rupees total';
      }
    }

    return lang.burst(count, totalStr, VoiceStyle.normal);
  }

  void updateThresholds({
    double? largeTxMultiplier,
    double? largeTxAbsolute,
    int? rapidRepeatWindow,
    int? rapidRepeatMinCount,
  }) {
    if (largeTxMultiplier  != null) _largeTxMultiplier   = largeTxMultiplier;
    if (largeTxAbsolute    != null) _largeTxAbsolute     = largeTxAbsolute;
    if (rapidRepeatWindow  != null) _rapidRepeatWindow   = rapidRepeatWindow;
    if (rapidRepeatMinCount!= null) _rapidRepeatMinCount = rapidRepeatMinCount;
  }

  Map<String, dynamic> todaySnapshot() => {
    'date':         _ledger.date.toIso8601String().substring(0, 10),
    'totalAmount':  _ledger.totalAmount,
    'txCount':      _ledger.txCount,
    'averageAmount':_ledger.averageAmount,
    'peakHour':     _ledger.peakHour,
  };

  // ─ RUSH DETECTION IMPLEMENTATION

  void _detectRush(TxRecord tx) {
    // Count transactions in the last [_rushTapWindow]
    final recentTxs = _ledger.recentRecords(_rushTapWindow.inSeconds ~/ 60);
    
    if (recentTxs.length >= _rushTapThreshold) {
      _enterRushMode();
    }
  }

  void _enterRushMode() {
    _isInRushMode = true;
    _rushModeSetAt = DateTime.now();
  }

  void _updateRushMode() {
    if (!_isInRushMode) return;
    
    final elapsed = DateTime.now().difference(_rushModeSetAt!);
    if (elapsed > _rushModeTimeout) {
      _isInRushMode = false;
      _rushModeSetAt = null;
    }
  }

  bool get isRushMode {
    _updateRushMode();
    return _isInRushMode;
  }

  VoiceStyle getAdaptiveStyle(VoiceStyle baseStyle) {
    // Auto-escalate to fastShop if in rush mode
    if (isRushMode && baseStyle != VoiceStyle.alert) {
      return VoiceStyle.fastShop;
    }
    return baseStyle;
  }
}
