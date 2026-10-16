import 'package:flutter/foundation.dart';
import 'sync_service.dart';

/// 🔧 RECONSTRUCTED FILE: this file was found completely empty (0 bytes) in
/// the repository — `AdaptiveServiceManager` was referenced in main.dart but
/// never defined anywhere, causing `flutter analyze` to report it as an
/// undefined identifier at both call sites. I don't have the original,
/// possibly more elaborate version of this class (the comment above its
/// call site suggests it once "replaced individual service initialization"
/// for multiple background services), so this is a safe, minimal
/// reconstruction that does exactly what its two call sites need:
///   - `initialize()` — called once after the first frame in MyApp.initState
///   - `stopAllServices()` — called from MyApp.dispose()
/// If you have an older copy of this file with more responsibilities
/// (e.g. battery/network-aware polling), restore that instead of this stub.
class AdaptiveServiceManager {
  AdaptiveServiceManager._();
  static final AdaptiveServiceManager instance = AdaptiveServiceManager._();

  bool _initialized = false;
  bool _initializing = false;
  bool _stopRequested = false;

  Future<void> initialize() async {
    if (_initialized || _initializing) return;
    _initializing = true;
    _stopRequested = false;
    try {
      await SyncService.init();

      // The service starts its pulse timer before its initial network sync
      // completes. The root widget can be disposed during that await (tests,
      // hot restart, or teardown), so honour a stop request before declaring
      // the manager fully initialized.
      if (_stopRequested) {
        await SyncService.dispose();
        return;
      }

      _initialized = true;
      if (kDebugMode) debugPrint('✅ AdaptiveServiceManager: services started');
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ AdaptiveServiceManager.initialize failed: $e');
    } finally {
      _initializing = false;
    }
  }

  void stopAllServices() {
    _stopRequested = true;
    if (!_initialized && !_initializing) return;
    try {
      // Do not gate this on _initialized: SyncService.init() starts its timer
      // before awaiting network work, while this flag is set only afterwards.
      // Always cancel in-progress startup as early as possible.
      SyncService.dispose();
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ AdaptiveServiceManager.stopAllServices failed: $e');
    } finally {
      _initialized = false;
    }
  }
}