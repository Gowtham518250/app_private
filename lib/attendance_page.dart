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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tab = TabController(length: 3, vsync: this);
    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.1).animate(CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut));
    _init();
    _startTimer();
    _startRefreshTimer();
  }

  @override
  void dispose() {
    _tab.dispose(); _pulseController.dispose(); _timer?.cancel(); _refreshTimer?.cancel(); WidgetsBinding.instance.removeObserver(this); super.dispose();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance(); _userId = prefs.getInt('user_id') ?? prefs.getInt('userId');
    if (_userId == null) { if (kDebugMode) debugPrint('⚠️ No user_id found in preferences'); WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _showSnack('⚠️ Please login to use attendance', _absent); }); }
    await _loadStaff(); try { await OfflineAttendanceService.reconcileFromBackend(); } catch (e) { if (kDebugMode) debugPrint('⚠️ Attendance reconciliation deferred: $e'); } await _fetch();
  }
  Future<void> _loadStaff() async { try { final workers=await WorkerLocalStorage.fetchWorkers(_userId??0); if(workers.isNotEmpty&&mounted)setState(()=>_staff=workers); } catch(e){if(kDebugMode)debugPrint('Error loading staff from local storage: $e');} try { final url=(_userId!=null&&_userId!>0)?'${ApiClient.attendanceWorkers}?user_id=$_userId':ApiClient.attendanceWorkers; final res=await ApiClient.getJson(url); if(res.statusCode==200&&mounted){final data=json.decode(res.body); final syncedWorkers=data is List?data.map((w)=>Worker.fromJson(w)).toList():(data is Map&&data['workers'] is List)?(data['workers'] as List).whereType<Map>().map((w)=>Worker.fromJson(Map<String,dynamic>.from(w))).toList():<Worker>[]; await WorkerLocalStorage.saveWorkers(_userId??0,syncedWorkers); setState(()=>_staff=syncedWorkers);}} catch(e){if(kDebugMode)debugPrint('⚠️ Backend staff sync failed: $e, using local data');} }
  Future<void> _saveStaff() async => _loadStaff();
  Future<void> _fetch() async { if(!mounted)return; setState(()=>_loading=true); try { final localRecords=await OfflineAttendanceService.loadLocalRecords(); if(mounted&&localRecords.isNotEmpty)setState(()=>_records=localRecords); final today=_df.format(DateTime.now()); String url='${ApiClient.attendancePrefix}/date/$today'; if(_userId!=null)url+='?employee_id=$_userId'; final res=await ApiClient.getJson(url); List<dynamic> allRecords=[]; if(res.statusCode==200){final data=json.decode(res.body); if(data is List)allRecords=List<dynamic>.from(data); else if(data is Map){allRecords=List<dynamic>.from((data['records']??[])as List);_todaySummary=Map<String,dynamic>.from(data);}} final workerResults=await Future.wait<List<dynamic>>(_staff.map((worker)async{try{final workerRes=await ApiClient.getJson('${ApiClient.attendancePrefix}/employee/${worker.id}');if(workerRes.statusCode==200){final workerData=json.decode(workerRes.body);if(workerData is Map&&workerData['records'] is List)return List<dynamic>.from(workerData['records']as List);if(workerData is List)return List<dynamic>.from(workerData);}}catch(e){if(kDebugMode)debugPrint('Error fetching attendance for worker ${worker.id}: $e');}return <dynamic>[];})); for(final workerRecords in workerResults)allRecords.addAll(workerRecords); if(allRecords.isNotEmpty)await OfflineAttendanceService.mergeRemoteRecords(allRecords.whereType<Map>().map((r)=>Map<String,dynamic>.from(r)).toList()); final mergedByKey=<String,Map<String,dynamic>>{}; String attendanceKey(Map<String,dynamic>r){final employee=(r['employee_id']??r['worker_id']??'').toString();final date=(r['attendance_date']??'').toString().split('T').first;return '$employee:$date';} for(final raw in[...localRecords,...allRecords]){if(raw is!Map)continue;final record=Map<String,dynamic>.from(raw);final key=attendanceKey(record);if(key==':')continue;final existing=mergedByKey[key];if(existing==null)mergedByKey[key]=record;else if(record['local_pending']==true&&existing['local_pending']!=true)mergedByKey[key]=record;else if(existing['local_pending']==true)mergedByKey[key]={...record,...existing,'local_pending':true};else mergedByKey[key]={...existing,...record};} if(mounted)setState(()=>_records=mergedByKey.values.toList()); }catch(e){if(kDebugMode)debugPrint('Error fetching attendance: $e');if(mounted)_showSnack('Failed to load attendance data',_absent);} if(mounted)setState(()=>_loading=false);_updateLiveHours(); }
  Future<void> _refreshAttendanceData()async{if(!mounted||_refreshInFlight)return;_refreshInFlight=true;try{await _loadStaff();try{await OfflineAttendanceService.reconcileFromBackend();}catch(e){if(kDebugMode)debugPrint('⚠️ Attendance reconcile refresh failed: $e');}await _fetch();}finally{_refreshInFlight=false;}}
  void _startRefreshTimer(){_refreshTimer?.cancel();_refreshTimer=Timer.periodic(const Duration(minutes:5),(_)=>_refreshAttendanceData());}
  @override void didChangeAppLifecycleState(AppLifecycleState state){if(state==AppLifecycleState.resumed)_refreshAttendanceData();}
  void _startTimer(){_timer=Timer.periodic(const Duration(minutes:1),(_){if(mounted)_updateLiveHours();});}
  void _updateLiveHours(){final today=_df.format(DateTime.now());final candidates=_records.where((r){final date=(r['attendance_date']??'').toString().split('T').first.trim();final id=r['employee_id'];return(id==_userId||id?.toString()==_userId.toString())&&date==today;}).map((r)=>Map<String,dynamic>.from(r as Map)).toList();Map<String,dynamic>?myRecord;if(candidates.isNotEmpty){final pending=candidates.where((r)=>r['local_pending']==true).toList();if(pending.isNotEmpty)myRecord=pending.first;else{candidates.sort((a,b){final at=DateTime.tryParse(a['updated_at']?.toString()??'')??DateTime.fromMillisecondsSinceEpoch(0);final bt=DateTime.tryParse(b['updated_at']?.toString()??'')??DateTime.fromMillisecondsSinceEpoch(0);return bt.compareTo(at);});myRecord=candidates.first;}}if(myRecord!=null&&myRecord['check_in_time']!=null&&myRecord['check_out_time']==null){final cin=_parseServerTime(myRecord['check_in_time']);if(cin!=null&&mounted)setState(()=>_liveHours=(DateTime.now().difference(cin).inMinutes/60.0).toStringAsFixed(2));}else if(myRecord!=null&&myRecord['working_hours']!=null){if(mounted)setState(()=>_liveHours=(myRecord!['working_hours']as num).toDouble().toStringAsFixed(2));}else if(mounted)setState(()=>_liveHours='0.00');}
  DateTime?_parseServerTime(dynamic raw){if(raw==null)return null;final str=raw.toString();var t=DateTime.tryParse(str);if(t==null)return null;if(!str.contains('+')&&!str.endsWith('Z'))t=DateTime.parse('${str}Z');return t.toLocal();}
  bool _isLateCheckIn(Map r){final cin=_parseServerTime(r['check_in_time']);if(cin==null)return false;final threshold=DateTime(cin.year,cin.month,cin.day,_shiftStart.hour,_shiftStart.minute+_lateGraceMinutes);return cin.isAfter(threshold);}
  double _calculateWorkerMonthlyHours(int workerId){double total=0;final now=DateTime.now();for(final r in _records){final id=r['worker_id']??r['employee_id'];if(id==null||id.toString()!=workerId.toString())continue;final d=DateTime.tryParse((r['attendance_date']??'').toString().split('T').first.trim());if(d==null||d.year!=now.year||d.month!=now.month)continue;if(r['working_hours']!=null)total+=(r['working_hours']as num).toDouble();else if(r['check_in_time']!=null&&r['check_out_time']!=null){final cin=_parseServerTime(r['check_in_time']);final cout=_parseServerTime(r['check_out_time']);if(cin!=null&&cout!=null)total+=cout.difference(cin).inMinutes/60.0;}}return total;}
  Future<void> _checkInOut()async{if(_userId==null){_showSnack('⚠️ User ID not found. Please login again.',_absent);return;}setState(()=>_marking=true);try{final today=_df.format(DateTime.now());final matchingRecords=_records.where((r){if(r is!Map)return false;final recDate=(r['attendance_date']??'').toString().split('T').first.trim();final empId=r['employee_id'];return(empId==_userId||empId?.toString()==_userId.toString())&&recDate==today;}).map((r)=>Map<String,dynamic>.from(r as Map)).toList();Map<String,dynamic>?myRecord;if(matchingRecords.isNotEmpty){final pending=matchingRecords.where((r)=>r['local_pending']==true).toList();if(pending.isNotEmpty)myRecord=pending.first;else{matchingRecords.sort((a,b){final at=DateTime.tryParse(a['updated_at']?.toString()??'')??DateTime.fromMillisecondsSinceEpoch(0);final bt=DateTime.tryParse(b['updated_at']?.toString()??'')??DateTime.fromMillisecondsSinceEpoch(0);return bt.compareTo(at);});myRecord=matchingRecords.first;}}if(myRecord==null||myRecord['check_in_time']==null){await OfflineAttendanceService.checkIn(employeeId:_userId!);_showSnack('✅ Checked In — saved offline and queued for sync',_present);}else if(myRecord['check_out_time']==null){await OfflineAttendanceService.checkOut(employeeId:_userId!);_showSnack('👋 Checked Out — saved offline and queued for sync',_primary);}else{_showSnack('✅ Already checked in and out today',Colors.orange);}await _fetch();}catch(e){_showSnack('❌ Attendance could not be saved safely: $e',_absent);}finally{if(mounted)setState(()=>_marking=false);}}
  void _showSnack(String msg,Color color){if(!mounted)return;ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(msg,style:const TextStyle(fontWeight:FontWeight.w600)),backgroundColor:color,behavior:SnackBarBehavior.floating,shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(12))));}
  @override Widget build(BuildContext context){final myRecord=_myTodayRecord();final checkedIn=myRecord!=null&&myRecord['check_in_time']!=null;final checkedOut=checkedIn&&myRecord['check_out_time']!=null;String btnLabel=AppLocalizations.of(context).checkIn;Color btnColor=_present;IconData btnIcon=Icons.login;if(checkedIn&&!checkedOut){btnLabel=AppLocalizations.of(context).checkOut;btnColor=_primary;btnIcon=Icons.logout;}else if(checkedOut){btnLabel=AppLocalizations.of(context).gotIt;btnColor=Colors.grey;btnIcon=Icons.check_circle;}return Scaffold(backgroundColor:const Color(0xFFF8FAFC),appBar:AppBar(title:Text('Attendance',style:GoogleFonts.poppins(fontWeight:FontWeight.w700)),backgroundColor:Colors.white,foregroundColor:const Color(0xFF111827),elevation:0,bottom:TabBar(controller:_tab,tabs:const[Tab(text:'Today'),Tab(text:'Staff'),Tab(text:'History')])),body:_loading&&_records.isEmpty?const Center(child:CircularProgressIndicator()):TabBarView(controller:_tab,children:[_buildToday(myRecord,checkedIn,checkedOut,btnLabel,btnColor,btnIcon),_buildStaff(),_buildHistory()]));}
  Map<String,dynamic>?_myTodayRecord(){final today=_df.format(DateTime.now());final candidates=_records.where((r){final date=(r['attendance_date']??'').toString().split('T').first.trim();final id=r['employee_id'];return(id==_userId||id?.toString()==_userId.toString())&&date==today;}).map((r)=>Map<String,dynamic>.from(r as Map)).toList();if(candidates.isEmpty)return null;final pending=candidates.where((r)=>r['local_pending']==true).toList();if(pending.isNotEmpty)return pending.first;candidates.sort((a,b){final at=DateTime.tryParse(a['updated_at']?.toString()??'')??DateTime.fromMillisecondsSinceEpoch(0);final bt=DateTime.tryParse(b['updated_at']?.toString()??'')??DateTime.fromMillisecondsSinceEpoch(0);return bt.compareTo(at);});return candidates.first;}
  Widget _buildToday(Map<String,dynamic>?myRecord,bool checkedIn,bool checkedOut,String btnLabel,Color btnColor,IconData btnIcon)=>RefreshIndicator(onRefresh:_refreshAttendanceData,child:ListView(padding:const EdgeInsets.all(20),children:[Card(child:Padding(padding:const EdgeInsets.all(20),child:Column(children:[Text(checkedOut?'Attendance completed':checkedIn?'You are checked in':'Ready to check in',style:GoogleFonts.poppins(fontSize:18,fontWeight:FontWeight.w700)),const SizedBox(height:12),Text('Live hours: $_liveHours',style:GoogleFonts.poppins(fontSize:16)),const SizedBox(height:20),ScaleTransition(scale:_pulseAnimation,child:ElevatedButton.icon(onPressed:_marking||checkedOut?null:_checkInOut,icon:Icon(btnIcon),label:Text(_marking?'Saving...':btnLabel),style:ElevatedButton.styleFrom(backgroundColor:btnColor,foregroundColor:Colors.white,minimumSize:const Size.fromHeight(52))))]))),const SizedBox(height:16),if(myRecord!=null)Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('Today',style:GoogleFonts.poppins(fontWeight:FontWeight.w700)),const SizedBox(height:8),Text('Status: ${(myRecord['status']??'PRESENT').toString()}'),if(myRecord['check_in_time']!=null)Text('Check-In: ${_formatTime(myRecord['check_in_time'])}'),if(myRecord['check_out_time']!=null)Text('Check-Out: ${_formatTime(myRecord['check_out_time'])}')])))]));
  String _formatTime(dynamic raw){final t=_parseServerTime(raw);return t==null?raw.toString():DateFormat('h:mm a').format(t);}
  Widget _buildStaff()=>ListView.builder(padding:const EdgeInsets.all(16),itemCount:_staff.length,itemBuilder:(context,index){final worker=_staff[index];final hours=_calculateWorkerMonthlyHours(worker.id);return Card(child:ListTile(title:Text(worker.name),subtitle:Text('Monthly hours: ${hours.toStringAsFixed(2)}'),trailing:const Icon(Icons.chevron_right),onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>WorkerAttendanceDetailPage(worker:worker,records:_records)))));});
  Widget _buildHistory(){final sorted=List<dynamic>.from(_records)..sort((a,b)=>(b['attendance_date']??'').toString().compareTo((a['attendance_date']??'').toString()));return ListView.builder(padding:const EdgeInsets.all(16),itemCount:sorted.length,itemBuilder:(context,index){final r=sorted[index]as Map;return Card(child:ListTile(title:Text((r['attendance_date']??'').toString()),subtitle:Text('${r['status']??'PRESENT'} • ${r['working_hours']??'-'} hours')));});}
}
