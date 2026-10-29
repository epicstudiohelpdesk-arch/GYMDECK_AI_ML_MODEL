import 'package:cal_scanner/core/extensions/widget_extension.dart';
import 'package:cal_scanner/theme/app_colors.dart';
import 'package:cal_scanner/theme/app_typography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:percent_indicator/circular_percent_indicator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../onboarding/data/local/preference_manager.dart';
import '../../../onboarding/data/models/user_data.dart';
import 'macro_indicator.dart';

class DailyTracker extends StatefulWidget {
  final double calories;
  final double protein;
  final double carbs;
  final double fat;

  const DailyTracker({
    super.key,
    required this.calories,
    required this.protein,
    required this.carbs,
    required this.fat,
  });

  @override
  State<DailyTracker> createState() => _DailyTrackerState();
}

class _DailyTrackerState extends State<DailyTracker> {
  UserData? userData;

  @override
  void initState() {
    super.initState();
    _loadUserData();
  }

  Future<void> _loadUserData() async {
    final prefs = await SharedPreferences.getInstance();
    final prefManager = PreferenceManager(prefs);
    userData = prefManager.getUserData();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final targetCalories = userData?.estimatedCalories.toDouble() ?? 2000.0;

    return Column(
      children: [
        // ),
        CircularPercentIndicator(
          backgroundColor: AppColors.kPrimaryGrey,
          radius: 90.sp,
          lineWidth: 14.0,
          percent: (widget.calories / targetCalories.toDouble()).clamp(
            0.0,
            1.0,
          ),
          center: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Icon(Icons.local_fire_department, color: Colors.orange),
              Text(
                widget.calories.toInt().toString(),
                style: AppTypography.displayLarge,
              ),
              SizedBox(height: 5.h),

              Text(
                'of ${targetCalories.toInt()} kcal',
                style: AppTypography.titleMedium.copyWith(
                  color: AppColors.kgrey,
                ),
              ),
            ],
          ),
          progressColor: Colors.orange,
        ),
        SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            MacroIndicator(
              label: 'Protein',
              value: widget.protein,
              goal: (userData?.proteinGoal ?? 0).toDouble(),
              color: Colors.green,
            ),
            MacroIndicator(
              label: 'Fats',
              value: widget.fat,
              goal: (userData?.fatGoal ?? 0).toDouble(),
              color: Colors.orange,
            ),
            MacroIndicator(
              label: 'Carbs',
              value: widget.carbs,
              goal: (userData?.carbsGoal ?? 0).toDouble(),
              color: Colors.amber,
            ),
          ],
        ).paddingSymmetric(horizontal: 10),
      ],
    );
  }
}
