import 'dart:io';

import 'package:fpdart/fpdart.dart';

import '../../../../core/error/failure.dart';
import '../../domain/entities/food.dart';
import '../../domain/repositories/food_repository.dart';
import '../datasources/food_local_datasource.dart';
import '../datasources/food_remote_datasource.dart';
import '../models/food_model.dart';

class FoodRepositoryImpl implements FoodRepository {
  final FoodLocalDataSource _local;
  final FoodRemoteDataSource _remote;

  FoodRepositoryImpl(this._local, this._remote);

  @override
  Future<Either<Failure, List<Food>>> getDailyFoodLog(DateTime date) async {
    try {
      final models = await _local.getDailyFoodLog(date);
      return right(models.map((e) => e.toDomain()).toList());
    } catch (e) {
      return left(CacheFailure('Failed to read daily log', cause: e));
    }
  }

  @override
  Future<Either<Failure, Unit>> addFood(Food food) async {
    try {
      final day = DateTime(food.timestamp.year, food.timestamp.month, food.timestamp.day);
      final current = await _local.getDailyFoodLog(day);
      final updated = [...current, FoodModel.fromDomain(food)];
      await _local.setDailyFoodLog(day, updated);
      return right(unit);
    } catch (e) {
      return left(CacheFailure('Failed to add food', cause: e));
    }
  }

  @override
  Future<Either<Failure, Unit>> deleteFood(Food food) async {
    try {
      final day = DateTime(food.timestamp.year, food.timestamp.month, food.timestamp.day);
      final current = await _local.getDailyFoodLog(day);
      final updated = current.where((e) => e.id != food.id).toList();
      await _local.setDailyFoodLog(day, updated);
      return right(unit);
    } catch (e) {
      return left(CacheFailure('Failed to delete food', cause: e));
    }
  }

  @override
  Future<Either<Failure, Unit>> updateFood(Food food) async {
    try {
      final day = DateTime(food.timestamp.year, food.timestamp.month, food.timestamp.day);
      final current = await _local.getDailyFoodLog(day);
      final updated = current
          .map((e) => e.id == food.id ? FoodModel.fromDomain(food) : e)
          .toList();
      await _local.setDailyFoodLog(day, updated);
      return right(unit);
    } catch (e) {
      return left(CacheFailure('Failed to update food', cause: e));
    }
  }

  @override
  Future<Either<Failure, Food>> detectFoodFromImage(File image) {
    return _remote.detectFoodAndCalories(image);
  }

  @override
  Future<Either<Failure, List<double>>> getWeeklyCalories({
    required DateTime endDate,
  }) async {
    try {
      final end = DateTime(endDate.year, endDate.month, endDate.day);
      final days = List.generate(7, (i) => end.subtract(Duration(days: 6 - i)));
      final results = await Future.wait(days.map(_local.getDailyFoodLog));
      final weekly = results
          .map((meals) => meals.fold<double>(0.0, (sum, m) => sum + m.calories))
          .toList();
      return right(weekly);
    } catch (e) {
      return left(CacheFailure('Failed to read weekly calories', cause: e));
    }
  }
}

