import 'package:cal_scanner/core/extensions/num_extension.dart';
import 'package:cal_scanner/features/onboarding/presentation/cubit/onboarding_cubit.dart';
import 'package:cal_scanner/features/onboarding/presentation/cubit/onboarding_state.dart';
import 'package:cal_scanner/theme/app_colors.dart';
import 'package:cal_scanner/theme/app_typography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

enum Gender { male, female }

class GenderWidget extends StatelessWidget {
  const GenderWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'What is your\nbiological sex',
          style: AppTypography.headlineLarge,
        ),
        10.kH,
        Text(
          'This helps us calculate your metabolism',
          style: AppTypography.bodyMedium,
        ),
        Expanded(
          child: Center(
            child: BlocBuilder<OnboardingCubit, OnboardingState>(
              builder: (context, state) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _GenderOption(
                      label: 'Male',
                      icon: Icons.male,
                      isSelected: state.gender == 'Male',
                      onTap: () =>
                          context.read<OnboardingCubit>().updateGender('Male'),
                    ),
                    const SizedBox(height: 8),
                    _GenderOption(
                      label: 'Female',
                      icon: Icons.female,
                      isSelected: state.gender == 'Female',
                      onTap: () => context.read<OnboardingCubit>().updateGender(
                        'Female',
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _GenderOption extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _GenderOption({
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        decoration: BoxDecoration(
          color: AppColors.kWhite,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? AppColors.kBlack
                : AppColors.kgrey.withValues(alpha: .2),
            width: isSelected ? 2 : 0.5,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 25,
              color: isSelected ? AppColors.kBlack : AppColors.kgrey,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: AppTypography.headlineSmall.copyWith(
                  color: isSelected ? Colors.black : Colors.grey,
                ),
              ),
            ),
            if (isSelected)
              Container(
                width: 20,
                height: 20,
                decoration: const BoxDecoration(
                  color: Colors.black,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check, size: 13, color: Colors.white),
              ),
          ],
        ),
      ),
    );
  }
}
