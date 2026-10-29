import 'package:fpdart/fpdart.dart';

import '../../../../core/error/failure.dart';
import '../repositories/onboarding_repository.dart';

class MarkOnboardingComplete {
  final OnboardingRepository _repo;
  MarkOnboardingComplete(this._repo);

  Future<Either<Failure, Unit>> call() {
    return _repo.setOnboardingComplete(true);
  }
}

