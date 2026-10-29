import Foundation

/// A workout diary day for the weekly recap. `calories` is that day's
/// calculated burn, when the user calculated one.
struct WeeklyRecapWorkoutDay: Equatable {
    let date: Date
    let calories: Int?
}

/// Totals for one recap week (seven local days).
struct WeeklyRecapWeekStats: Equatable {
    var loggedDays = 0
    /// Logged days within ±10% of the calorie target.
    var calorieTargetDays = 0
    /// Logged days that reached the protein target.
    var proteinGoalDays = 0
    /// Mean over the days with food logged; nil when nothing was logged.
    var averageCalories: Int?
    /// Days with a logged workout.
    var workouts = 0
    var activeBurnCalories = 0
    var weighIns = 0
    /// Last minus first weigh-in of the week; nil with fewer than two.
    var weightChangeKg: Double?
    /// Longest run of consecutive days with food logged.
    var longestLoggingStreak = 0

    var hasActivity: Bool { loggedDays > 0 || workouts > 0 || weighIns > 0 }
}

/// Encouraging, deterministic call-outs. Only good news is highlighted, so a
/// quieter week never reads as a scolding.
enum WeeklyRecapHighlight: Hashable {
    case loggedEveryDay
    case loggingStreak(days: Int)
    case moreWorkouts(Int)
    case moreCalorieTargetDays(Int)
    case moreProteinGoalDays(Int)
    case averageCaloriesOnTarget
    case moreLoggedDays(Int)
}

/// The recap's energy figures as shown, in the user's unit (#520). Totals, the
/// ±10% target window and the comparisons all stay kcal; only these convert.
struct WeeklyRecapEnergyFigures: Equatable {
    /// Unitless average, e.g. "1,850" or "7,740"; nil when nothing was logged.
    let averageCalories: String?
    /// Unitless calorie target for the average's caption.
    let calorieGoal: String
    /// Active burn with its unit, e.g. "350 kcal" or "1,464 kJ".
    let activeBurn: String
    /// Change between the two weeks' shown burns in display units. Converting
    /// keeps the order, so its sign always matches the kcal comparison.
    let activeBurnChange: Int
}

/// The Progress tab's recap of one completed week, compared with the week
/// before it (#431). Pure, so it can be computed for any week in the past.
struct WeeklyRecap: Equatable {
    /// First local day (start of day) of the recapped week.
    let weekStart: Date
    /// Last local day (start of day) of the recapped week.
    let weekEnd: Date
    let current: WeeklyRecapWeekStats
    /// The week just before, for the comparisons.
    let previous: WeeklyRecapWeekStats
    let highlights: [WeeklyRecapHighlight]

    static let calorieTolerance = 0.10
    static let minimumHighlightStreak = 3
    /// An average over fewer days says little about the week.
    static let minimumDaysForAverageHighlight = 3
    static let maximumHighlights = 3

    var days: ClosedRange<Date> { weekStart...weekEnd }

    /// `base` with weeks starting on the app's "Week Starts On" setting
    /// (Monday by default) instead of the region's first weekday.
    static func calendar(weekStartsOnMonday: Bool, base: Calendar = .current) -> Calendar {
        var calendar = base
        calendar.firstWeekday = weekStartsOnMonday ? 2 : 1 // 2 = Monday, 1 = Sunday
        return calendar
    }

    /// Start of the recapped week. Offset 0 is the most recent completed week
    /// (the one before the week containing `now`), 1 the week before that.
    /// Weeks begin on the calendar's first weekday; the card passes one built by
    /// `calendar(weekStartsOnMonday:)`.
    static func weekStart(offset: Int, now: Date = .now, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        return day(-7 * (max(offset, 0) + 1), from: thisWeek, calendar: calendar)
    }

    static func compute(
        offset: Int = 0,
        now: Date = .now,
        calendar: Calendar = .current,
        foods: [FoodEntry],
        workouts: [WeeklyRecapWorkoutDay],
        weights: [WeightEntry],
        calorieGoal: Int,
        proteinGoal: Int
    ) -> WeeklyRecap {
        let start = weekStart(offset: offset, now: now, calendar: calendar)
        func weekStats(from weekStart: Date) -> WeeklyRecapWeekStats {
            stats(
                weekStart: weekStart,
                calendar: calendar,
                foods: foods,
                workouts: workouts,
                weights: weights,
                calorieGoal: calorieGoal,
                proteinGoal: proteinGoal
            )
        }
        let current = weekStats(from: start)
        let previous = weekStats(from: day(-7, from: start, calendar: calendar))
        return WeeklyRecap(
            weekStart: start,
            weekEnd: day(6, from: start, calendar: calendar),
            current: current,
            previous: previous,
            highlights: highlights(current: current, previous: previous, calorieGoal: calorieGoal)
        )
    }

    static func stats(
        weekStart: Date,
        calendar: Calendar = .current,
        foods: [FoodEntry],
        workouts: [WeeklyRecapWorkoutDay],
        weights: [WeightEntry],
        calorieGoal: Int,
        proteinGoal: Int
    ) -> WeeklyRecapWeekStats {
        let first = calendar.startOfDay(for: weekStart)
        let nextWeek = day(7, from: first, calendar: calendar)
        var indexByDay: [Date: Int] = [:]
        for offset in 0..<7 {
            indexByDay[day(offset, from: first, calendar: calendar)] = offset
        }
        // The cheap bounds check skips the day lookup for everything outside the week.
        func dayIndex(_ date: Date) -> Int? {
            guard date >= first, date < nextWeek else { return nil }
            return indexByDay[calendar.startOfDay(for: date)]
        }

        var logged = Array(repeating: false, count: 7)
        var calories = Array(repeating: 0, count: 7)
        var protein = Array(repeating: 0.0, count: 7)
        for entry in foods {
            guard let index = dayIndex(entry.timestamp) else { continue }
            logged[index] = true
            calories[index] += entry.calories
            protein[index] += entry.protein
        }

        var stats = WeeklyRecapWeekStats()
        var streak = 0
        var totalCalories = 0
        for index in 0..<7 {
            guard logged[index] else {
                streak = 0
                continue
            }
            stats.loggedDays += 1
            totalCalories += calories[index]
            streak += 1
            stats.longestLoggingStreak = max(stats.longestLoggingStreak, streak)
            if isOnCalorieTarget(calories[index], goal: calorieGoal) {
                stats.calorieTargetDays += 1
            }
            // Rounded like the protein totals on screen, so "150 / 150 g" counts.
            if proteinGoal > 0, protein[index].rounded() >= Double(proteinGoal) {
                stats.proteinGoalDays += 1
            }
        }
        if stats.loggedDays > 0 {
            stats.averageCalories = Int((Double(totalCalories) / Double(stats.loggedDays)).rounded())
        }

        // One workout per diary day; the burn is that day's calculated estimate.
        var burnByDay: [Int: Int] = [:]
        var workoutDays = Set<Int>()
        for workout in workouts {
            guard let index = dayIndex(workout.date) else { continue }
            workoutDays.insert(index)
            if let burn = workout.calories, burn > 0 {
                burnByDay[index] = max(burnByDay[index] ?? 0, burn)
            }
        }
        stats.workouts = workoutDays.count
        stats.activeBurnCalories = burnByDay.values.reduce(0, +)

        let readings = weights
            .filter { dayIndex($0.date) != nil }
            .sorted { $0.date < $1.date }
        stats.weighIns = readings.count
        if readings.count >= 2, let firstReading = readings.first, let lastReading = readings.last {
            stats.weightChangeKg = lastReading.weightKg - firstReading.weightKg
        }
        return stats
    }

    static func highlights(
        current: WeeklyRecapWeekStats,
        previous: WeeklyRecapWeekStats,
        calorieGoal: Int
    ) -> [WeeklyRecapHighlight] {
        var result: [WeeklyRecapHighlight] = []
        if current.loggedDays == 7 {
            result.append(.loggedEveryDay)
        } else if current.longestLoggingStreak >= minimumHighlightStreak {
            result.append(.loggingStreak(days: current.longestLoggingStreak))
        }
        if current.workouts > previous.workouts {
            result.append(.moreWorkouts(current.workouts - previous.workouts))
        }
        if current.calorieTargetDays > previous.calorieTargetDays {
            result.append(.moreCalorieTargetDays(current.calorieTargetDays - previous.calorieTargetDays))
        }
        if current.proteinGoalDays > previous.proteinGoalDays {
            result.append(.moreProteinGoalDays(current.proteinGoalDays - previous.proteinGoalDays))
        }
        if current.loggedDays >= minimumDaysForAverageHighlight,
           let average = current.averageCalories,
           isOnCalorieTarget(average, goal: calorieGoal) {
            result.append(.averageCaloriesOnTarget)
        }
        // A full week is already called out above.
        if current.loggedDays < 7, current.loggedDays > previous.loggedDays {
            result.append(.moreLoggedDays(current.loggedDays - previous.loggedDays))
        }
        return Array(result.prefix(maximumHighlights))
    }

    /// Within ±10% of a positive calorie target.
    static func isOnCalorieTarget(_ calories: Int, goal: Int) -> Bool {
        guard goal > 0 else { return false }
        return abs(Double(calories - goal)) <= Double(goal) * calorieTolerance
    }

    /// Workout diary days in `days`: a day counts when its plan has work the user
    /// did (sets with reps or a saved timer) or a calculated burn.
    static func workoutDays(
        in days: ClosedRange<Date>,
        dayPlans: [String: StrengthWorkoutDayPlan],
        sessions: [StrengthWorkoutSession],
        calendar: Calendar = .current
    ) -> [WeeklyRecapWorkoutDay] {
        var burnByDay: [Date: Int] = [:]
        for burn in WorkoutBurnAggregation.daily(sessions: sessions, in: days, calendar: calendar) {
            burnByDay[burn.date] = burn.calories
        }
        let first = calendar.startOfDay(for: days.lowerBound)
        let dayCount = calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: days.upperBound)).day ?? 0
        guard dayCount >= 0 else { return [] }
        return (0...dayCount).compactMap { offset in
            let date = day(offset, from: first, calendar: calendar)
            let key = StrengthWorkoutDate.key(for: date, calendar: calendar)
            let performed = dayPlans[key]?.exercises.contains(where: \.hasCalculableWork) ?? false
            let burn = burnByDay[date]
            guard performed || burn != nil else { return nil }
            return WeeklyRecapWorkoutDay(date: date, calories: burn)
        }
    }

    /// The recap's energy amounts in `unit`. The burn change is the difference
    /// of the two shown values, so "1,464 kJ" after "1,255 kJ" reads "+209".
    static func energyFigures(
        current: WeeklyRecapWeekStats,
        previous: WeeklyRecapWeekStats,
        calorieGoal: Int,
        unit: EnergyUnit,
        locale: Locale = .current
    ) -> WeeklyRecapEnergyFigures {
        WeeklyRecapEnergyFigures(
            averageCalories: current.averageCalories.map { unit.number(kcal: $0, locale: locale) },
            calorieGoal: unit.number(kcal: calorieGoal, locale: locale),
            activeBurn: unit.format(kcal: current.activeBurnCalories, locale: locale),
            activeBurnChange: unit.displayValue(kcal: current.activeBurnCalories)
                - unit.displayValue(kcal: previous.activeBurnCalories)
        )
    }

    /// "+2", "−1" or "0" for the small change line under a recap stat.
    static func signedChange(_ delta: Int, locale: Locale = .current) -> String {
        let magnitude = abs(delta).formatted(.number.locale(locale))
        if delta > 0 { return "+\(magnitude)" }
        if delta < 0 { return "\u{2212}\(magnitude)" }
        return magnitude
    }

    private static func day(_ offset: Int, from date: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: calendar.date(byAdding: .day, value: offset, to: date) ?? date)
    }
}
