import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';

/// Audit Logging Service
/// Provides comprehensive audit logging for all critical operations
/// Helps track data changes, user actions, and system events for troubleshooting
class AuditLoggingService {
  static AuditLoggingService? _instance;
  static const String _auditLogKey = 'audit_log';
  static const int _maxLogEntries = 500; // Keep last 500 log entries
  
  AuditLoggingService._();
  
  static AuditLoggingService get instance {
    _instance ??= AuditLoggingService._();
    return _instance!;
  }
  
  /// Log an audit event
  Future<void> logEvent(AuditEvent event) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final logJson = prefs.getString(_auditLogKey) ?? '[]';
      final List<dynamic> log = json.decode(logJson);
      
      // Add new event
      log.add(event.toJson());
      
      // Trim log if too large
      if (log.length > _maxLogEntries) {
        final removeCount = log.length - _maxLogEntries;
        for (int i = 0; i < removeCount; i++) {
          log.removeAt(0);
        }
      }
      
      await prefs.setString(_auditLogKey, json.encode(log));
      
      if (kDebugMode) {
        debugPrint('📝 Audit log: [${event.type}] ${event.action} - ${event.description}');
      }
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error logging audit event: $e');
    }
  }
  
  /// Log a data operation
  Future<void> logDataOperation(String dataType, String operation, Map<String, dynamic> details) async {
    final event = AuditEvent(
      type: AuditType.dataOperation,
      action: operation,
      description: '$operation on $dataType',
      details: details,
      dataType: dataType,
    );
    await logEvent(event);
  }
  
  /// Log a sync operation
  Future<void> logSyncOperation(String syncType, bool success, {String? error}) async {
    final event = AuditEvent(
      type: AuditType.syncOperation,
      action: syncType,
      description: 'Sync: $syncType - ${success ? "Success" : "Failed"}',
      success: success,
      error: error,
    );
    await logEvent(event);
  }
  
  /// Log a user action
  Future<void> logUserAction(String action, Map<String, dynamic> context) async {
    final event = AuditEvent(
      type: AuditType.userAction,
      action: action,
      description: 'User action: $action',
      details: context,
    );
    await logEvent(event);
  }
  
  /// Log a system event
  Future<void> logSystemEvent(String event, Map<String, dynamic> details) async {
    final auditEvent = AuditEvent(
      type: AuditType.systemEvent,
      action: event,
      description: 'System event: $event',
      details: details,
    );
    await logEvent(auditEvent);
  }
  
  /// Log an error
  Future<void> logError(String error, {String? context, Map<String, dynamic>? details}) async {
    final event = AuditEvent(
      type: AuditType.error,
      action: 'error',
      description: 'Error: $error',
      error: error,
      context: context,
      details: details,
    );
    await logEvent(event);
  }
  
  /// Log a security event
  Future<void> logSecurityEvent(String event, Map<String, dynamic> details) async {
    final auditEvent = AuditEvent(
      type: AuditType.securityEvent,
      action: event,
      description: 'Security event: $event',
      details: details,
    );
    await logEvent(auditEvent);
  }
  
  /// Get audit log
  Future<List<AuditEvent>> getAuditLog({int? limit, DateTime? startDate, DateTime? endDate}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final logJson = prefs.getString(_auditLogKey) ?? '[]';
      final List<dynamic> log = json.decode(logJson);
      
      final events = log.map((e) => AuditEvent.fromJson(e as Map<String, dynamic>)).toList();
      
      // Filter by date range if specified
      if (startDate != null || endDate != null) {
        events.removeWhere((event) {
          if (startDate != null && event.timestamp.isBefore(startDate)) return true;
          if (endDate != null && event.timestamp.isAfter(endDate)) return true;
          return false;
        });
      }
      
      // Sort by timestamp (newest first)
      events.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      
      // Apply limit if specified
      if (limit != null && events.length > limit) {
        return events.sublist(0, limit);
      }
      
      return events;
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error getting audit log: $e');
      return [];
    }
  }
  
  /// Get events by type
  Future<List<AuditEvent>> getEventsByType(AuditType type, {int? limit}) async {
    final allEvents = await getAuditLog();
    final filtered = allEvents.where((e) => e.type == type).toList();
    
    if (limit != null && filtered.length > limit) {
      return filtered.sublist(0, limit);
    }
    
    return filtered;
  }
  
  /// Search audit log
  Future<List<AuditEvent>> searchAuditLog(String query) async {
    final allEvents = await getAuditLog();
    final lowerQuery = query.toLowerCase();
    
    return allEvents.where((event) =>
      event.action.toLowerCase().contains(lowerQuery) ||
      event.description.toLowerCase().contains(lowerQuery) ||
      (event.error?.toLowerCase().contains(lowerQuery) ?? false)
    ).toList();
  }
  
  /// Clear audit log
  Future<void> clearAuditLog() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_auditLogKey);
      if (kDebugMode) debugPrint('🗑️ Audit log cleared');
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error clearing audit log: $e');
    }
  }
  
  /// Export audit log
  Future<String> exportAuditLog() async {
    try {
      final events = await getAuditLog();
      final logEntries = events.map((e) => e.toExportString()).join('\n');
      return 'AUDIT LOG EXPORT\nGenerated: ${DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now())}\n\n$logEntries';
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error exporting audit log: $e');
      return '';
    }
  }
  
  /// Get audit statistics
  Future<AuditStatistics> getAuditStatistics() async {
    final events = await getAuditLog();
    final stats = AuditStatistics();
    
    for (final event in events) {
      stats.totalEvents++;
      
      switch (event.type) {
        case AuditType.dataOperation:
          stats.dataOperations++;
          break;
        case AuditType.syncOperation:
          stats.syncOperations++;
          if (event.success == false) stats.failedSyncs++;
          break;
        case AuditType.userAction:
          stats.userActions++;
          break;
        case AuditType.systemEvent:
          stats.systemEvents++;
          break;
        case AuditType.error:
          stats.errors++;
          break;
        case AuditType.securityEvent:
          stats.securityEvents++;
          break;
      }
    }
    
    return stats;
  }
}

/// Audit event
class AuditEvent {
  final AuditType type;
  final String action;
  final String description;
  final DateTime timestamp;
  final bool? success;
  final String? error;
  final String? context;
  final Map<String, dynamic>? details;
  final String? dataType;
  
  AuditEvent({
    required this.type,
    required this.action,
    required this.description,
    DateTime? timestamp,
    this.success,
    this.error,
    this.context,
    this.details,
    this.dataType,
  }) : timestamp = timestamp ?? DateTime.now();
  
  Map<String, dynamic> toJson() {
    return {
      'type': type.toString(),
      'action': action,
      'description': description,
      'timestamp': timestamp.toIso8601String(),
      'success': success,
      'error': error,
      'context': context,
      'details': details,
      'data_type': dataType,
    };
  }
  
  static AuditEvent fromJson(Map<String, dynamic> json) {
    return AuditEvent(
      type: _parseAuditType(json['type']),
      action: json['action'],
      description: json['description'],
      timestamp: DateTime.parse(json['timestamp']),
      success: json['success'],
      error: json['error'],
      context: json['context'],
      details: json['details'],
      dataType: json['data_type'],
    );
  }
  
  String toExportString() {
    final buffer = StringBuffer();
    buffer.writeln('[${DateFormat('yyyy-MM-dd HH:mm:ss').format(timestamp)}] ${type.name.toUpperCase()}');
    buffer.writeln('  Action: $action');
    buffer.writeln('  Description: $description');
    if (success != null) buffer.writeln('  Success: $success');
    if (error != null) buffer.writeln('  Error: $error');
    if (context != null) buffer.writeln('  Context: $context');
    if (details != null && details!.isNotEmpty) {
      buffer.writeln('  Details:');
      details!.forEach((key, value) {
        buffer.writeln('    $key: $value');
      });
    }
    return buffer.toString();
  }
  
  static AuditType _parseAuditType(String typeString) {
    switch (typeString) {
      case 'AuditType.dataOperation':
        return AuditType.dataOperation;
      case 'AuditType.syncOperation':
        return AuditType.syncOperation;
      case 'AuditType.userAction':
        return AuditType.userAction;
      case 'AuditType.systemEvent':
        return AuditType.systemEvent;
      case 'AuditType.error':
        return AuditType.error;
      case 'AuditType.securityEvent':
        return AuditType.securityEvent;
      default:
        return AuditType.systemEvent;
    }
  }
}

/// Audit type enum
enum AuditType {
  dataOperation,
  syncOperation,
  userAction,
  systemEvent,
  error,
  securityEvent,
}

/// Audit statistics
class AuditStatistics {
  int totalEvents = 0;
  int dataOperations = 0;
  int syncOperations = 0;
  int failedSyncs = 0;
  int userActions = 0;
  int systemEvents = 0;
  int errors = 0;
  int securityEvents = 0;
  
  double get syncSuccessRate {
    if (syncOperations == 0) return 0.0;
    return ((syncOperations - failedSyncs) / syncOperations) * 100;
  }
}