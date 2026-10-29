import 'package:fpdart/fpdart.dart';

import '../../../../core/error/failure.dart';
import '../entities/user_data.dart';
import '../repositories/onboarding_repository.dart';

class SaveUserData {
  final OnboardingRepository _repo;
  SaveUserData(this._repo);

  Future<Either<Failure, Unit>> call(UserData userData) {
    return _repo.saveUserData(userData);
  }
}

