import 'package:cal_scanner/theme/app_colors.dart';
import 'package:cal_scanner/theme/app_typography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../animation/bouncing_animation.dart';

class AppButton extends StatelessWidget {
  final Color? btnColor;
  final String text;
  final VoidCallback? onTap;
  final Widget? child;
  final double? height;
  final double? width;
  final Color? textColor;
  final Color? borderColor;
  final double? borderRadius;
  final double? fontSize;

  const AppButton({
    super.key,
    this.btnColor,
    required this.text,
    required this.onTap,
    this.child,
    this.height,
    this.width,
    this.textColor,
    this.borderColor,
    this.borderRadius,
    this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    return Bounce(
      onTap: onTap,
      child: Container(
        height: height ?? 50.h,
        width: width ?? MediaQuery.sizeOf(context).width,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.kBlack,
          borderRadius: BorderRadius.circular(borderRadius ?? 30.r),
          border: Border.all(color: borderColor ?? Colors.transparent),
        ),
        child:
            child ??
            Text(
              text,
              style: AppTypography.headlineMedium.copyWith(
                color: textColor ?? AppColors.kWhite,
                fontSize: fontSize ?? 16.sp,
              ),
            ),
      ),
    );
  }
}
