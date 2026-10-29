import 'package:cal_scanner/app_widgets/buttons/back_button.dart';
import 'package:cal_scanner/core/extensions/capital_first_extension.dart';
import 'package:cal_scanner/core/extensions/context_extension.dart';
import 'package:cal_scanner/core/extensions/widget_extension.dart';
import 'package:cal_scanner/features/calories/presentation/cubit/food_log_cubit.dart';
import 'package:cal_scanner/features/calories/presentation/widgets/macros_card.dart';
import 'package:cal_scanner/theme/app_typography.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' hide VerticalDivider;
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../domain/entities/food.dart';
import 'package:timeago/timeago.dart' as timeago;

class MealDetailScreen extends StatelessWidget {
  final Food meal;

  const MealDetailScreen({super.key, required this.meal});

  void _deleteMeal(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete Meal'),
        content: Text('Are you sure you want to delete this meal?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: TextStyle(color: Colors.black)),
          ),
          TextButton(
            onPressed: () {
              context.read<FoodLogCubit>().deleteMeal(meal);
              Navigator.pop(context); // Close the dialog
              Navigator.pop(context);
            },
            child: Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.surface,
      appBar: AppBar(
        centerTitle: true,
        backgroundColor: context.colors.surface,
        iconTheme: IconThemeData(color: context.colors.onSurface),
        leading: AppBackButton(),
        actions: [
          IconButton(
            icon: Icon(CupertinoIcons.delete, color: Colors.red),
            onPressed: () => _deleteMeal(context),
          ).paddingOnly(right: 10),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (meal.imageUrl != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(12.0),
                child: Image.network(
                  meal.imageUrl!,
                  height: 180,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
            if (meal.imageUrl != null) SizedBox(height: 24),

            // Large calorie display
            Text(
              meal.name.capitalizeFirst(),
              style: AppTypography.headlineMedium,
            ),
            SizedBox(height: 30),

            Text(
              meal.calories.toStringAsFixed(0),
              style: TextStyle(
                fontSize: 80,
                fontWeight: FontWeight.bold,
                color: Colors.orange,
                height: 1.0,
              ),
            ),
            SizedBox(height: 4),
            Text(
              'calories',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey[500],
                fontWeight: FontWeight.w400,
              ),
            ),

            SizedBox(height: 32),

            // Macros card
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 12,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  MacroItem(
                    value: '${meal.protein.toStringAsFixed(0)}g',
                    label: 'Protein',
                    color: Colors.blue,
                  ),
                  VerticalDivider(),

                  MacroItem(
                    value: '${meal.carbs.toStringAsFixed(0)}g',
                    label: 'Carbs',
                    color: Colors.orange,
                  ),
                  VerticalDivider(),
                  MacroItem(
                    value: '${meal.fat.toStringAsFixed(0)}g',
                    label: 'Fat',
                    color: Colors.redAccent,
                  ),
                ],
              ),
            ),

            SizedBox(height: 32),

            // Additional details
            _DetailRow(
              icon: Icons.access_time,
              label: 'Logged',
              value: timeago.format(meal.timestamp),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10.0),
      child: Row(
        children: [
          Icon(icon, size: 22, color: context.colors.primary),
          SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: context.colors.onSurface,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w400,
              color: context.colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
