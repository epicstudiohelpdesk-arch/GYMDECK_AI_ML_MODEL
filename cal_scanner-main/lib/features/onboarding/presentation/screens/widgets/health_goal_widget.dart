import 'package:cal_scanner/core/extensions/num_extension.dart';
import 'package:cal_scanner/features/onboarding/presentation/cubit/onboarding_cubit.dart';
import 'package:cal_scanner/features/onboarding/presentation/cubit/onboarding_state.dart';
import 'package:cal_scanner/theme/app_colors.dart';
import 'package:cal_scanner/theme/app_typography.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

class HealthGoalWidget extends StatelessWidget {
  const HealthGoalWidget({super.key});

  static const _goals = [
    _GoalOption(
      value: 'Weight Loss',
      label: 'Lose Weight',
      icon: Icons.trending_down_rounded,
    ),
    _GoalOption(
      value: 'Maintenance',
      label: 'Maintain',
      icon: CupertinoIcons.arrow_2_squarepath,
    ),
    _GoalOption(
      value: 'Muscle Gain',
      label: 'Gain Weight',
      icon: Icons.trending_up_rounded,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('What is your\ngoal?', style: AppTypography.headlineLarge),
        10.kH,
        Text(
          "We'll adjust your daily calories accordingly.",
          style: AppTypography.bodyMedium,
        ),
        Expanded(
          child: BlocBuilder<OnboardingCubit, OnboardingState>(
            builder: (context, state) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: _goals.map((goal) {
                    final isSelected = state.userGoal == goal.value;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _GoalCard(
                        goal: goal,
                        isSelected: isSelected,
                        onTap: () => context.read<OnboardingCubit>().updateGoal(
                          goal.value,
                        ),
                      ),
                    );
                  }).toList(),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _GoalOption {
  final String value;
  final String label;
  final IconData icon;

  const _GoalOption({
    required this.value,
    required this.label,
    required this.icon,
  });
}

class _GoalCard extends StatelessWidget {
  final _GoalOption goal;
  final bool isSelected;
  final VoidCallback onTap;

  const _GoalCard({
    required this.goal,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        width: double.infinity,
        padding: EdgeInsets.symmetric(horizontal: 20, vertical: 18.h),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? Colors.black : Colors.grey.shade200,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              goal.icon,
              size: 25.sp,
              color: isSelected ? AppColors.kPureBlack : AppColors.kgrey,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                goal.label,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  color: isSelected ? AppColors.kPureBlack : AppColors.kgrey,
                ),
              ),
            ),
            if (isSelected)
              CircleAvatar(
                radius: 12.sp,
                backgroundColor: Colors.black,

                child: const Icon(Icons.check, color: Colors.white, size: 16),
              ),
          ],
        ),
      ),
    );
  }
}
