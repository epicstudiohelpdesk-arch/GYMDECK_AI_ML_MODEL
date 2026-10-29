import 'package:flutter_bloc/flutter_bloc.dart';

class WeekDatePickerState {
  final DateTime selectedDate;
  final DateTime visibleMonthDate;
  final List<DateTime> dates;

  const WeekDatePickerState({
    required this.selectedDate,
    required this.visibleMonthDate,
    required this.dates,
  });

  WeekDatePickerState copyWith({
    DateTime? selectedDate,
    DateTime? visibleMonthDate,
    List<DateTime>? dates,
  }) {
    return WeekDatePickerState(
      selectedDate: selectedDate ?? this.selectedDate,
      visibleMonthDate: visibleMonthDate ?? this.visibleMonthDate,
      dates: dates ?? this.dates,
    );
  }
}

class WeekDatePickerCubit extends Cubit<WeekDatePickerState> {
  WeekDatePickerCubit({required DateTime initialSelectedDate})
    : super(_buildInitialState(initialSelectedDate));

  static WeekDatePickerState _buildInitialState(DateTime selectedDate) {
    final today = DateTime.now();
    final startDate = DateTime(today.year, 1, 1);
    final dayCount = today.difference(startDate).inDays + 1;
    final dates = List.generate(
      dayCount,
      (i) => startDate.add(Duration(days: i)),
    );

    return WeekDatePickerState(
      selectedDate: selectedDate,
      visibleMonthDate: today,
      dates: dates,
    );
  }

  void selectDate(DateTime date) {
    final today = DateTime.now();
    if (date.isAfter(today)) return;
    emit(state.copyWith(selectedDate: date));
  }

  void updateVisibleMonth(DateTime date) {
    if (date.month != state.visibleMonthDate.month ||
        date.year != state.visibleMonthDate.year) {
      emit(state.copyWith(visibleMonthDate: date));
    }
  }
}
