import 'package:fpdart/fpdart.dart';

import '../../../../core/error/failure.dart';
import '../entities/food.dart';
import '../repositories/food_repository.dart';

class UpdateFood {
  final FoodRepository _repo;
  UpdateFood(this._repo);

  Future<Either<Failure, Unit>> call(Food food) {
    return _repo.updateFood(food);
  }
}

