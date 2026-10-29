import 'package:fpdart/fpdart.dart';

import '../../../../core/error/failure.dart';
import '../entities/food.dart';
import '../repositories/food_repository.dart';

class AddFood {
  final FoodRepository _repo;
  AddFood(this._repo);

  Future<Either<Failure, Unit>> call(Food food) {
    return _repo.addFood(food);
  }
}

