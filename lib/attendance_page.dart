import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'scoped_shared_preferences.dart';
import 'package:intl/intl.dart';
import 'api_client.dart';
import 'app_localizations.dart';
import 'package:provider/provider.dart';
import 'language_provider.dart';
import 'models.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'worker_local_storage.dart';
import 'worker_attendance_detail_page.dart';
import 'attendance_offline_service.dart';

class AttendancePage extends StatefulWidget {
  const AttendancePage({super.key});
  @override
  State<AttendancePage> createState() => _AttendancePageState();
}

class _AttendancePageState extends State<AttendancePage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const Color _primary = Color(0xFF6366F1);
  static const Color _present = Color(0xFF10B981);
  static const Color _absent = Color(0xFFEF4444);
  static const Color _half = Color(0xFFF59E0B);

  // Shift window used to flag late check-ins / early check-outs.
  static const TimeOfDay _shiftStart = TimeOfDay(hour: 9, minute: 30);
  static const int _lateGraceMinutes = 15;

  final DateFormat _df = DateFormat('yyyy-MM-dd');
  bool _loading = true;
  bool _marking = false;
  List<dynamic> _records = [];
  Map<String, dynamic>? _todaySummary;
  int? _userId;
  late TabController _tab;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  Timer? _timer;
  Timer? _refreshTimer;
  bool _refreshInFlight = false;
  String _liveHours = '0.0';
  List<Worker> _staff = [];
  // Source of truth for "am I currently checked in?" — read straight from
  // OfflineAttendanceService (which supports multiple sessions/day) instead
  // of being derived from the collapsed `_records` display list.
  Map<String, dynamic>? _mySession;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tab = TabController(length: 3, vsync: this);
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.1).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _init();
    _startTimer();
    _startRefreshTimer();
  }

  @override
  void dispose() {
    _tab.dispose();
    _pulseController.dispose();
    _timer?.cancel();
    _refreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    _userId = prefs.getInt('user_id') ?? prefs.getInt('userId');

    if (_userId == null) {
      if (kDebugMode) debugPrint('⚠️ No user_id found in preferences');
      // Delay snack message until widget is built
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showSnack('⚠️ Please login to use attendance', _absent);
      });
    }

    await _loadStaff();
    // Backend is authoritative after login/data-clear; reconcile before the
    // first UI fetch so a stale local state cannot force a false Check In.
    try {
      await OfflineAttendanceService.reconcileFromBackend();
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Attendance reconciliation deferred: $e');
    }
    await _fetch();
  }

  Future<void> _loadStaff() async {
    // Load staff from local storage first (immediate response)
    try {
      final workers = await WorkerLocalStorage.fetchWorkers(_userId ?? 0);
      
      if (workers.isNotEmpty && mounted) {
        setState(() {
          _staff = workers;
        });
        if (kDebugMode) debugPrint('📦 Loaded ${_staff.length} workers from local storage');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Error loading staff from local storage: $e');
    }
    
    // Then sync with backend in background
    try {
      final url = (_userId != null && _userId! > 0)
          ? '${ApiClient.attendanceWorkers}?user_id=$_userId'
          : ApiClient.attendanceWorkers;
      final res = await ApiClient.getJson(url);
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (mounted) {
          final syncedWorkers = data is List
              ? data.map((w) => Worker.fromJson(w)).toList()
              : (data is Map && data['workers'] is List)
                  ? (data['workers'] as List)
                      .whereType<Map>()
                      .map((w) => Worker.fromJson(Map<String, dynamic>.from(w)))
                      .toList()
                  : <Worker>[];

          // Backend success becomes the durable offline roster.
          await WorkerLocalStorage.saveWorkers(_userId ?? 0, syncedWorkers);

          setState(() {
            _staff = syncedWorkers;
          });
          if (kDebugMode) {
            debugPrint('✅ Synced and cached ${_staff.length} workers from backend');
          }
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Backend staff sync failed: $e, using local data');
    }
  }

  Future<void> _saveStaff() async {
    // Staff is now synced with backend - no local save needed
    // Refresh from backend to ensure consistency
    await _loadStaff();
  }

  Future<void> _fetch() async {
    setState(() => _loading = true);
    try {
      // Local-first: render persisted attendance immediately, even offline.
      final localRecords = await OfflineAttendanceService.loadLocalRecords();
      if (mounted && localRecords.isNotEmpty) {
        setState(() => _records = localRecords);
      }

      final today = _df.format(DateTime.now());
      
      // Fetch shopkeeper's attendance
      String url = '${ApiClient.attendancePrefix}/date/$today';
      if (_userId != null) {
        url += '?employee_id=$_userId';
      }
      final res = await ApiClient.getJson(url);
      
      List<dynamic> allRecords = [];
      
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (data is List) {
          allRecords = List<dynamic>.from(data);
        } else if (data is Map) {
          allRecords = List<dynamic>.from((data['records'] ?? []) as List);
          _todaySummary = Map<String, dynamic>.from(data);
        }
      }
      
      // Fetch worker attendance in parallel so payroll/attendance stays responsive.
      final workerResults = await Future.wait<List<dynamic>>(_staff.map((worker) async {
        try {
          final workerUrl = '${ApiClient.attendancePrefix}/employee/${worker.id}';
          final workerRes = await ApiClient.getJson(workerUrl);
          if (workerRes.statusCode == 200) {
            final workerData = json.decode(workerRes.body);
            if (workerData is Map && workerData['records'] is List) return List<dynamic>.from(workerData['records'] as List);
            if (workerData is List) return List<dynamic>.from(workerData);
          }
        } catch (e) {
          if (kDebugMode) debugPrint('Error fetching attendance for worker ${worker.id}: $e');
        }
        return <dynamic>[];
      }));
      for (final workerRecords in workerResults) { allRecords.addAll(workerRecords); }

      // Persist the complete remote history so payroll does not fall to zero
      // on cold start when the network/auth refresh is temporarily unavailable.
      if (allRecords.isNotEmpty) {
        await OfflineAttendanceService.mergeRemoteRecords(
          allRecords.whereType<Map>().map((r) => Map<String, dynamic>.from(r)).toList(),
        );
      }
      
      // IMPORTANT: never replace durable local attendance with a stale/empty
      // cloud response. Immediately after CHECK IN/CHECK OUT the local record
      // is marked local_pending=true; a cloud response can legitimately lag
      // behind it. Merge by employee/worker + business date and prefer the
      // local pending record until sync confirms it.
      final mergedByKey = <String, Map<String, dynamic>>{};
      String attendanceKey(Map<String, dynamic> r) {
        final employee = (r['worker_id'] ?? r['employee_id'] ?? '').toString();
        final date = (r['attendance_date'] ?? '').toString().split('T').first;
        // Include session_index so multiple check-in/out pairs on the same
        // day are kept as separate records instead of overwriting each
        // other (which previously made hours/history undercount and made
        // the day look "closed" after the first checkout).
        final session = (r['session_index'] ?? 0).toString();
        return '$employee:$date:$session';
      }

      for (final raw in [...localRecords, ...allRecords]) {
        if (raw is! Map) continue;
        final record = Map<String, dynamic>.from(raw);
        final key = attendanceKey(record);
        if (key == ':') continue;
        final existing = mergedByKey[key];
        if (existing == null) {
          mergedByKey[key] = record;
        } else if (record['local_pending'] == true && existing['local_pending'] != true) {
          mergedByKey[key] = record;
        } else if (existing['local_pending'] == true) {
          // Preserve the local pending state and its timestamps. Remote data
          // must not make the UI flip back to CHECK IN while sync is pending.
          mergedByKey[key] = {...record, ...existing, 'local_pending': true};
        } else {
          mergedByKey[key] = {...existing, ...record};
        }
      }

      if (mounted) {
        setState(() {
          _records = mergedByKey.values.toList();
        });
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error fetching attendance: $e');
      }
      if (mounted) {
        _showSnack('Failed to load attendance data', _absent);
      }
    }
    setState(() => _loading = false);
    await _refreshMySession();
    await _updateLiveHours();
  }

  Future<void> _refreshAttendanceData() async {
    if (!mounted || _refreshInFlight) return;
    _refreshInFlight = true;
    try {
      await _loadStaff();
      try { await OfflineAttendanceService.reconcileFromBackend(); } catch (e) { if (kDebugMode) debugPrint('⚠️ Attendance reconcile refresh failed: $e'); }
      await _fetch();
    } finally {
      _refreshInFlight = false;
    }
  }

  void _startRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(minutes: 5), (_) => _refreshAttendanceData());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshAttendanceData();
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(minutes: 1), (timer) {
      if (mounted) _updateLiveHours();
    });
  }

  Future<void> _updateLiveHours() async {
    if (_userId == null) return;
    // Sum across ALL of today's sessions (not just one record), so hours
    // keep accumulating correctly across multiple check-in/check-out pairs.
    final total = await OfflineAttendanceService.todayTotalHours(employeeId: _userId!);
    if (mounted) {
      setState(() {
        _liveHours = total.toStringAsFixed(2);
      });
    }
  }

  /// Refreshes the open-session pointer used to drive the check-in/out
  /// button. Always re-read after fetch/check-in/check-out so the button
  /// never gets stuck disabled once a session is closed.
  Future<void> _refreshMySession() async {
    if (_userId == null) return;
    final open = await OfflineAttendanceService.openSessionToday(employeeId: _userId!);
    if (mounted) setState(() => _mySession = open);
  }

  /// Backend sends naive timestamps with no timezone suffix (e.g.
  /// "2026-07-28T04:15:00"), which are actually UTC. DateTime.parse would
  /// otherwise treat that string as *local* time, which is wrong by our
  /// UTC offset. This normalizes any server timestamp to local time
  /// consistently, whether or not it carries a timezone suffix already.
  DateTime? _parseServerTime(dynamic raw) {
    if (raw == null) return null;
    final str = raw.toString();
    DateTime? t = DateTime.tryParse(str);
    if (t == null) return null;
    if (!str.contains('+') && !str.endsWith('Z')) {
      t = DateTime.parse('${str}Z');
    }
    return t.toLocal();
  }

  bool _isLateCheckIn(Map r) {
    final cin = _parseServerTime(r['check_in_time']);
    if (cin == null) return false;
    final threshold = DateTime(
        cin.year, cin.month, cin.day, _shiftStart.hour, _shiftStart.minute + _lateGraceMinutes);
    return cin.isAfter(threshold);
  }

  double _calculateWorkerMonthlyHours(int workerId) {
    double totalHours = 0;
    final now = DateTime.now();
    
    // Filter records for this worker in current month using worker_id field
    for (var r in _records) {
      // Use worker_id if available, otherwise fall back to employee_id for backward compatibility
      final recordWorkerId = r['worker_id'] ?? r['employee_id'];
      if (recordWorkerId == null) continue;
      if (recordWorkerId.toString() != workerId.toString()) continue;
      
      final attDateStr = (r['attendance_date'] ?? '').toString().split('T').first.trim();
      final attDate = DateTime.tryParse(attDateStr);
      if (attDate == null) continue;
      if (attDate.year != now.year || attDate.month != now.month) continue;
      
      // Use working_hours from backend if available
      if (r['working_hours'] != null) {
        totalHours += (r['working_hours'] as num).toDouble();
      } else if (r['check_in_time'] != null && r['check_out_time'] != null) {
        final cin = _parseServerTime(r['check_in_time']);
        final cout = _parseServerTime(r['check_out_time']);
        if (cin != null && cout != null) {
          totalHours += cout.difference(cin).inMinutes / 60.0;
        }
      }
    }
    return totalHours;
  }

  Future<void> _checkInOut() async {
    if (_userId == null) {
      _showSnack('⚠️ User ID not found. Please login again.', _absent);
      return;
    }
    setState(() => _marking = true);

    try {
      // _mySession is refreshed straight from OfflineAttendanceService after
      // every fetch/check-in/check-out, so it's always the current truth —
      // no risk of reading a stale collapsed record from `_records`.
      if (_mySession == null) {
        await OfflineAttendanceService.checkIn(employeeId: _userId!);
        _showSnack('✅ Checked In — saved offline and queued for sync', _present);
      } else {
        await OfflineAttendanceService.checkOut(employeeId: _userId!);
        _showSnack('👋 Checked Out — saved offline and queued for sync. Tap again anytime to check back in.', _primary);
      }

      await _fetch();
    } catch (e) {
      _showSnack('❌ Attendance could not be saved safely: $e', _absent);
    } finally {
      if (mounted) setState(() => _marking = false);
    }
  }

  void _showSnack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontWeight: FontWeight.w600)),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final today = _df.format(DateTime.now());
    // ✅ FIX: Normalize date and employee_id comparison (backend may return string ID)
    final myRecord = _records.where((r) {
      final recDate = (r['attendance_date'] ?? '').toString().split('T').first.trim();
      final empId = r['employee_id'];
      final empIdMatch = empId == _userId || empId.toString() == _userId.toString();
      return empIdMatch && recDate == today;
    }).firstOrNull;

    // Whether there's an open session right now drives the button — NOT
    // whether a session was ever checked out today. This is what allows
    // multiple check-in/check-out pairs on the same day (e.g. lunch break):
    // once a session is checked out, the button goes back to "Check In"
    // instead of getting permanently disabled.
    final hasOpenSession = _mySession != null;

    String btnLabel = AppLocalizations.of(context).checkIn;
    Color btnColor = _present;
    IconData btnIcon = Icons.login;
    if (hasOpenSession) {
      btnLabel = AppLocalizations.of(context).checkOut;
      btnColor = _primary;
      btnIcon = Icons.logout;
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: Text(AppLocalizations.of(context).attendance, style: GoogleFonts.poppins(
            fontWeight: FontWeight.w700, color: Colors.white)),
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          _buildLanguageSwitcher(),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _fetch)
        ],
        bottom: TabBar(
          controller: _tab,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          tabs: [
            Tab(text: AppLocalizations.of(context).today),
            Tab(text: AppLocalizations.of(context).history),
            const Tab(text: 'Payroll'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          // Prefer the live open session for display (accurate in-progress
          // check-in time); fall back to whatever `_records` has for today.
          _todayTab(_mySession ?? myRecord, hasOpenSession, !hasOpenSession && myRecord != null),
          _historyTab(),
          _payrollTab(),
        ],
      ),
      floatingActionButton: ScaleTransition(
        scale: _pulseAnimation,
        child: FloatingActionButton.extended(
          // Always tappable (aside from the in-flight spinner state) so a
          // worker can check in again after checking out earlier the same
          // day. This is the actual bug fix: the button used to be
          // permanently disabled once `checkedOut` became true.
          onPressed: _marking ? null : _checkInOut,
          backgroundColor: btnColor,
          foregroundColor: Colors.white,
          elevation: 4,
          icon: _marking
              ? const SizedBox(width: 20, height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : Icon(btnIcon),
          label: Text(btnLabel,
              style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }

  Widget _todayTab(Map<String, dynamic>? rec, bool ci, bool co) {
    final today = DateFormat('EEEE, dd MMMM yyyy').format(DateTime.now());

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Date banner
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)]),
              borderRadius: BorderRadius.circular(16)),
          child: Row(children: [
            Icon(Icons.calendar_today, color: Colors.white70, size: 20),
            const SizedBox(width: 10),
            Text(today, style: GoogleFonts.poppins(
                color: Colors.white, fontWeight: FontWeight.w600)),
          ]),
        ),
        const SizedBox(height: 20),
        
        // --- STAFF ATTENDANCE (Moved to top for visibility) ---
        if (_staff.isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Staff Management', style: GoogleFonts.poppins(
                    fontWeight: FontWeight.w80