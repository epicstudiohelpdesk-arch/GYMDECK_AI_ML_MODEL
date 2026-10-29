import 'package:cal_scanner/core/extensions/num_extension.dart';
import 'package:cal_scanner/features/onboarding/presentation/cubit/onboarding_cubit.dart';
import 'package:cal_scanner/theme/app_colors.dart';
import 'package:cal_scanner/theme/app_typography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

class AgeWidget extends StatefulWidget {
  const AgeWidget({super.key});

  @override
  State<AgeWidget> createState() => _AgeWidgetState();
}

class _AgeWidgetState extends State<AgeWidget> {
  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  static const _startYear = 1924;
  static const _endYear = 2024;
  static const _itemExtent = 52.0;

  int _month = 0, _day = 0, _year = 76;

  late final _monthCtrl = FixedExtentScrollController(initialItem: _month);
  late final _dayCtrl = FixedExtentScrollController(initialItem: _day);
  late final _yearCtrl = FixedExtentScrollController(initialItem: _year);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notify(); // sends default age to cubit immediately
    });
  }

  @override
  void dispose() {
    _monthCtrl.dispose();
    _dayCtrl.dispose();
    _yearCtrl.dispose();
    super.dispose();
  }

  int get _daysInMonth =>
      DateUtils.getDaysInMonth(_startYear + _year, _month + 1);

  void _clampDay() {
    final max = _daysInMonth - 1;
    if (_day > max) {
      setState(() => _day = max);
      _dayCtrl.jumpToItem(max);
    }
  }

  void _onMonthChanged(int i) {
    setState(() => _month = i);
    _clampDay();
    _notify();
  }

  void _onDayChanged(int i) {
    setState(() => _day = i);
    _notify();
  }

  void _onYearChanged(int i) {
    setState(() => _year = i);
    _clampDay();
    _notify();
  }

  void _notify() {
    final dob = DateTime(_startYear + _year, _month + 1, _day + 1);
    final now = DateTime.now();
    final age =
        now.year -
        dob.year -
        (now.month < dob.month || (now.month == dob.month && now.day < dob.day)
            ? 1
            : 0);
    context.read<OnboardingCubit>().updateAge(age);
    debugPrint(age.toString());
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('When were you\nborn?', style: AppTypography.headlineLarge),
        10.kH,
        Text(
          'This will be used to calibrate your custom plan.',
          style: AppTypography.bodyMedium,
        ),
        32.kH,
        _buildPicker(context),
      ],
    );
  }

  Widget _buildPicker(BuildContext context) {
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final pickerHeight = _itemExtent * 5;

    return SizedBox(
      height: pickerHeight,
      child: Stack(
        children: [
          Align(
            alignment: Alignment.center,
            child: Container(
              height: 45.h,
              margin: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                color: AppColors.kWhite,
                borderRadius: BorderRadius.circular(14),

                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 12,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
            ),
          ),

          // Columns
          Row(
            children: [
              Expanded(
                flex: 5,
                child: _buildColumn(
                  ctrl: _monthCtrl,
                  count: 12,
                  label: (i) => _months[i],
                  onChanged: _onMonthChanged,
                  selected: _month,
                ),
              ),
              Expanded(
                flex: 3,
                child: _buildColumn(
                  ctrl: _dayCtrl,
                  count: _daysInMonth,
                  label: (i) => '${i + 1}',
                  onChanged: _onDayChanged,
                  selected: _day,
                ),
              ),
              Expanded(
                flex: 4,
                child: _buildColumn(
                  ctrl: _yearCtrl,
                  count: _endYear - _startYear + 1,
                  label: (i) => '${_startYear + i}',
                  onChanged: _onYearChanged,
                  selected: _year,
                ),
              ),
            ],
          ),

          // Fade gradients
          Positioned.fill(
            child: IgnorePointer(
              child: Column(
                children: [
                  Expanded(
                    child: _fade(
                      bg,
                      Alignment.topCenter,
                      Alignment.bottomCenter,
                    ),
                  ),
                  SizedBox(height: _itemExtent),
                  Expanded(
                    child: _fade(
                      bg,
                      Alignment.bottomCenter,
                      Alignment.topCenter,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fade(Color color, Alignment begin, Alignment end) => Container(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: begin,
        end: end,
        colors: [color, color.withValues(alpha: 0.1)],
      ),
    ),
  );

  Widget _buildColumn({
    required FixedExtentScrollController ctrl,
    required int count,
    required String Function(int) label,
    required ValueChanged<int> onChanged,
    required int selected,
  }) {
    return ListWheelScrollView.useDelegate(
      controller: ctrl,
      itemExtent: _itemExtent,
      diameterRatio: 8,
      physics: const FixedExtentScrollPhysics(),
      onSelectedItemChanged: onChanged,
      childDelegate: ListWheelChildBuilderDelegate(
        childCount: count,
        builder: (context, i) {
          if (i < 0 || i >= count) return null;
          final isSelected = i == selected;
          return Center(
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 180),
              style: TextStyle(
                fontSize: isSelected ? 17.h : 14,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                color: isSelected
                    ? Theme.of(context).colorScheme.onSurface
                    : Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.3),
                letterSpacing: isSelected ? 0.2 : 0,
              ),
              child: Text(label(i)),
            ),
          );
        },
      ),
    );
  }
}
