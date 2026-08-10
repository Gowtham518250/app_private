import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';

/// WorkerLocalStorage - Simple local-only worker storage
/// Saves workers to unique preference key: workers_${shopkeeper_id}
/// Only stores: name, phone, position, salary, pin, id
class WorkerLocalStorage {
  
  /// Get unique storage key for a shopkeeper
  static String getWorkerPreferenceKey(int shopkeeperId) {
    return 'workers_$shopkeeperId';
  }
  
  /// Fetch all workers for current shopkeeper
  static Future<List<Worker>> fetchWorkers(int shopkeeperId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = getWorkerPreferenceKey(shopkeeperId);
      
      final workersJson = prefs.getString(key);
      if (workersJson == null) return [];
      
      final List<dynamic> decoded = jsonDecode(workersJson);
      return decoded.map((w) => Worker.fromJson(w as Map<String, dynamic>)).toList();
    } catch (e) {
      print('❌ Error fetching workers: $e');
      return [];
    }
  }
  
  /// Get single worker by name (returns first match)
  static Future<Worker?> getWorkerByName(int shopkeeperId, String name) async {
    final workers = await fetchWorkers(shopkeeperId);
    try {
      return workers.firstWhere((w) => w.name.toLowerCase() == name.toLowerCase());
    } catch (e) {
      return null;
    }
  }
  
  /// Check if worker exists by name
  static Future<bool> workerExists(int shopkeeperId, String name) async {
    final worker = await getWorkerByName(shopkeeperId, name);
    return worker != null;
  }
  
  /// Get all worker names as list (useful for dropdowns)
  static Future<List<String>> getWorkerNames(int shopkeeperId) async {
    final workers = await fetchWorkers(shopkeeperId);
    return workers.map((w) => w.name).toList();
  }
  
  /// Get worker count
  static Future<int> getWorkerCount(int shopkeeperId) async {
    final workers = await fetchWorkers(shopkeeperId);
    return workers.length;
  }
  
  /// Clear all workers for a shopkeeper
  static Future<void> clearWorkers(int shopkeeperId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = getWorkerPreferenceKey(shopkeeperId);
      await prefs.remove(key);
      print('✅ All workers cleared for shopkeeper $shopkeeperId');
    } catch (e) {
      print('❌ Error clearing workers: $e');
    }
  }
}
