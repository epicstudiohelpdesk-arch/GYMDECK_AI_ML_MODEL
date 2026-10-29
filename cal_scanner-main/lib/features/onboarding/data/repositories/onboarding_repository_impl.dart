import 'package:fpdart/fpdart.dart';

import '../../../../core/error/failure.dart';
import '../../domain/entities/user_data.dart';
import '../../domain/repositories/onboarding_repository.dart';
import '../datasources/onboarding_local_datasource.dart';
import '../models/user_data_model.dart';

class OnboardingRepositoryImpl implements OnboardingRepository {
  final OnboardingLocalDataSource _local;
  OnboardingRepositoryImpl(this._local);

  @override
  Future<Either<Failure, UserData?>> getUserData() async {
    try {
      final model = await _local.getUserData();
      return right(model?.toDomain());
    } catch (e) {
      return left(CacheFailure('Failed to read user data', cause: e));
    }
  }

  @override
  Future<Either<Failure, bool>> isOnboardingComplete() async {
    try {
      final done = await _local.isOnboardingComplete();
      return right(done);
    } catch (e) {
      return left(CacheFailure('Failed to read onboarding status', cause: e));
    }
  }

  @override
  Future<Either<Failure, Unit>> saveUserData(UserData userData) async {
    try {
      await _local.saveUserData(UserDataModel.fromDomain(userData));
      return right(unit);
    } catch (e) {
      return left(CacheFailure('Failed to save user data', cause: e));
    }
  }

  @override
  Future<Either<Failure, Unit>> setOnboardingComplete(bool value) async {
    try {
      await _local.setOnboardingComplete(value);
      return right(unit);
    } catch (e) {
      return left(CacheFailure('Failed to write onboarding status', cause: e));
    }
  }
}

