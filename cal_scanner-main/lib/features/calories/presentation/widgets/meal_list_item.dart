import 'package:cal_scanner/core/extensions/capital_first_extension.dart';
import 'package:cal_scanner/core/extensions/context_extension.dart';
import 'package:cal_scanner/core/extensions/num_extension.dart';
import 'package:cal_scanner/theme/app_typography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../../domain/entities/food.dart';

class MealListItem extends StatelessWidget {
  final Food meal;
  final String timeAgo;

  const MealListItem({super.key, required this.meal, required this.timeAgo});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8.h),
      decoration: BoxDecoration(
        color: context.colors.surface,
        border: Border.all(color: context.colors.outlineVariant),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Text section
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  meal.name.capitalizeFirst(),
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.displaySmall.copyWith(fontSize: 16.sp),
                ),

                10.kH,
                Text('${meal.calories.toStringAsFixed(0)} kcal'),
              ],
            ),
          ),

          // Trailing icon
          Text(timeAgo, style: AppTypography.bodySmall),
        ],
      ),
    );
  }
}
