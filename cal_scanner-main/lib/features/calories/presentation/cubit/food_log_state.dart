import 'dart:io';

import '../../domain/entities/food.dart';

class FoodLogState {
  final List<Food> meals;
  final double totalCalories;
  final double totalProtein;
  final double totalCarbs;
  final double totalFat;
  final List<double> weeklyData;
  final bool isLoading;
  final String? error;
  final String? successMessage;
  // Image Picking
  final File? selectedImage;
  final bool isScanning; // NEW
  final Food? scannedMeal;
  final DateTime selectedDate;

  FoodLogState({
    this.meals = const [],
    this.totalCalories = 0,
    this.totalProtein = 0,
    this.totalCarbs = 0,
    this.totalFat = 0,
    this.weeklyData = const [],
    this.isLoading = false,
    this.error,
    this.successMessage,
    this.selectedImage,
    this.scannedMeal,
    this.isScanning = false,
    DateTime? selectedDate,
  }) : selectedDate = selectedDate ?? DateTime.now();

  FoodLogState copyWith({
    List<Food>? meals,
    double? totalCalories,
    double? totalProtein,
    double? totalCarbs,
    double? totalFat,
    List<double>? weeklyData,
    bool? isLoading,
    String? error,
    String? successMessage,
    File? selectedImage,
    bool? isScanning,
    Food? scannedMeal,
    bool clearScannedMeal = false,
    bool clearError = false,
    DateTime? selectedDate,
  }) {
    return FoodLogState(
      meals: meals ?? this.meals,
      totalCalories: totalCalories ?? this.totalCalories,
      totalProtein: totalProtein ?? this.totalProtein,
      totalCarbs: totalCarbs ?? this.totalCarbs,
      totalFat: totalFat ?? this.totalFat,
      weeklyData: weeklyData ?? this.weeklyData,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : error ?? this.error,
      successMessage: successMessage ?? this.successMessage,
      selectedImage: selectedImage ?? this.selectedImage,
      isScanning: isScanning ?? this.isScanning,
      scannedMeal: clearScannedMeal ? null : scannedMeal ?? this.scannedMeal,
      selectedDate: selectedDate ?? this.selectedDate,
    );
  }
}
