import 'package:fpdart/fpdart.dart';

import '../../../../core/error/failure.dart';
import '../entities/user_data.dart';

abstract class OnboardingRepository {
  Future<Either<Failure, Unit>> saveUserData(UserData userData);
  Future<Either<Failure, UserData?>> getUserData();

  Future<Either<Failure, bool>> isOnboardingComplete();
  Future<Either<Failure, Unit>> setOnboardingComplete(bool value);
}

