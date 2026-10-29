import '../../domain/entities/user_data.dart';

class UserDataModel {
  final double weight;
  final double heightCm;
  final int age;
  final String activityLevel;
  final String gender;
  final String goal;
  final int estimatedCalories;
  final int proteinGoal;
  final int fatGoal;
  final int carbsGoal;

  const UserDataModel({
    required this.weight,
    required this.heightCm,
    required this.age,
    required this.activityLevel,
    required this.gender,
    required this.goal,
    required this.estimatedCalories,
    required this.proteinGoal,
    required this.fatGoal,
    required this.carbsGoal,
  });

  factory UserDataModel.fromJson(Map<String, dynamic> json) {
    return UserDataModel(
      weight: (json['weight'] as num).toDouble(),
      heightCm: (json['height'] as num).toDouble(),
      age: json['age'] as int,
      activityLevel: json['activityLevel'] as String,
      gender: json['gender'] as String,
      goal: json['goal'] as String,
      estimatedCalories: json['estimatedCalories'] as int,
      proteinGoal: json['proteinGoal'] as int,
      fatGoal: json['fatGoal'] as int,
      carbsGoal: json['carbsGoal'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'weight': weight,
      'height': heightCm,
      'age': age,
      'activityLevel': activityLevel,
      'gender': gender,
      'goal': goal,
      'estimatedCalories': estimatedCalories,
      'proteinGoal': proteinGoal,
      'fatGoal': fatGoal,
      'carbsGoal': carbsGoal,
    };
  }

  UserData toDomain() {
    return UserData(
      weight: weight,
      heightCm: heightCm,
      age: age,
      activityLevel: activityLevel,
      gender: gender,
      goal: goal,
      estimatedCalories: estimatedCalories,
      proteinGoal: proteinGoal,
      fatGoal: fatGoal,
      carbsGoal: carbsGoal,
    );
  }

  factory UserDataModel.fromDomain(UserData userData) {
    return UserDataModel(
      weight: userData.weight,
      heightCm: userData.heightCm,
      age: userData.age,
      activityLevel: userData.activityLevel,
      gender: userData.gender,
      goal: userData.goal,
      estimatedCalories: userData.estimatedCalories,
      proteinGoal: userData.proteinGoal,
      fatGoal: userData.fatGoal,
      carbsGoal: userData.carbsGoal,
    );
  }
}

