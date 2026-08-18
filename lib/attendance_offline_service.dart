import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_client.dart';
import 'sync_queue_manager.dart';

/// Durable local-first attendance operations.
///
/// A worker can have MULTIPLE attendance sessions on the same business day
/// (e.g. check in for a morning shift, check out for lunch, check in again
/// after lunch, and so on). Each session is stored under its own
/// `session_index` (0, 1, 2, ...) so that closing one session never blocks
/// starting a new one on the same date.
class OfflineAttendanceService {
  static const String _prefix = 'attendance_local_v2_';
  static Future<int?> _userId() async { final p=await SharedPreferences.getInstance(); return p.getInt('user_id') ?? p.getInt('userId'); }
  static String _date(DateTime v) => '${v.year.toString().padLeft(4,'0')}-${v.month.toString().padLeft(2,'0')}-${v.day.toString().padLeft(2,'0')}';
  static String _identity(Map<String,dynamic> r,int uid){final e=r['employee_id']?.toString().trim()??'';final w=r['worker_id']?.toString().trim()??'';if(e.isNotEmpty)return 'employee:$e';if(w.isNotEmpty)return 'worker:$w';return 'user:$uid';}
  static int _sessionIndexOf(Map<String,dynamic> r){final raw=r['session_index'];if(raw is int)return raw;if(raw!=null)return int.tryParse(raw.toString())??0;return 0;}
  // NOTE: the key now includes a session index so multiple check-in/out
  // pairs on the same date are stored as separate records instead of
  // overwriting each other.
  static String _recordKey(Map<String,dynamic> r,int uid)=>'${_identity(r,uid)}:${(r['attendance_date']?.toString()??'').split('T').first}:${_sessionIndexOf(r)}';
  static Future<String> _key(int uid) async=>'$_prefix$uid';

  static bool _sameWorker(Map r,int employeeId,int? workerId)=>(r['employee_id']?.toString()??'')==employeeId.toString()&&(r['worker_id']?.toString()??'')==(workerId?.toString()??'');

  static Future<List<Map<String,dynamic>>> loadLocalRecords() async { final uid=await _userId();if(uid==null||uid<=0)return <Map<String,dynamic>>[];final p=await SharedPreferences.getInstance();final raw=p.getString(await _key(uid));if(raw==null||raw.isEmpty)return <Map<String,dynamic>>[];try{final d=jsonDecode(raw);if(d is! List)return <Map<String,dynamic>>[];return d.whereType<Map>().map((e)=>Map<String,dynamic>.from(e)).toList();}catch(_){return <Map<String,dynamic>>[];} }

  static Future<void> _saveRecords(List<Map<String,dynamic>> records) async { final uid=await _userId();if(uid==null||uid<=0)return;final p=await SharedPreferences.getInstance();final out=<String,Map<String,dynamic>>{};for(final r in records){final k=_recordKey(r,uid);if(k.endsWith(':'))continue;out[k]=Map<String,dynamic>.from(r);}await p.setString(await _key(uid),jsonEncode(out.values.toList())); }

  /// All sessions (check-in/out pairs) for [employeeId]/[workerId] on [date],
  /// sorted by session index (i.e. chronological order).
  static Future<List<Map<String,dynamic>>> _findTodaySessions({required int employeeId,int? workerId,required String date}) async {
    final records=await loadLocalRecords();
    final sessions=records.where((r)=>_sameWorker(r,employeeId,workerId)&&(r['attendance_date']?.toString()??'').split('T').first==date).map((e)=>Map<String,dynamic>.from(e)).toList();
    sessions.sort((a,b)=>_sessionIndexOf(a).compareTo(_sessionIndexOf(b)));
    return sessions;
  }

  /// The currently open session for today, if any (checked in, not yet
  /// checked out). This is what determines whether the next tap should be
  /// a check-in or a check-out.
  static Future<Map<String,dynamic>?> _findOpenSession({required int employeeId,int? workerId,required String date}) async {
    final sessions=await _findTodaySessions(employeeId:employeeId,workerId:workerId,date:date);
    for(final s in sessions.reversed){if(s['check_in_time']!=null&&s['check_out_time']==null)return s;}
    return null;
  }

  static Future<void> _upsertSession({required int employeeId,int? workerId,required String date,required int sessionIndex,DateTime? checkIn,DateTime? checkOut,String? status,double? workingHours}) async {
    final records=await loadLocalRecords();
    final index=records.indexWhere((r)=>_sameWorker(r,employeeId,workerId)&&(r['attendance_date']?.toString()??'').split('T').first==date&&_sessionIndexOf(r)==sessionIndex);
    final existing=index>=0?Map<String,dynamic>.from(records[index]):<String,dynamic>{};
    final merged=<String,dynamic>{
      ...existing,
      'employee_id':employeeId,
      if(workerId!=null)'worker_id':workerId,
      'attendance_date':date,
      'session_index':sessionIndex,
      if(checkIn!=null)'check_in_time':checkIn.toUtc().toIso8601String(),
      if(checkOut!=null)'check_out_time':checkOut.toUtc().toIso8601String(),
      if(status!=null)'status':status.toUpperCase(),
      if(workingHours!=null)'working_hours':workingHours,
      'local_pending':true,
      'updated_at':DateTime.now().toUtc().toIso8601String(),
    };
    if(index>=0)records[index]=merged;else records.add(merged);
    await _saveRecords(records);
  }

  /// Starts a new attendance session. If a session is already open (checked
  /// in but not checked out), this is treated as the toggle's check-out
  /// action instead of silently failing — so a stale double-tap never gets
  /// stuck. Otherwise a brand-new session is opened, so a worker can check
  /// in again after an earlier check-out on the same day (e.g. after lunch).
  static Future<bool> checkIn({required int employeeId,int? workerId}) async {
    final now=DateTime.now();
    final date=_date(now);
    final open=await _findOpenSession(employeeId:employeeId,workerId:workerId,date:date);
    if(open!=null)return checkOut(employeeId:employeeId,workerId:workerId);
    final sessions=await _findTodaySessions(employeeId:employeeId,workerId:workerId,date:date);
    final nextIndex=sessions.isEmpty?0:(sessions.map(_sessionIndexOf).reduce((a,b)=>a>b?a:b)+1);
    final operationId='ATT_IN_${workerId??employeeId}_${date}_s$nextIndex';
    await _upsertSession(employeeId:employeeId,workerId:workerId,date:date,sessionIndex:nextIndex,checkIn:now,status:'PRESENT');
    final queued=await SyncQueueManager.enqueue('attendance_check_in',{'operation_id':operationId,'idempotency_key':operationId,'employee_id':employeeId,'worker_id':workerId,'attendance_date':date,'session_index':nextIndex});
    if(!queued)throw StateError('Unable to persist attendance check-in to durable outbox');
    return true;
  }

  /// Closes the currently open session for today. No-op (returns true) if
  /// everything is already checked out, so repeated taps stay safe.
  static Future<bool> checkOut({required int employeeId,int? workerId}) async {
    final now=DateTime.now();
    final date=_date(now);
    final open=await _findOpenSession(employeeId:employeeId,workerId:workerId,date:date);
    if(open==null)return true;
    final sessionIndex=_sessionIndexOf(open);
    DateTime? checkIn;
    final raw=open['check_in_time'];
    if(raw!=null)checkIn=DateTime.tryParse(raw.toString());
    final hours=checkIn==null?null:now.difference(checkIn.toLocal()).inSeconds/3600.0;
    final operationId='ATT_OUT_${workerId??employeeId}_${date}_s$sessionIndex';
    await _upsertSession(employeeId:employeeId,workerId:workerId,date:date,sessionIndex:sessionIndex,checkOut:now,workingHours:hours,status:'PRESENT');
    final queued=await SyncQueueManager.enqueue('attendance_check_out',{'operation_id':operationId,'idempotency_key':operationId,'employee_id':employeeId,'worker_id':workerId,'attendance_date':date,'session_index':sessionIndex});
    if(!queued)throw StateError('Unable to persist attendance check-out to durable outbox');
    return true;
  }

  /// The open session for today, if any — the single source of truth the UI
  /// should use to decide whether the next tap is a check-in or check-out.
  static Future<Map<String,dynamic>?> openSessionToday({required int employeeId,int? workerId}) => _findOpenSession(employeeId:employeeId,workerId:workerId,date:_date(DateTime.now()));

  /// All of today's sessions in chronological order (for history display).
  static Future<List<Map<String,dynamic>>> todaySessions({required int employeeId,int? workerId}) => _findTodaySessions(employeeId:employeeId,workerId:workerId,date:_date(DateTime.now()));

  /// Total worked hours for today across all sessions (closed sessions use
  /// their stored working_hours; an open session contributes live elapsed
  /// time so the UI can show a running total).
  static Future<double> todayTotalHours({required int employeeId,int? workerId}) async {
    final date=_date(DateTime.now());
    final sessions=await _findTodaySessions(employeeId:employeeId,workerId:workerId,date:date);
    double total=0;
    for(final s in sessions){
      if(s['working_hours']!=null){total+=(s['working_hours'] as num).toDouble();continue;}
      final cin=DateTime.tryParse((s['check_in_time']??'').toString());
      final cout=DateTime.tryParse((s['check_out_time']??'').toString());
      if(cin!=null&&cout!=null)total+=cout.toLocal().difference(cin.toLocal()).inSeconds/3600.0;
      else if(cin!=null&&s['check_out_time']==null)total+=DateTime.now().difference(cin.toLocal()).inSeconds/3600.0;
    }
    return total;
  }

  /// Remote records are keyed by employee+date without a session concept on
  /// legacy backends, so they're merged into session index 0 unless the
  /// server itself starts sending a `session_index` field (forward
  /// compatible if/when the backend adds multi-session support).
  static Future<void> mergeRemoteRecords(List<Map<String,dynamic>> remoteRecords) async { if(remoteRecords.isEmpty)return;try{final uid=await _userId();if(uid==null||uid<=0)return;final local=await loadLocalRecords();final merged=<String,Map<String,dynamic>>{};for(final r in local){merged[_recordKey(r,uid)]=Map<String,dynamic>.from(r);}for(final serverRaw in remoteRecords){final server=Map<String,dynamic>.from(serverRaw);server['session_index']??=0;final k=_recordKey(server,uid);final previous=merged[k];merged[k]={...(previous??{}),...server,'local_pending':false,'synced_at':DateTime.now().toUtc().toIso8601String()};}await _saveRecords(merged.values.toList());}catch(e){if(kDebugMode)debugPrint('⚠️ Failed to cache remote attendance history: $e');} }

  static Future<void> reconcileFromBackend() async { final uid=await _userId();if(uid==null||uid<=0)return;try{final date=_date(DateTime.now());final response=await ApiClient.getJson('${ApiClient.attendancePrefix}/date/$date');if(response.statusCode!=200)return;final decoded=jsonDecode(response.body);if(decoded is! Map||decoded['records'] is! List)return;final remote=(decoded['records'] as List).whereType<Map>().map((e)=>Map<String,dynamic>.from(e)).toList();if(remote.isEmpty)return;await mergeRemoteRecords(remote);}catch(e){if(kDebugMode)debugPrint('OfflineAttendance reconcile skipped: $e');} }

  static Future<void> markSynced({required int employeeId,int? workerId,required String date,int sessionIndex=0}) async {final records=await loadLocalRecords();for(int i=0;i<records.length;i++){final r=records[i];if(_sameWorker(r,employeeId,workerId)&&(r['attendance_date']?.toString().split('T').first??'')==date&&_sessionIndexOf(r)==sessionIndex){records[i]={...r,'local_pending':false,'synced_at':DateTime.now().toUtc().toIso8601String()};await _saveRecords(records);return;}}}
}
