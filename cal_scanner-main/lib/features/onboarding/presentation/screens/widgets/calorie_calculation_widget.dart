import 'package:cal_scanner/features/onboarding/presentation/cubit/onboarding_cubit.dart';
import 'package:cal_scanner/features/onboarding/presentation/cubit/onboarding_state.dart';
import 'package:cal_scanner/core/extensions/num_extension.dart';
import 'package:cal_scanner/theme/app_colors.dart';
import 'package:cal_scanner/theme/app_typography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

class CalorieCalculationWidget extends StatelessWidget {
  const CalorieCalculationWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<OnboardingCubit, OnboardingState>(
      builder: (context, state) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Your plan is ready!', style: AppTypography.headlineLarge),
            8.kH,
            Text(
              "Here's your personalized nutrition plan.",
              style: AppTypography.bodyLarge,
            ),
            44.kH,

            // Big calorie number
            Align(
              alignment: Alignment.center,
              child: Text(
                '${state.estimatedCalories}',
                style: const TextStyle(
                  fontSize: 80,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFFF5A623),
                  height: 1,
                ),
              ),
            ),
            4.kH,
            Align(
              alignment: Alignment.center,
              child: Text(
                'Your Daily calories',
                style: AppTypography.bodyLarge.copyWith(
                  color: AppColors.kBlack.withValues(alpha: .6),
                ),
              ),
            ),
            36.kH,

            // Macros pill
            Container(
              margin: EdgeInsets.symmetric(horizontal: 4.w),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 12,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _MacroItem(
                    value: '${state.proteinGoal.toInt()}g',
                    label: 'Protein',
                    color: const Color(0xFF5B8DEF),
                  ),
                  _VerticalDivider(),
                  _MacroItem(
                    value: '${state.carbsGoal.toInt()}g',
                    label: 'Carbs',
                    color: const Color(0xFFF5A623),
                  ),
                  _VerticalDivider(),
                  _MacroItem(
                    value: '${state.fatGoal.toInt()}g',
                    label: 'Fat',
                    color: const Color(0xFFF5654A),
                  ),
                ],
              ),
            ),
            32.kH,

            // Footer
            Align(
              alignment: Alignment.center,
              child: Text(
                "You're all set! Start scanning your meals\nand we'll help you stay on track.",
                textAlign: TextAlign.center,
                style: AppTypography.bodyLarge.copyWith(
                  color: AppColors.kBlack.withValues(alpha: .6),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MacroItem extends StatelessWidget {
  final String value;
  final String label;
  final Color color;

  const _MacroItem({
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: AppTypography.displaySmall.copyWith(
            color: color,
            fontSize: 22.sp,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          label,
          style: TextStyle(
            fontSize: 13.sp,
            fontWeight: FontWeight.w600,
            color: Colors.grey,
          ),
        ),
      ],
    );
  }
}

class _VerticalDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(width: 1, height: 40, color: const Color(0xFFE8E8E8));
  }
}
