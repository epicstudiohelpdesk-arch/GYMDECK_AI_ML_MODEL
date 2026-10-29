class OnboardingState {
  final double? weight;
  final double? height;
  final int? age;
  final String activityLevel;
  final String gender;
  final String userGoal;
  final int estimatedCalories;
  // macros
  final double proteinGoal;
  final double fatGoal;
  final double carbsGoal;
  final String? error;

  const OnboardingState({
    this.weight,
    this.height,
    this.age,
    this.activityLevel = 'Moderate',
    this.gender = 'Male',
    this.userGoal = 'Weight Loss',
    this.estimatedCalories = 0,
    this.proteinGoal = 0,
    this.fatGoal = 0,
    this.carbsGoal = 0,
    this.error,
  });

  OnboardingState copyWith({
    double? weight,
    double? height,
    int? age,
    String? activityLevel,
    String? gender,
    String? userGoal,
    int? estimatedCalories,
    double? proteinGoal,
    double? fatGoal,
    double? carbsGoal,
    String? error,
  }) {
    return OnboardingState(
      weight: weight ?? this.weight,
      height: height ?? this.height,
      age: age ?? this.age,
      activityLevel: activityLevel ?? this.activityLevel,
      gender: gender ?? this.gender,
      userGoal: userGoal ?? this.userGoal,
      estimatedCalories: estimatedCalories ?? this.estimatedCalories,
      proteinGoal: proteinGoal ?? this.proteinGoal,
      fatGoal: fatGoal ?? this.fatGoal,
      carbsGoal: carbsGoal ?? this.carbsGoal,
      error: error ?? this.error,
    );
  }
}
