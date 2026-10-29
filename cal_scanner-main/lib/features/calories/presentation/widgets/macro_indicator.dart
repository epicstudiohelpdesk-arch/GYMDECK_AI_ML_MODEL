import 'package:cal_scanner/theme/app_colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:percent_indicator/linear_percent_indicator.dart';

class MacroIndicator extends StatelessWidget {
  final String label;
  final double value;
  final double goal;
  final Color color;

  const MacroIndicator({
    super.key,
    required this.label,
    required this.value,
    required this.goal,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
        SizedBox(height: 4),
        LinearPercentIndicator(
          width: 80,
          lineHeight: 8,
          percent: (value / goal).clamp(0.0, 1.0),
          backgroundColor: AppColors.kPrimaryGrey,
          progressColor: color,
          padding: EdgeInsets.zero,
          barRadius: Radius.circular(4),
        ),
        SizedBox(height: 5.h),
        Text(
          '${value.toInt()}/${goal.toInt()}g',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}
