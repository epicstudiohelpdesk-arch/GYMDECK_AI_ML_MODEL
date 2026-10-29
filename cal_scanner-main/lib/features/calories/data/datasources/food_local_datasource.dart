import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/food_model.dart';

class FoodLocalDataSource {
  final SharedPreferences _prefs;
  FoodLocalDataSource(this._prefs);

  String _keyForDate(DateTime date) {
    final day = DateTime(date.year, date.month, date.day);
    return 'food_log_${day.toIso8601String().split('T')[0]}';
  }

  Future<List<FoodModel>> getDailyFoodLog(DateTime date) async {
    final key = _keyForDate(date);
    final stored = _prefs.getString(key);
    if (stored == null) return [];
    final decoded = jsonDecode(stored);
    if (decoded is! List) return [];
    return decoded
        .whereType<Map>()
        .map((m) => FoodModel.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  Future<void> setDailyFoodLog(DateTime date, List<FoodModel> items) async {
    final key = _keyForDate(date);
    await _prefs.setString(
      key,
      jsonEncode(items.map((e) => e.toJson()).toList()),
    );
  }
}

