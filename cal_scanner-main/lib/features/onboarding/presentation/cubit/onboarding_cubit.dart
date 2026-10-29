import 'package:flutter_bloc/flutter_bloc.dart';
import 'onboarding_state.dart';
import '../../domain/usecases/calculate_goals.dart';
import '../../domain/usecases/mark_onboarding_complete.dart';
import '../../domain/usecases/save_user_data.dart';

class OnboardingCubit extends Cubit<OnboardingState> {
  final CalculateGoals _calculateGoals;
  final SaveUserData _saveUserData;
  final MarkOnboardingComplete _markOnboardingComplete;

  OnboardingCubit(
    this._calculateGoals,
    this._saveUserData,
    this._markOnboardingComplete,
  ) : super(const OnboardingState());

  void updateWeight(double value) => emit(state.copyWith(weight: value));
  void updateHeight(double value) => emit(state.copyWith(height: value));
  void updateAge(int value) => emit(state.copyWith(age: value));
  void updateActivityLevel(String value) =>
      emit(state.copyWith(activityLevel: value));
  void updateGender(String value) => emit(state.copyWith(gender: value));
  void updateGoal(String value) => emit(state.copyWith(userGoal: value));

  Future<void> saveAndCalculate() async {
    double heightToCm(double feetInches) {
      final parts = feetInches.toString().split('.');
      final feet = int.parse(parts[0]);
      final inches = parts.length > 1 ? int.parse(parts[1]) : 0;
      final totalInches = (feet * 12) + inches;
      return totalInches * 2.54;
    }

    final heightInCm = heightToCm(state.height!);
    final calc = await _calculateGoals(
      weight: state.weight!,
      heightCm: heightInCm,
      age: state.age!,
      activityLevel: state.activityLevel,
      gender: state.gender,
      goal: state.userGoal,
    );

    await calc.match(
      (l) async => emit(state.copyWith(error: l.message)),
      (userData) async {
        emit(
          state.copyWith(
            estimatedCalories: userData.estimatedCalories,
            proteinGoal: userData.proteinGoal.toDouble(),
            fatGoal: userData.fatGoal.toDouble(),
            carbsGoal: userData.carbsGoal.toDouble(),
            error: null,
          ),
        );
        await _saveUserData(userData);
        await _markOnboardingComplete();
      },
    );
  }
}
