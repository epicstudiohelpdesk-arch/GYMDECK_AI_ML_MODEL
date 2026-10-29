import 'package:cal_scanner/core/extensions/num_extension.dart';
import 'package:cal_scanner/core/extensions/widget_extension.dart';
import 'package:cal_scanner/core/extensions/context_extension.dart';
import 'package:cal_scanner/features/calories/presentation/screens/meal_detail_screen.dart';
import 'package:cal_scanner/gen/assets.gen.dart';
import 'package:cal_scanner/theme/app_typography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../../domain/entities/food.dart';
import '../cubit/food_log_cubit.dart';
import 'meal_list_item.dart';
import 'package:timeago/timeago.dart' as timeago;

class MealList extends StatelessWidget {
  final List<Food> meals;

  const MealList({required this.meals, super.key});

  @override
  Widget build(BuildContext context) {
    final sortedMeals = List.of(meals)
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    return meals.isEmpty
        ? Padding(
            padding: EdgeInsetsGeometry.only(top: 20.h),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Image.asset(
                  Assets.images.tray.path,
                  height: 40.h,
                  color: context.colors.onSurfaceVariant,
                ),
                15.kH,
                Padding(
                  padding: pagePadding,
                  child: Text(
                    'Your plate is empty for now\nScan any meal to instantly track calories',
                    textAlign: TextAlign.center,
                    style: AppTypography.bodyMedium.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                ),
                Row(),
              ],
            ),
          )
        : ListView.separated(
            padding: pagePadding,
            shrinkWrap: true,
            physics: NeverScrollableScrollPhysics(),
            itemCount: sortedMeals.length,
            separatorBuilder: (context, index) => SizedBox(height: 12),
            itemBuilder: (context, index) {
              final meal = sortedMeals[index];
              return GestureDetector(
                onLongPress: () => _showDeleteDialog(context, meal),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => MealDetailScreen(meal: meal),
                    ),
                  );
                },
                child: MealListItem(
                  meal: meal,
                  timeAgo: timeago
                      .format(meal.timestamp)
                      .replaceAll(' minutes', ' min')
                      .replaceAll(' minute', ' min'),
                ),
              );
            },
          );
  }

  void _showDeleteDialog(BuildContext context, Food meal) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete Meal'),
        content: Text('Are you sure you want to delete this meal?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              context.read<FoodLogCubit>().deleteMeal(meal);
            },
            child: Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
