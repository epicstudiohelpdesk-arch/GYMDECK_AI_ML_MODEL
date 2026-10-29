import 'package:cal_scanner/core/extensions/widget_extension.dart';
import 'package:cal_scanner/features/onboarding/presentation/cubit/onboarding_cubit.dart';
import 'package:cal_scanner/theme/app_colors.dart';
import 'package:cal_scanner/theme/app_typography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

// ─── Main Widget ────────────────────────────────────────────────────────────
class HeightWeightWidget extends StatefulWidget {
  const HeightWeightWidget({super.key});

  @override
  State<HeightWeightWidget> createState() => _HeightWeightWidgetState();
}

class _HeightWeightWidgetState extends State<HeightWeightWidget> {
  // Default selections
  int _selectedFeet = 5;
  int _selectedInches = 7;
  int _selectedWeight = 70;

  static const int _minFeet = 3;
  static const int _maxFeet = 7;
  static const int _minInches = 0;
  static const int _maxInches = 11;
  static const int _minWeight = 40;
  static const int _maxWeight = 200;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final height = double.parse('$_selectedFeet.$_selectedInches');
      context.read<OnboardingCubit>().updateHeight(height);
      context.read<OnboardingCubit>().updateWeight(_selectedWeight.toDouble());
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Height & weight', style: AppTypography.headlineLarge),
        const SizedBox(height: 6),
        Text(
          "We'll use this for calorie calculations.",
          style: AppTypography.bodyMedium,
        ),
        const SizedBox(height: 60),

        Row(
          children: const [
            Expanded(child: _ColumnLabel('FEET')),
            Expanded(child: _ColumnLabel('INCHES')),
            Expanded(child: _ColumnLabel('WEIGHT')),
          ],
        ),
        const SizedBox(height: 8),

        // ── Picker ───────────────────────────────────────────────────────
        SizedBox(
          height: 200.h,
          child: Stack(
            children: [
              // Selection highlight band
              Positioned(
                top: 0,
                bottom: 0,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    height: 45.h,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.06),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // Pickers row
              Row(
                children: [
                  // Feet
                  Expanded(
                    child: _ScrollPicker(
                      items: List.generate(
                        _maxFeet - _minFeet + 1,
                        (i) => '${i + _minFeet}\'',
                      ),
                      initialIndex: _selectedFeet - _minFeet,
                      onChanged: (i) {
                        final newFeet = i + _minFeet;
                        setState(() => _selectedFeet = newFeet);
                        final height = double.parse(
                          '$newFeet.$_selectedInches',
                        );
                        context.read<OnboardingCubit>().updateHeight(height);
                      },
                    ),
                  ),
                  // Inches
                  Expanded(
                    child: _ScrollPicker(
                      items: List.generate(
                        _maxInches - _minInches + 1,
                        (i) => '${i + _minInches}"',
                      ),
                      initialIndex: _selectedInches - _minInches,
                      onChanged: (i) {
                        final newInches = i + _minInches;
                        setState(() => _selectedInches = newInches);
                        final height = double.parse(
                          '$_selectedFeet.$newInches',
                        );
                        context.read<OnboardingCubit>().updateHeight(height);
                      },
                    ),
                  ),
                  // Weight
                  Expanded(
                    child: _ScrollPicker(
                      items: List.generate(
                        _maxWeight - _minWeight + 1,
                        (i) => '${i + _minWeight} kg',
                      ),
                      initialIndex: _selectedWeight - _minWeight,
                      onChanged: (i) {
                        final newWeight = i + _minWeight;
                        setState(() => _selectedWeight = newWeight);
                        context.read<OnboardingCubit>().updateWeight(
                          newWeight.toDouble(),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ).paddingSymmetric(horizontal: 2.w),

        const SizedBox(height: 32),

        // ── Summary chip ─────────────────────────────────────────────────
        Center(
          child: Container(
            width: 150.w,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.kBlack,
              borderRadius: BorderRadius.circular(50),
            ),
            child: Center(
              child: Text(
                '$_selectedFeet . $_selectedInches  :  $_selectedWeight kg',
                style: AppTypography.bodyLarge.copyWith(color: Colors.white),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ColumnLabel extends StatelessWidget {
  final String label;
  const _ColumnLabel(this.label);

  @override
  Widget build(BuildContext context) =>
      Text(label, textAlign: TextAlign.center, style: AppTypography.bodyMedium);
}

// ─── Scroll Picker ────────────────────────────────────────────────────────────
class _ScrollPicker extends StatefulWidget {
  final List<String> items;
  final int initialIndex;
  final ValueChanged<int> onChanged;

  const _ScrollPicker({
    required this.items,
    required this.initialIndex,
    required this.onChanged,
  });

  @override
  State<_ScrollPicker> createState() => _ScrollPickerState();
}

class _ScrollPickerState extends State<_ScrollPicker> {
  late final FixedExtentScrollController _controller;
  late int _selectedIndex;

  static const double _itemExtent = 48.0;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialIndex;
    _controller = FixedExtentScrollController(initialItem: widget.initialIndex);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListWheelScrollView.useDelegate(
      controller: _controller,
      itemExtent: _itemExtent,
      perspective: 0.003,
      diameterRatio: 2.2,
      physics: const FixedExtentScrollPhysics(),
      onSelectedItemChanged: (index) {
        setState(() => _selectedIndex = index);
        widget.onChanged(index);
      },
      childDelegate: ListWheelChildBuilderDelegate(
        builder: (context, index) {
          if (index < 0 || index >= widget.items.length) return null;
          final isSelected = index == _selectedIndex;
          return Center(
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 150),
              style: TextStyle(
                fontSize: isSelected ? 18.h : 15.h,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                color: isSelected ? AppColors.kPureBlack : AppColors.kgrey,
                height: 1,
              ),
              child: Text(widget.items[index], textAlign: TextAlign.center),
            ),
          );
        },
        childCount: widget.items.length,
      ),
    );
  }
}
