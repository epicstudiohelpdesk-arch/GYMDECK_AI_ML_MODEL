import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../network/api_service.dart';
import '../routes/router.dart';
import '../../features/calories/data/datasources/food_local_datasource.dart';
import '../../features/calories/data/datasources/food_remote_datasource.dart';
import '../../features/calories/data/repositories/food_repository_impl.dart';
import '../../features/calories/domain/repositories/food_repository.dart';
import '../../features/calories/domain/usecases/add_food.dart';
import '../../features/calories/domain/usecases/delete_food.dart';
import '../../features/calories/domain/usecases/detect_food_from_image.dart';
import '../../features/calories/domain/usecases/get_daily_food_log.dart';
import '../../features/calories/domain/usecases/get_weekly_calories.dart';
import '../../features/calories/domain/usecases/update_food.dart';
import '../../features/calories/presentation/cubit/food_log_cubit.dart';
import '../../features/onboarding/data/datasources/onboarding_local_datasource.dart';
import '../../features/onboarding/data/repositories/onboarding_repository_impl.dart';
import '../../features/onboarding/domain/repositories/onboarding_repository.dart';
import '../../features/onboarding/domain/usecases/calculate_goals.dart';
import '../../features/onboarding/domain/usecases/mark_onboarding_complete.dart';
import '../../features/onboarding/domain/usecases/save_user_data.dart';
import '../../features/onboarding/presentation/cubit/onboarding_cubit.dart';

final sl = GetIt.instance;

Future<void> configureDependencies({
  required SharedPreferences prefs,
  required bool showOnboarding,
}) async {
  // External
  sl.registerLazySingleton<SharedPreferences>(() => prefs);
  sl.registerLazySingleton<http.Client>(() => http.Client());

  // Core
  sl.registerLazySingleton<ApiService>(() => ApiService(sl()));
  sl.registerLazySingleton<AppRouter>(
    () => AppRouter(showOnboarding: showOnboarding, prefs: sl()),
  );
  sl.registerLazySingleton<GoRouter>(() => sl<AppRouter>().router);

  // Calories
  sl.registerLazySingleton<FoodLocalDataSource>(() => FoodLocalDataSource(sl()));
  sl.registerLazySingleton<FoodRemoteDataSource>(() => FoodRemoteDataSource(sl()));
  sl.registerLazySingleton<FoodRepository>(() => FoodRepositoryImpl(sl(), sl()));

  sl.registerLazySingleton<GetDailyFoodLog>(() => GetDailyFoodLog(sl()));
  sl.registerLazySingleton<GetWeeklyCalories>(() => GetWeeklyCalories(sl()));
  sl.registerLazySingleton<AddFood>(() => AddFood(sl()));
  sl.registerLazySingleton<DeleteFood>(() => DeleteFood(sl()));
  sl.registerLazySingleton<UpdateFood>(() => UpdateFood(sl()));
  sl.registerLazySingleton<DetectFoodFromImage>(() => DetectFoodFromImage(sl()));

  sl.registerFactory<FoodLogCubit>(
    () => FoodLogCubit(sl(), sl(), sl(), sl(), sl(), sl())..loadDailyLog(),
  );

  // Onboarding
  sl.registerLazySingleton<OnboardingLocalDataSource>(
    () => OnboardingLocalDataSource(sl()),
  );
  sl.registerLazySingleton<OnboardingRepository>(
    () => OnboardingRepositoryImpl(sl()),
  );
  sl.registerLazySingleton<CalculateGoals>(() => CalculateGoals());
  sl.registerLazySingleton<SaveUserData>(() => SaveUserData(sl()));
  sl.registerLazySingleton<MarkOnboardingComplete>(
    () => MarkOnboardingComplete(sl()),
  );

  sl.registerFactory<OnboardingCubit>(() => OnboardingCubit(sl(), sl(), sl()));
}
