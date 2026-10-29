import Foundation
import Testing
@testable import calorietracker

@MainActor
struct WeeklyRecapTests {
    // MARK: - Week boundaries

    @Test func recapsTheLastCompletedWeekFromTheCalendarsFirstWeekday() throws {
        // Saturday, October 17, 2026.
        let saturday = try date(2026, 10, 17, hour: 15)
        let mondayBefore = try date(2026, 10, 5)
        let mondayTwoBefore = try date(2026, 9, 28)
        let sundayBefore = try date(2026, 10, 4)

        let monday = calendar(firstWeekday: 2)
        #expect(WeeklyRecap.weekStart(offset: 0, now: saturday, calendar: monday) == mondayBefore)
        #expect(WeeklyRecap.weekStart(offset: 1, now: saturday, calendar: monday) == mondayTwoBefore)

        let sunday = calendar(firstWeekday: 1)
        #expect(WeeklyRecap.weekStart(offset: 0, now: saturday, calendar: sunday) == sundayBefore)
    }

    @Test func weeksFollowTheWeekStartsOnSettingInsteadOfTheRegion() throws {
        let saturday = try date(2026, 10, 17, hour: 15)
        let mondayBefore = try date(2026, 10, 5)
        let sundayBefore = try date(2026, 10, 4)
        let saturdayBefore = try date(2026, 10, 10)

        // A US-style calendar starts weeks on Sunday; the default Monday setting wins.
        let usRegion = calendar(firstWeekday: 1)
        let mondayFirst = WeeklyRecap.calendar(weekStartsOnMonday: true, base: usRegion)
        #expect(mondayFirst.firstWeekday == 2)
        #expect(WeeklyRecap.weekStart(offset: 0, now: saturday, calendar: mondayFirst) == mondayBefore)

        // A Monday-first region with the setting on Sunday gets Sunday weeks.
        let germanRegion = calendar(firstWeekday: 2)
        let sundayFirst = WeeklyRecap.calendar(weekStartsOnMonday: false, base: germanRegion)
        #expect(sundayFirst.firstWeekday == 1)
        #expect(WeeklyRecap.weekStart(offset: 0, now: saturday, calendar: sundayFirst) == sundayBefore)
        // Only the first weekday changes; days still resolve in the base time zone.
        #expect(sundayFirst.timeZone == germanRegion.timeZone)

        let recap = WeeklyRecap.compute(
            now: saturday,
            calendar: sundayFirst,
            foods: [food(2_000, protein: 0, at: sundayBefore)],
            workouts: [],
            weights: [],
            calorieGoal: 2_000,
            proteinGoal: 0
        )
        #expect(recap.weekStart == sundayBefore)
        #expect(recap.weekEnd == saturdayBefore)
        #expect(recap.current.loggedDays == 1)
    }

    @Test func theCurrentWeekIsNeverRecappedBeforeItEnds() throws {
        let monday = calendar(firstWeekday: 2)
        let lastWeek = try date(2026, 10, 5)
        let finishedWeek = try date(2026, 10, 12)
        let lateSunday = try date(2026, 10, 18, hour: 23)
        let earlyMonday = try date(2026, 10, 19, hour: 0, minute: 30)
        // Late on the current week's final day the recap still shows the week before it.
        #expect(WeeklyRecap.weekStart(offset: 0, now: lateSunday, calendar: monday) == lastWeek)
        // Just after midnight the finished week becomes the recap.
        #expect(WeeklyRecap.weekStart(offset: 0, now: earlyMonday, calendar: monday) == finishedWeek)
    }

    // MARK: - Week stats

    @Test func countsLoggedTargetAndProteinDaysInsideTheWeek() throws {
        let foods = try [
            food(2_000, protein: 150, at: date(2026, 10, 5, hour: 12)),
            // 2,150 is within 10% of 2,000; 149.6 g shows as 150 g.
            food(2_150, protein: 149.6, at: date(2026, 10, 6, hour: 12)),
            food(2_300, protein: 100, at: date(2026, 10, 7, hour: 12)),
            // Two meals that together miss the range but reach protein.
            food(900, protein: 80, at: date(2026, 10, 9, hour: 9)),
            food(800, protein: 80, at: date(2026, 10, 9, hour: 19)),
            // Exactly 10% under still counts.
            food(1_800, protein: 50, at: date(2026, 10, 10, hour: 12)),
            food(500, protein: 20, at: date(2026, 10, 11, hour: 23, minute: 59)),
            // Outside the week on either side.
            food(2_000, protein: 150, at: date(2026, 10, 4, hour: 23, minute: 59)),
            food(2_000, protein: 150, at: date(2026, 10, 12, hour: 0)),
        ]

        let stats = WeeklyRecap.stats(
            weekStart: try date(2026, 10, 5),
            calendar: calendar(firstWeekday: 2),
            foods: foods,
            workouts: [],
            weights: [],
            calorieGoal: 2_000,
            proteinGoal: 150
        )

        #expect(stats.loggedDays == 6)
        #expect(stats.calorieTargetDays == 3)
        #expect(stats.proteinGoalDays == 3)
        #expect(stats.averageCalories == 1_742) // 10,450 / 6 days
        #expect(stats.longestLoggingStreak == 3)
        #expect(stats.hasActivity)
    }

    @Test func anEmptyWeekHasNoAverageOrActivity() throws {
        let stats = WeeklyRecap.stats(
            weekStart: try date(2026, 10, 5),
            calendar: calendar(firstWeekday: 2),
            foods: [],
            workouts: [],
            weights: [],
            calorieGoal: 2_000,
            proteinGoal: 150
        )
        #expect(stats == WeeklyRecapWeekStats())
        #expect(stats.averageCalories == nil)
        #expect(!stats.hasActivity)
    }

    @Test func countsOneWorkoutPerDayWithItsBurn() throws {
        let workouts = try [
            WeeklyRecapWorkoutDay(date: date(2026, 10, 6), calories: nil),
            WeeklyRecapWorkoutDay(date: date(2026, 10, 6), calories: 300),
            WeeklyRecapWorkoutDay(date: date(2026, 10, 8), calories: 250),
            WeeklyRecapWorkoutDay(date: date(2026, 10, 12), calories: 900),
        ]

        let stats = WeeklyRecap.stats(
            weekStart: try date(2026, 10, 5),
            calendar: calendar(firstWeekday: 2),
            foods: [],
            workouts: workouts,
            weights: [],
            calorieGoal: 2_000,
            proteinGoal: 150
        )

        #expect(stats.workouts == 2)
        #expect(stats.activeBurnCalories == 550)
        #expect(stats.hasActivity)
    }

    @Test func weightChangeIsLastMinusFirstReadingOfTheWeek() throws {
        let weights = try [
            WeightEntry(date: date(2026, 10, 11, hour: 20), weightKg: 79.4),
            WeightEntry(date: date(2026, 10, 5, hour: 8), weightKg: 80.0),
            WeightEntry(date: date(2026, 10, 8, hour: 8), weightKg: 79.9),
            WeightEntry(date: date(2026, 10, 12, hour: 8), weightKg: 70.0),
        ]

        let stats = WeeklyRecap.stats(
            weekStart: try date(2026, 10, 5),
            calendar: calendar(firstWeekday: 2),
            foods: [],
            workouts: [],
            weights: weights,
            calorieGoal: 2_000,
            proteinGoal: 150
        )
        #expect(stats.weighIns == 3)
        #expect(abs((stats.weightChangeKg ?? 0) - -0.6) < 0.000_1)

        let single = WeeklyRecap.stats(
            weekStart: try date(2026, 10, 5),
            calendar: calendar(firstWeekday: 2),
            foods: [],
            workouts: [],
            weights: [weights[2]],
            calorieGoal: 2_000,
            proteinGoal: 150
        )
        #expect(single.weighIns == 1)
        #expect(single.weightChangeKg == nil)
    }

    @Test func comparesTheRecappedWeekWithTheOneBefore() throws {
        let foods = try [
            food(2_000, protein: 150, at: date(2026, 9, 29, hour: 12)),
            food(2_000, protein: 150, at: date(2026, 9, 22, hour: 12)),
            food(2_000, protein: 150, at: date(2026, 9, 23, hour: 12)),
        ]

        let now = try date(2026, 10, 17, hour: 15)
        let expectedStart = try date(2026, 9, 28)
        let expectedEnd = try date(2026, 10, 4)

        let recap = WeeklyRecap.compute(
            offset: 1,
            now: now,
            calendar: calendar(firstWeekday: 2),
            foods: foods,
            workouts: [],
            weights: [],
            calorieGoal: 2_000,
            proteinGoal: 150
        )

        #expect(recap.weekStart == expectedStart)
        #expect(recap.weekEnd == expectedEnd)
        #expect(recap.current.loggedDays == 1)
        #expect(recap.previous.loggedDays == 2)
        // A quieter week is never called out.
        #expect(recap.highlights.isEmpty)
    }

    // MARK: - Highlights

    @Test func highlightsOnlyImprovementsInPriorityOrder() {
        var current = WeeklyRecapWeekStats()
        current.loggedDays = 7
        current.longestLoggingStreak = 7
        current.workouts = 3
        current.calorieTargetDays = 5
        current.proteinGoalDays = 4
        current.averageCalories = 2_050
        var previous = WeeklyRecapWeekStats()
        previous.loggedDays = 5
        previous.workouts = 1
        previous.calorieTargetDays = 2
        previous.proteinGoalDays = 4

        #expect(
            WeeklyRecap.highlights(current: current, previous: previous, calorieGoal: 2_000)
                == [.loggedEveryDay, .moreWorkouts(2), .moreCalorieTargetDays(3)]
        )
    }

    @Test func aStreakAndMoreLoggedDaysAreCalledOutWithoutAFullWeek() {
        var current = WeeklyRecapWeekStats()
        current.loggedDays = 5
        current.longestLoggingStreak = 4
        current.averageCalories = 2_190
        var previous = WeeklyRecapWeekStats()
        previous.loggedDays = 3

        #expect(
            WeeklyRecap.highlights(current: current, previous: previous, calorieGoal: 2_000)
                == [.loggingStreak(days: 4), .averageCaloriesOnTarget, .moreLoggedDays(2)]
        )

        // Short streaks, a missed average and fewer days stay quiet.
        current.longestLoggingStreak = 2
        current.averageCalories = 2_300
        current.loggedDays = 2
        #expect(WeeklyRecap.highlights(current: current, previous: previous, calorieGoal: 2_000).isEmpty)
    }

    @Test func averageCaloriesNeedEnoughLoggedDays() {
        var current = WeeklyRecapWeekStats()
        current.loggedDays = 2
        current.longestLoggingStreak = 2
        current.averageCalories = 2_000
        #expect(WeeklyRecap.highlights(current: current, previous: current, calorieGoal: 2_000).isEmpty)
        #expect(!WeeklyRecap.isOnCalorieTarget(2_000, goal: 0))
    }

    // MARK: - Workout diary days

    @Test func workoutDaysComeFromPerformedPlansAndCalculatedBurns() throws {
        let calendar = Calendar.current
        let start = try localDate(2026, 10, 5)
        let end = try localDate(2026, 10, 11)

        var strength = StrengthPlannedExercise(item: ExerciseLibraryItem(id: "bench", name: "Bench Press", category: "strength"))
        strength.sets = [StrengthPlannedSet(reps: "8")]
        let plannedOnly = StrengthPlannedExercise(item: ExerciseLibraryItem(id: "squat", name: "Squat", category: "strength"))
        var cardio = StrengthPlannedExercise(item: ExerciseLibraryItem(id: "run", name: "Running", category: "cardio"))
        cardio.timer = StrengthExerciseTimer(accumulatedSeconds: 1_200, savedDurationSeconds: 1_200)

        let plans = [
            "2026-10-05": StrengthWorkoutDayPlan(dateKey: "2026-10-05", exercises: [strength]),
            // Added but not done yet.
            "2026-10-06": StrengthWorkoutDayPlan(dateKey: "2026-10-06", exercises: [plannedOnly]),
            "2026-10-07": StrengthWorkoutDayPlan(dateKey: "2026-10-07", exercises: [cardio]),
            // Outside the range.
            "2026-10-12": StrengthWorkoutDayPlan(dateKey: "2026-10-12", exercises: [strength]),
        ]
        let burnDay = try localDate(2026, 10, 7)
        let burn = StrengthWorkoutSession(
            diaryDate: burnDay,
            diaryDateKey: "2026-10-07",
            startedAt: burnDay,
            completedAt: burnDay,
            durationSeconds: 0,
            exercises: [],
            caloriesBurned: 320
        )
        // A burn whose diary plan was cleared afterwards still counts.
        let orphanDay = try localDate(2026, 10, 9)
        let orphanBurn = StrengthWorkoutSession(
            diaryDate: orphanDay,
            diaryDateKey: "2026-10-09",
            startedAt: orphanDay,
            completedAt: orphanDay,
            durationSeconds: 0,
            exercises: [],
            caloriesBurned: 180
        )

        let days = WeeklyRecap.workoutDays(
            in: start...end,
            dayPlans: plans,
            sessions: [burn, orphanBurn],
            calendar: calendar
        )

        let expected = try [
            WeeklyRecapWorkoutDay(date: localDate(2026, 10, 5), calories: nil),
            WeeklyRecapWorkoutDay(date: localDate(2026, 10, 7), calories: 320),
            WeeklyRecapWorkoutDay(date: localDate(2026, 10, 9), calories: 180),
        ]
        #expect(days == expected)
    }

    // MARK: - Formatting

    @Test func changesShowTheirSign() {
        let locale = Locale(identifier: "en_US")
        #expect(WeeklyRecap.signedChange(2, locale: locale) == "+2")
        #expect(WeeklyRecap.signedChange(-1, locale: locale) == "\u{2212}1")
        #expect(WeeklyRecap.signedChange(0, locale: locale) == "0")
        #expect(WeeklyRecap.signedChange(1_234, locale: locale) == "+1,234")
    }

    @Test func energyFiguresInKilocaloriesAreUnchanged() {
        let english = Locale(identifier: "en_US")
        let current = WeeklyRecapWeekStats(loggedDays: 3, averageCalories: 1_850, activeBurnCalories: 350)
        let previous = WeeklyRecapWeekStats(loggedDays: 2, averageCalories: 2_400, activeBurnCalories: 300)

        let figures = WeeklyRecap.energyFigures(
            current: current, previous: previous, calorieGoal: 2_000, unit: .kcal, locale: english
        )
        #expect(figures == WeeklyRecapEnergyFigures(
            averageCalories: "1,850", calorieGoal: "2,000", activeBurn: "350 kcal", activeBurnChange: 50
        ))
    }

    @Test func energyFiguresConvertToKilojoules() {
        let english = Locale(identifier: "en_US")
        let current = WeeklyRecapWeekStats(loggedDays: 3, averageCalories: 1_850, activeBurnCalories: 350)
        var previous = WeeklyRecapWeekStats(activeBurnCalories: 300)

        // 1,850 kcal = 7,740 kJ, 2,000 = 8,368, 350 = 1,464 and 300 = 1,255.
        let figures = WeeklyRecap.energyFigures(
            current: current, previous: previous, calorieGoal: 2_000, unit: .kj, locale: english
        )
        #expect(figures == WeeklyRecapEnergyFigures(
            averageCalories: "7,740", calorieGoal: "8,368", activeBurn: "1,464 kJ", activeBurnChange: 209
        ))

        // The change is between the shown values (1,464 − 1,674), not −50 kcal converted (−209).
        previous.activeBurnCalories = 400
        let lower = WeeklyRecap.energyFigures(
            current: current, previous: previous, calorieGoal: 2_000, unit: .kj, locale: english
        )
        #expect(lower.activeBurnChange == -210)

        // Locale grouping still applies, and an empty week has no average.
        let german = WeeklyRecap.energyFigures(
            current: WeeklyRecapWeekStats(), previous: WeeklyRecapWeekStats(),
            calorieGoal: 2_000, unit: .kj, locale: Locale(identifier: "de_DE")
        )
        #expect(german.averageCalories == nil)
        #expect(german.calorieGoal == "8.368")
        #expect(german.activeBurnChange == 0)
    }

    // MARK: - Helpers

    private func calendar(firstWeekday: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) throws -> Date {
        try #require(calendar(firstWeekday: 2).date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)))
    }

    /// Workout diary days resolve through the device calendar.
    private func localDate(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        try #require(Calendar.current.date(from: DateComponents(year: year, month: month, day: day)))
    }

    private func food(_ calories: Int, protein: Double, at timestamp: Date) -> FoodEntry {
        FoodEntry(
            name: "Meal",
            calories: calories,
            protein: protein,
            carbs: 0,
            fat: 0,
            timestamp: timestamp,
            source: .manual
        )
    }
}
