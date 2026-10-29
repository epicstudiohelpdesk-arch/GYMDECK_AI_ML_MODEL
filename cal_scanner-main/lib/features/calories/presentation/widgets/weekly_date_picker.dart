import 'package:cal_scanner/core/extensions/widget_extension.dart';
import 'package:cal_scanner/features/calories/presentation/cubit/weeklydatepicker_cubit.dart';
import 'package:cal_scanner/theme/app_colors.dart';
import 'package:cal_scanner/theme/app_typography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

class WeekDatePicker extends StatefulWidget {
  final DateTime selectedDate;
  final ValueChanged<DateTime> onDateSelected;

  const WeekDatePicker({
    super.key,
    required this.selectedDate,
    required this.onDateSelected,
  });

  @override
  State<WeekDatePicker> createState() => _WeekDatePickerState();
}

class _WeekDatePickerState extends State<WeekDatePicker> {
  late final ScrollController _scrollController;
  late final WeekDatePickerCubit _cubit;

  static const double _itemWidth = 60.0;

  @override
  void initState() {
    super.initState();
    _cubit = WeekDatePickerCubit(initialSelectedDate: widget.selectedDate);

    final today = DateTime.now();
    final startDate = DateTime(today.year, 1, 1);
    final todayIndex = today.difference(startDate).inDays;

    final initialOffset = (todayIndex * _itemWidth) - 160;
    _scrollController = ScrollController(
      initialScrollOffset: initialOffset < 0 ? 0 : initialOffset,
    );

    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    final offset = _scrollController.offset;
    final dates = _cubit.state.dates;
    final centerIndex = ((offset + 160) / _itemWidth).floor().clamp(
      0,
      dates.length - 1,
    );
    _cubit.updateVisibleMonth(dates[centerIndex]);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _cubit.close();
    super.dispose();
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  bool _isToday(DateTime date) => _isSameDay(date, DateTime.now());

  String _dayLabel(DateTime date) {
    const labels = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
    return labels[date.weekday - 1];
  }

  String _monthYearLabel(DateTime date) {
    const months = [
      'JANUARY',
      'FEBRUARY',
      'MARCH',
      'APRIL',
      'MAY',
      'JUNE',
      'JULY',
      'AUGUST',
      'SEPTEMBER',
      'OCTOBER',
      'NOVEMBER',
      'DECEMBER',
    ];
    return '${months[date.month - 1]} ${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    final dateColor = AppColors.kOrange;
    final today = DateTime.now();

    return BlocBuilder<WeekDatePickerCubit, WeekDatePickerState>(
      bloc: _cubit,
      builder: (context, state) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _monthYearLabel(state.visibleMonthDate),
              style: AppTypography.headlineSmall.copyWith(color: dateColor),
            ).paddingOnly(left: 20),

            SizedBox(
              height: 60.h,
              child: ListView.builder(
                padding: pagePadding,
                controller: _scrollController,
                scrollDirection: Axis.horizontal,
                itemCount: state.dates.length,
                itemExtent: _itemWidth,
                itemBuilder: (context, index) {
                  final date = state.dates[index];
                  final isSelected = _isSameDay(date, state.selectedDate);
                  final isToday = _isToday(date);
                  final isFuture = date.isAfter(today);

                  return GestureDetector(
                    onTap: isFuture
                        ? null
                        : () {
                            _cubit.selectDate(date);
                            widget.onDateSelected(date);
                          },
                    child: Container(
                      margin: EdgeInsets.symmetric(horizontal: 2),
                      decoration: BoxDecoration(
                        color: isSelected ? dateColor : Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            _dayLabel(date),
                            style: TextStyle(
                              fontSize: 11.sp,
                              fontWeight: FontWeight.w600,
                              color: isSelected
                                  ? AppColors.kWhite
                                  : isFuture
                                  ? AppColors.kgrey
                                  : Theme.of(context).colorScheme.onSurface
                                        .withValues(alpha: 0.5),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${date.day}',
                            style: AppTypography.bodyLarge.copyWith(
                              fontWeight: isSelected || isToday
                                  ? FontWeight.w800
                                  : FontWeight.w500,
                              color: isSelected
                                  ? AppColors.kWhite
                                  : isFuture
                                  ? AppColors.kgrey
                                  : AppColors.kBlack,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
