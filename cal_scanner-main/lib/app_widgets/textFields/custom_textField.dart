import 'package:cal_scanner/theme/app_colors.dart';
import 'package:cal_scanner/theme/app_typography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

class CustomTextField extends StatefulWidget {
  final TextEditingController controller;
  final String hintText;
  final int maxLines;
  final TextStyle? textStyle;
  final TextStyle? hintStyle;
  final EdgeInsetsGeometry? contentPadding;
  final Color? fillColor;
  final Color? borderColor;
  final Color? focusedBorderColor;
  final double borderRadius;
  final Color? cursorColor;
  final bool? autofocus;
  final FocusNode? focusNode;
  final String? validatorTxt;
  Function(String)? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Widget? prefixIcon;
  TextInputType? keyboardType;

  /// NEW
  final bool isPassword;

  CustomTextField({
    super.key,
    required this.controller,
    required this.hintText,
    this.maxLines = 1,
    this.textStyle,
    this.hintStyle,
    this.contentPadding,
    this.fillColor,
    this.borderColor,
    this.focusedBorderColor,
    this.borderRadius = 24.0,
    this.cursorColor,
    this.autofocus,
    this.focusNode,
    this.validatorTxt,
    this.isPassword = false,
    this.onChanged,
    this.onSubmitted,
    this.prefixIcon,
    this.keyboardType,
  });

  @override
  State<CustomTextField> createState() => _CustomTextFieldState();
}

class _CustomTextFieldState extends State<CustomTextField> {
  bool _obscureText = true;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      keyboardType: widget.keyboardType ?? TextInputType.emailAddress,
      onChanged: widget.onChanged,
      onFieldSubmitted: widget.onSubmitted,
      controller: widget.controller,
      cursorColor: widget.cursorColor ?? AppColors.kBlack,
      maxLines: widget.isPassword ? 1 : widget.maxLines,
      autofocus: widget.autofocus ?? false,
      focusNode: widget.focusNode,
      obscureText: widget.isPassword ? _obscureText : false,
      validator: (value) {
        if (value == null || value.isEmpty) {
          return widget.validatorTxt;
        }
        return null;
      },
      style: widget.textStyle ?? AppTypography.bodyMedium,
      decoration: InputDecoration(
        hintText: widget.hintText,
        hintStyle:
            widget.hintStyle ??
            AppTypography.bodyMedium.copyWith(
              fontSize: 14.sp,
              color: AppColors.kBlack.withValues(alpha: .5),
            ),
        filled: true,
        fillColor: widget.fillColor ?? Colors.white,
        prefixIcon: widget.prefixIcon,

        /// 👁 Eye Icon
        suffixIcon: widget.isPassword
            ? IconButton(
                icon: Icon(
                  _obscureText ? Icons.visibility_off : Icons.visibility,
                  color: AppColors.kBlack.withValues(alpha: .6),
                ),
                onPressed: () {
                  setState(() {
                    _obscureText = !_obscureText;
                  });
                },
              )
            : null,

        border: _border(AppColors.kBlack.withValues(alpha: .2)),
        enabledBorder: _border(
          widget.borderColor ?? AppColors.kBlack.withValues(alpha: .2),
        ),
        focusedBorder: _border(
          widget.focusedBorderColor ?? AppColors.kBlack.withValues(alpha: .5),
        ),
        errorBorder: _border(Colors.red),
        focusedErrorBorder: _border(Colors.red),
        contentPadding:
            widget.contentPadding ??
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
    );
  }

  OutlineInputBorder _border(Color color) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      borderSide: BorderSide(color: color, width: 1),
    );
  }
}
