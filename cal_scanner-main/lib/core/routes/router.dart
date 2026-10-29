import 'package:cal_scanner/features/calories/presentation/screens/home_screen.dart';
import 'package:cal_scanner/features/onboarding/presentation/screens/onboarding_screen.dart';
import 'package:cal_scanner/features/onboarding/presentation/screens/splash.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_routes.dart';

class AppRouter {
  final bool showOnboarding;
  final SharedPreferences prefs;

  AppRouter({required this.showOnboarding, required this.prefs});

  late final GoRouter router = GoRouter(
    initialLocation: AppRoutes.splash,
    routes: [
      GoRoute(
        path: AppRoutes.splash,
        name: AppRoutes.splash,
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: AppRoutes.onboarding,
        name: AppRoutes.onboarding,
        builder: (context, state) => const OnboardingScreen(),
      ),
      GoRoute(
        path: AppRoutes.main,
        name: AppRoutes.main,
        builder: (context, state) => const HomeScreen(), // ← no child needed
      ),
    ],
    redirect: (context, state) {
      final onboardingDone = prefs.getBool('onboarding_complete') ?? false;
      final location = state.matchedLocation;
      final isSplash = location == AppRoutes.splash;
      if (isSplash) return null;
      if (!onboardingDone) return AppRoutes.onboarding;
      return null;
    },
  );
}
