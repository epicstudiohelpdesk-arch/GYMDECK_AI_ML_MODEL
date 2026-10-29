import 'package:fpdart/fpdart.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/utils/calorie_calculator.dart';
import '../entities/user_data.dart';

class CalculateGoals {
  Future<Either<Failure, UserData>> call({
    required double weight,
    required double heightCm,
    required int age,
    required String activityLevel,
    required String gender,
    required String goal,
  }) async {
    try {
      final maintenance = CalorieCalculator.fallbackEstimateCalories(
        weight: weight,
        height: heightCm,
        age: age,
        activityLevel: activityLevel,
        gender: gender,
      );

      final adjusted = CalorieCalculator.calculateCaloriesBasedOnGoal(
        maintenanceCalories: maintenance,
        goal: goal,
      );

      final macros = CalorieCalculator.calculateMacroGoals(
        calories: adjusted,
        goal: goal,
      );

      return right(
        UserData(
          weight: weight,
          heightCm: heightCm,
          age: age,
          activityLevel: activityLevel,
          gender: gender,
          goal: goal,
          estimatedCalories: adjusted,
          proteinGoal: macros['proteinGoal']!,
          fatGoal: macros['fatGoal']!,
          carbsGoal: macros['carbsGoal']!,
        ),
      );
    } catch (e) {
      return left(Failure('Failed to calculate goals', cause: e));
    }
  }
}

