import 'dart:io';

import 'package:cal_scanner/features/calories/presentation/cubit/food_log_state.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/entities/food.dart';
import '../../domain/usecases/add_food.dart';
import '../../domain/usecases/delete_food.dart';
import '../../domain/usecases/detect_food_from_image.dart';
import '../../domain/usecases/get_daily_food_log.dart';
import '../../domain/usecases/get_weekly_calories.dart';
import '../../domain/usecases/update_food.dart';

class FoodLogCubit extends Cubit<FoodLogState> {
  final GetDailyFoodLog _getDailyFoodLog;
  final GetWeeklyCalories _getWeeklyCalories;
  final AddFood _addFood;
  final DeleteFood _deleteFood;
  final UpdateFood _updateFood;
  final DetectFoodFromImage _detectFoodFromImage;

  FoodLogCubit(
    this._getDailyFoodLog,
    this._getWeeklyCalories,
    this._addFood,
    this._deleteFood,
    this._updateFood,
    this._detectFoodFromImage,
  ) : super(FoodLogState());

  // fetch data view date

  Future<void> selectDate(DateTime date) async {
    final normalized = DateTime(date.year, date.month, date.day);

    emit(state.copyWith(selectedDate: normalized));
    await loadDailyLog();
  }

  Future<void> loadDailyLog({Food? preserveScannedMeal}) async {
    emit(state.copyWith(isLoading: true));
    final mealsResult = await _getDailyFoodLog(state.selectedDate);
    final weeklyResult = await _getWeeklyCalories(endDate: DateTime.now());

    if (mealsResult.isLeft()) {
      emit(
        state.copyWith(
          error: mealsResult.fold((l) => l.message, (_) => null),
          isLoading: false,
        ),
      );
      return;
    }
    if (weeklyResult.isLeft()) {
      emit(
        state.copyWith(
          error: weeklyResult.fold((l) => l.message, (_) => null),
          isLoading: false,
        ),
      );
      return;
    }

    final meals = mealsResult.getOrElse((_) => const <Food>[]);
    final weeklyData = weeklyResult.getOrElse((_) => const <double>[]);
    final totals = _calculateTotals(meals);

    emit(
      state.copyWith(
        meals: meals,
        totalCalories: totals['calories'],
        totalProtein: totals['protein'],
        totalCarbs: totals['carbs'],
        totalFat: totals['fat'],
        weeklyData: weeklyData,
        isLoading: false,
        scannedMeal: preserveScannedMeal ?? state.scannedMeal,
        clearError: true,
      ),
    );
  }

  Future<void> addMeal(Food meal) async {
    final result = await _addFood(meal);
    result.match(
      (l) => emit(state.copyWith(error: l.message)),
      (_) async => loadDailyLog(),
    );
  }

  Map<String, double> _calculateTotals(List<Food> meals) {
    return meals.fold(
      {'calories': 0.0, 'protein': 0.0, 'carbs': 0.0, 'fat': 0.0},
      (totals, meal) {
        totals['calories'] = (totals['calories'] ?? 0) + meal.calories;
        totals['protein'] = (totals['protein'] ?? 0) + meal.protein;
        totals['carbs'] = (totals['carbs'] ?? 0) + meal.carbs;
        totals['fat'] = (totals['fat'] ?? 0) + meal.fat;
        return totals;
      },
    );
  }

  Future<void> addMealFromImage(File image) async {
    emit(state.copyWith(isScanning: true, selectedImage: image));
    final result = await _detectFoodFromImage(image);
    result.fold(
      (failure) {
        emit(
          state.copyWith(
            error: failure.message,
            successMessage: null,
            isScanning: false,
          ),
        );
      },
      (meal) async {
        emit(
          state.copyWith(
            scannedMeal: meal,
            isScanning: false,
            error: null,
            successMessage: 'Food "${meal.name}" detected successfully',
          ),
        );
        await _addFood(meal);
        await loadDailyLog(preserveScannedMeal: meal);
      },
    );
  }

  void clearMessages() {
    emit(
      FoodLogState(
        meals: state.meals,
        totalCalories: state.totalCalories,
        totalProtein: state.totalProtein,
        totalCarbs: state.totalCarbs,
        totalFat: state.totalFat,
        weeklyData: state.weeklyData,
        isLoading: state.isLoading,
        error: null,
        successMessage: null,
        selectedImage: state.selectedImage,
        isScanning: state.isScanning,
        scannedMeal: state.scannedMeal,
        selectedDate: state.selectedDate,
      ),
    );
  }

  Future<void> deleteMeal(Food meal) async {
    final result = await _deleteFood(meal);
    result.match(
      (l) => emit(state.copyWith(error: l.message)),
      (_) async => loadDailyLog(),
    );
  }

  Future<void> updateMeal(Food meal) async {
    final result = await _updateFood(meal);
    result.match(
      (l) => emit(state.copyWith(error: l.message)),
      (_) async => loadDailyLog(),
    );
  }

  // re-build the UI at midnight for changes if user has't restart the app or crashed

  Future<void> refreshForNewDay() async {
    final today = DateTime.now();
    final normalized = DateTime(today.year, today.month, today.day);
    emit(state.copyWith(selectedDate: normalized));
    await loadDailyLog();
  }
}
