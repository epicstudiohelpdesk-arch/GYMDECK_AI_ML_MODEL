import 'package:cal_scanner/core/extensions/num_extension.dart';
import 'package:cal_scanner/features/onboarding/presentation/cubit/onboarding_cubit.dart';
import 'package:cal_scanner/features/onboarding/presentation/cubit/onboarding_state.dart';
import 'package:cal_scanner/theme/app_colors.dart';
import 'package:cal_scanner/theme/app_typography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

class ActivityWidget extends StatelessWidget {
  const ActivityWidget({super.key});

  static const List<Map<String, String>> _activityLevels = [
    {'label': 'Sedentary', 'description': 'Little or no exercise'},
    {'label': 'Light', 'description': 'Exercise 1-3 days/week'},
    {'label': 'Moderate', 'description': 'Exercise 3-5 days/week'},
    {'label': 'Active', 'description': 'Exercise 6-7 days/week'},
    {'label': 'Very Active', 'description': 'Hard exercise daily'},
  ];

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics:
          const ClampingScrollPhysics(), // ← prevents conflict with PageView
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('How active are you?', style: AppTypography.headlineLarge),
          10.kH,
          Text(
            'Your daily activity affects calorie needs.',
            style: AppTypography.bodyMedium,
          ),
          20.kH,
          BlocBuilder<OnboardingCubit, OnboardingState>(
            builder: (context, state) {
              return Column(
                children: _activityLevels.map((activity) {
                  final label = activity['label']!;
                  final description = activity['description']!;
                  final isSelected = state.activityLevel == label;

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _ActivityCard(
                      label: label,
                      description: description,
                      isSelected: isSelected,
                      onTap: () {
                        context.read<OnboardingCubit>().updateActivityLevel(
                          label,
                        );
                      },
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({
    required this.label,
    required this.description,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final String description;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        width: double.infinity,
        padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10.h),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? Colors.black : Colors.grey.shade200,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: isSelected
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: Colors.black,
                    ),
                  ),
                  2.kH,
                  Text(
                    description,
                    style: AppTypography.bodyMedium.copyWith(
                      color: AppColors.kgrey,
                    ),
                  ),
                ],
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
