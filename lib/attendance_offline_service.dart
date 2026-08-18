import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_client.dart';
import 'sync_queue_manager.dart';

/// Durable local-first attendance operations.
/// A worker can have only one attendance record per business day.
/// Local state is used immediately, while the durable outbox synchronizes it
/// with the backend when connectivity/authentication is available.
class OfflineAttendanceService {
  static const String _prefix = 'attendance_local_v2_';

  static Future<int?> _userId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('user_id') ?? prefs.getInt('userId');
  }

  static String _date(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

  static String _identity(Map<String, dynamic> record, int fallbackUserId) {
    final employeeId = record['employee_id']?.toString().trim() ?? '';
    final workerId = record['worker_id']?.toString().trim() ?? '';
    if (employeeId.isNotEmpty) return 'employee:$employeeId';
    if (workerId.isNotEmpty) return 'worker:$workerId';
    return 'user:$fallbackUserId';
  }

  static String _recordKey(Map<String, dynamic> record, int fallbackUserId) {
    final date = (record['attendance_date']?.toString() ?? '').split('T').first;
    return '${_identity(record, fallbackUserId)}:$date';
  }

  static Future<String> _key(int userId) async => '$_prefix$userId';

  static Future<List<Map<String, dynamic>>> loadLocalRecords() async {
    final uid = await _userId();
    if (uid == null || uid <= 0) return <Map<String, dynamic>>[];
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(await _key(uid));
    if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Map<String, dynamic>>[];
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<void> _saveRecords(List<Map<String, dynamic>> records) async {
    final uid = await _userId();
    if (uid == null || uid <= 0) return;
    final prefs = await SharedPreferences.getInstance();
    final dedup = <String, Map<String, dynamic>>{};
    for (final record in records) {
      final key = _recordKey(record, uid);
      if (key.endsWith(':')) continue;
      dedup[key] = Map<String, dynamic>.from(record);
    }
    await prefs.setString(await _key(uid), jsonEncode(dedup.values.toList()));
  }

  static Future<Map<String, dynamic>?> _findTodayRecord({
    required int employeeId,
    int? workerId,
    required String date,
  }) async {
    final records = await loadLocalRecords();
    for (final record in records) {
      final sameEmployee =
          (record['employee_id']?.toString() ?? '') == employeeId.toString();
      final sameWorker =
          (record['worker_id']?.toString() ?? '') == (workerId?.toString() ?? '');
      final sameDate =
          (record['attendance_date']?.toString() ?? '').split('T').first == date;
      if (sameEmployee && sameWorker && sameDate) {
        return Map<String, dynamic>.from(record);
      }
    }
    return null;
  }

  static Future<void> _upsertLocal({
    required int employeeId,
    int? workerId,
    required String date,
    DateTime? checkIn,
    DateTime? checkOut,
    String? status,
    double? workingHours,
  }) async {
    final records = await loadLocalRecords();
    final index = records.indexWhere((record) {
      final sameEmployee =
          (record['employee_id']?.toString() ?? '') == employeeId.toString();
      final sameWorker =
          (record['worker_id']?.toString() ?? '') == (workerId?.toString() ?? '');
      final sameDate =
          (record['attendance_date']?.toString() ?? '').split('T').first == date;
      return sameEmployee && sameWorker && sameDate;
    });

    final existing = index >= 0
        ? Map<String, dynamic>.from(records[index])
        : <String, dynamic>{};

    final merged = <String, dynamic>{
      ...existing,
      'employee_id': employeeId,
      if (workerId != null) 'worker_id': workerId,
      'attendance_date': date,
      if (checkIn != null) 'check_in_time': checkIn.toUtc().toIso8601String(),
      if (checkOut != null) 'check_out_time': checkOut.toUtc().toIso8601String(),
      if (status != null) 'status': status.toUpperCase(),
      if (workingHours != null) 'working_hours': workingHours,
      'local_pending': true,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };

    if (index >= 0) {
      records[index] = merged;
    } else {
      records.add(merged);
    }
    await _saveRecords(records);
  }

  /// Idempotent daily check-in. Repeated taps/retries on the same day do not
  /// enqueue another check-in once a check-in timestamp already exists.
  static Future<bool> checkIn({required int employeeId, int? workerId}) async {
    final now = DateTime.now();
    final date = _date(now);
    final existing = await _findTodayRecord(
      employeeId: employeeId,
      workerId: workerId,
      date: date,
    );

    if (existing != null && existing['check_in_time'] != null) {
      // If a check-out exists, this is already a completed attendance day and
      // must never be reopened by an accidental second Check-In tap.
      return true;
    }

    final operationId = 'ATT_IN_${workerId ?? employeeId}_$date';
    await _upsertLocal(
      employeeId: employeeId,
      workerId: workerId,
      date: date,
      checkIn: now,
      status: 'PRESENT',
    );

    final queued = await SyncQueueManager.enqueue('attendance_check_in', {
      'operation_id': operationId,
      'idempotency_key': operationId,
      'employee_id': employeeId,
      'worker_id': workerId,
      'attendance_date': date,
    });

    if (!queued) {
      throw StateError('Unable to persist attendance check-in to durable outbox');
    }
    return true;
  }

  /// Idempotent daily check-out. Repeated taps cannot create additional
  /// checkout operations for the same worker/date.
  static Future<bool> checkOut({required int employeeId, int? workerId}) async {
    final now = DateTime.now();
    final date = _date(now);
    final existing = await _findTodayRecord(
      employeeId: employeeId,
      workerId: workerId,
      date: date,
    );

    if (existing != null && existing['check_out_time'] != null) return true;

    DateTime? checkIn;
    final rawCheckIn = existing?['check_in_time'];
    if (rawCheckIn != null) checkIn = DateTime.tryParse(rawCheckIn.toString());
    final workingHours = checkIn == null
        ? null
        : now.difference(checkIn.toLocal()).inSeconds / 3600.0;
    final operationId = 'ATT_OUT_${workerId ?? employeeId}_$date';

    await _upsertLocal(
      employeeId: employeeId,
      workerId: workerId,
      date: date,
      checkOut: now,
      workingHours: workingHours,
      status: 'PRESENT',
    );

    final queued = await SyncQueueManager.enqueue('attendance_check_out', {
      'operation_id': operationId,
      'idempotency_key': operationId,
      'employee_id': employeeId,
      'worker_id': workerId,
      'attendance_date': date,
    });

    if (!queued) {
      throw StateError('Unable to persist attendance check-out to durable outbox');
    }
    return true;
  }

  /// Merge remote records. A matching remote record is considered the source
  /// of truth after successful synchronization, so a stale local_pending flag
  /// is cleared instead of permanently overriding backend state.
  static Future<void> mergeRemoteRecords(
    List<Map<String, dynamic>> remoteRecords,
  ) async {
    if (remoteRecords.isEmpty) return;
    try {
      final uid = await _userId();
      if (uid == null || uid <= 0) return;
      final local = await loadLocalRecords();
      final merged = <String, Map<String, dynamic>>{};

      for (final record in [...local, ...remoteRecords]) {
        final key = _recordKey(record, uid);
        if (key.endsWith(':')) continue;
        final previous = merged[key];
        if (previous == null) {
          merged[key] = Map<String, dynamic>.from(record);
          continue;
        }

        final isRemote = remoteRecords.any((remote) =>
            _recordKey(remote, uid) == key && identical(remote, record));
        if (isRemote) {
          merged[key] = {
            ...previous,
            ...Map<String, dynamic>.from(record),
            'local_pending': false,
            'synced_at': DateTime.now().toUtc().toIso8601String(),
          };
        } else if (previous['local_pending'] == true) {
          merged[key] = {
            ...Map<String, dynamic>.from(record),
            ...previous,
            'local_pending': true,
          };
        } else {
          merged[key] = {
            ...previous,
            ...Map<String, dynamic>.from(record),
          };
        }
      }

      await _saveRecords(merged.values.toList());
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ Failed to cache remote attendance history: $e');
      }
    }
  }

  /// Reconcile today's local state against the backend. A server record for
  /// the same worker/date clears local_pending because the durable operation
  /// has reached the authoritative backend.
  static Future<void> reconcileFromBackend() async {
    final uid = await _userId();
    if (uid == null || uid <= 0) return;
    try {
      final date = _date(DateTime.now());
      final response = await ApiClient.getJson(
        '${ApiClient.attendancePrefix}/date/$date',
      );
      if (response.statusCode != 200) return;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map || decoded['records'] is! List) return;

      final remote = (decoded['records'] as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      if (remote.isEmpty) return;

      final local = await loadLocalRecords();
      final merged = <String, Map<String, dynamic>>{};

      for (final record in local) {
        merged[_recordKey(record, uid)] = Map<String, dynamic>.from(record);
      }

      for (final serverRecord in remote) {
        final key = _recordKey(serverRecord, uid);
        final previous = merged[key];
        if (previous == null) {
          merged[key] = {
            ...serverRecord,
            'local_pending': false,
          };
        } else {
          merged[key] = {
            ...previous,
            ...serverRecord,
            'local_pending': false,
            'synced_at': DateTime.now().toUtc().toIso8601String(),
          };
        }
      }

      await _saveRecords(merged.values.toList());
    } catch (e) {
      if (kDebugMode) {
        debugPrint('OfflineAttendance reconcile skipped: $e');
      }
    }
  }

  static Future<void> markSynced({
    required int employeeId,
    int? workerId,
    required String date,
  }) async {
    final records = await loadLocalRecords();
    for (int i = 0; i < records.length; i++) {
      final record = records[i];
      if ((record['employee_id']?.toString() ?? '') == employeeId.toString() &&
          (record['worker_id']?.toString() ?? '') == (workerId?.toString() ?? '') &&
          (record['attendance_date']?.toString().split('T').first ?? '') == date) {
        records[i] = {
          ...record,
          'local_pending': false,
          'synced_at': DateTime.now().toUtc().toIso8601String(),
        };
        await _saveRecords(records);
        return;
      }
    }
  }
}
