import 'package:fpdart/fpdart.dart';

import '../../../../core/error/failure.dart';
import '../entities/food.dart';
import '../repositories/food_repository.dart';

class GetDailyFoodLog {
  final FoodRepository _repo;
  GetDailyFoodLog(this._repo);

  Future<Either<Failure, List<Food>>> call(DateTime date) {
    return _repo.getDailyFoodLog(date);
  }
}

