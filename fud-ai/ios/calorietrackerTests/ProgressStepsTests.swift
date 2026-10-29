import Foundation
import Testing
@testable import calorietracker

struct ProgressStepsTests {
    @Test func stepsMetricOnlyAppearsWithHealthEnabledAndComesLast() {
        #expect(
            ProgressMetric.available(bodyFatAvailable: true, workoutBurnAvailable: true, stepsAvailable: true)
                == [.weight, .bodyFat, .workouts, .steps]
        )
        #expect(
            ProgressMetric.available(bodyFatAvailable: false, workoutBurnAvailable: false, stepsAvailable: true)
                == [.weight, .steps]
        )
        #expect(
            ProgressMetric.available(bodyFatAvailable: true, workoutBurnAvailable: true)
                == [.weight, .bodyFat, .workouts]
        )
    }

    @Test func summaryAveragesOnlyDaysWithStepsAndPicksTheBestDay() throws {
        let calendar = utcCalendar
        let days = try [
            StepDay(date: date(2026, 10, 12, calendar: calendar), steps: 6_000),
            StepDay(date: date(2026, 10, 14, calendar: calendar), steps: 12_500),
            StepDay(date: date(2026, 10, 15, calendar: calendar), steps: 8_001),
        ]

        let summary = StepsAggregation.summary(days)

        #expect(summary.total == 26_501)
        #expect(summary.average == 8_834)
        #expect(summary.best == days[1])
    }

    @Test func emptySummaryIsZero() {
        let summary = StepsAggregation.summary([])
        #expect(summary.total == 0)
        #expect(summary.average == 0)
        #expect(summary.best == nil)
    }

    @Test func weeklyBarsAverageEachCalendarWeek() throws {
        var calendar = utcCalendar
        calendar.firstWeekday = 2 // Monday
        let days = try [
            // Week of Mon 5 Oct 2026.
            StepDay(date: date(2026, 10, 5, calendar: calendar), steps: 4_000),
            StepDay(date: date(2026, 10, 11, calendar: calendar), steps: 6_000),
            // Week of Mon 12 Oct 2026.
            StepDay(date: date(2026, 10, 13, calendar: calendar), steps: 9_000),
        ]

        let daily = StepsAggregation.chartBars(Array(days.reversed()), weekly: false, calendar: calendar)
        let weekly = StepsAggregation.chartBars(days, weekly: true, calendar: calendar)

        #expect(daily == days)
        let expectedWeekly = try [
            StepDay(date: date(2026, 10, 5, calendar: calendar), steps: 5_000),
            StepDay(date: date(2026, 10, 12, calendar: calendar), steps: 9_000),
        ]
        #expect(weekly == expectedWeekly)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: year, month: month, day: day)))
    }
}
