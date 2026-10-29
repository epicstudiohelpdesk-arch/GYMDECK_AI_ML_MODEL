import 'package:fpdart/fpdart.dart';

import '../../../../core/error/failure.dart';
import '../entities/food.dart';
import '../repositories/food_repository.dart';

class DeleteFood {
  final FoodRepository _repo;
  DeleteFood(this._repo);

  Future<Either<Failure, Unit>> call(Food food) {
    return _repo.deleteFood(food);
  }
}

