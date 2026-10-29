import 'package:fpdart/fpdart.dart';

import '../../../../core/error/failure.dart';
import '../repositories/food_repository.dart';

class GetWeeklyCalories {
  final FoodRepository _repo;
  GetWeeklyCalories(this._repo);

  Future<Either<Failure, List<double>>> call({required DateTime endDate}) {
    return _repo.getWeeklyCalories(endDate: endDate);
  }
}

