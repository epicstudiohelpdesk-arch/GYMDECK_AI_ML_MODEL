import 'package:cal_scanner/app_widgets/buttons/app_button.dart';
import 'package:cal_scanner/app_widgets/buttons/back_button.dart';
import 'package:cal_scanner/core/extensions/widget_extension.dart';
import 'package:cal_scanner/features/onboarding/presentation/cubit/onboarding_cubit.dart';
import 'package:cal_scanner/features/onboarding/presentation/screens/widgets/activity_widget.dart';
import 'package:cal_scanner/features/onboarding/presentation/screens/widgets/age_widget.dart';
import 'package:cal_scanner/features/onboarding/presentation/screens/widgets/calorie_calculation_widget.dart';
import 'package:cal_scanner/features/onboarding/presentation/screens/widgets/gender_widget.dart';
import 'package:cal_scanner/features/onboarding/presentation/screens/widgets/health_goal_widget.dart';
import 'package:cal_scanner/features/onboarding/presentation/screens/widgets/height_widget.dart';
import 'package:cal_scanner/theme/app_colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../../core/routes/app_routes.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  OnboardingScreenState createState() => OnboardingScreenState();
}

class OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  static const int _totalPages = 6;
  static const int _lastPage = _totalPages - 1;

  Future<void> _nextPage() async {
    if (_currentPage == _lastPage) {
      context.go(AppRoutes.main);
    } else {
      if (_currentPage == _lastPage - 1) {
        await context.read<OnboardingCubit>().saveAndCalculate();
      }

      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _previousPage() {
    _pageController.previousPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4.0),
          child: Row(
            children: [
              Visibility(
                visible: _currentPage != 0,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: AppBackButton(
                  onPressed: () => _previousPage(),
                ).paddingOnly(right: 10),
              ),
              Expanded(
                child: LinearProgressIndicator(
                  borderRadius: BorderRadius.circular(5),
                  value: (_currentPage + 1) / _totalPages,
                  backgroundColor: AppColors.kLightGrey,
                  valueColor: AlwaysStoppedAnimation(AppColors.kBlack),
                ).paddingOnly(right: 40.0),
              ),
            ],
          ),
        ),
      ),
      body: PageView(
        controller: _pageController,
        physics: const NeverScrollableScrollPhysics(),
        onPageChanged: (index) => setState(() => _currentPage = index),
        children: const [
          GenderWidget(),
          AgeWidget(),
          HeightWeightWidget(),
          ActivityWidget(),
          HealthGoalWidget(),
          CalorieCalculationWidget(),
        ],
      ).paddingOnly(left: 20.0, right: 20, top: 20),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: AppButton(
            text: _currentPage == _lastPage ? 'Get Started' : 'Continue',
            onTap: _nextPage,
          ),
        ),
      ),
    );
  }
}
