import 'dart:io';

import 'package:fpdart/fpdart.dart';

import '../../../../core/error/failure.dart';
import '../entities/food.dart';

abstract class FoodRepository {
  Future<Either<Failure, List<Food>>> getDailyFoodLog(DateTime date);
  Future<Either<Failure, Unit>> addFood(Food food);
  Future<Either<Failure, Unit>> deleteFood(Food food);
  Future<Either<Failure, Unit>> updateFood(Food food);

  Future<Either<Failure, Food>> detectFoodFromImage(File image);

  Future<Either<Failure, List<double>>> getWeeklyCalories({
    required DateTime endDate,
  });
}

