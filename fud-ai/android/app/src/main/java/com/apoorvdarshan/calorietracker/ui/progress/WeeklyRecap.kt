package com.apoorvdarshan.calorietracker.ui.progress

import com.apoorvdarshan.calorietracker.models.EnergyUnit
import com.apoorvdarshan.calorietracker.models.FoodEntry
import com.apoorvdarshan.calorietracker.models.WeightEntry
import com.apoorvdarshan.calorietracker.models.WorkoutDate
import com.apoorvdarshan.calorietracker.models.WorkoutDayPlan
import com.apoorvdarshan.calorietracker.models.WorkoutSession
import java.text.NumberFormat
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.TemporalAdjusters
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/** A workout diary day for the weekly recap. [calories] is that day's calculated burn,
 *  when the user calculated one. */
internal data class WeeklyRecapWorkoutDay(val date: LocalDate, val calories: Int?)

/** Totals for one recap week (seven local days). */
internal data class WeeklyRecapWeekStats(
    val loggedDays: Int = 0,
    /** Logged days within ±10% of the calorie target. */
    val calorieTargetDays: Int = 0,
    /** Logged days that reached the protein target. */
    val proteinGoalDays: Int = 0,
    /** Mean over the days with food logged; null when nothing was logged. */
    val averageCalories: Int? = null,
    /** Days with a logged workout. */
    val workouts: Int = 0,
    val activeBurnCalories: Int = 0,
    val weighIns: Int = 0,
    /** Last minus first weigh-in of the week; null with fewer than two. */
    val weightChangeKg: Double? = null,
    /** Longest run of consecutive days with food logged. */
    val longestLoggingStreak: Int = 0
) {
    val hasActivity: Boolean get() = loggedDays > 0 || workouts > 0 || weighIns > 0
}

/** Encouraging, deterministic call-outs. Only good news is highlighted, so a quieter
 *  week never reads as a scolding. */
internal sealed interface WeeklyRecapHighlight {
    data object LoggedEveryDay : WeeklyRecapHighlight
    data class LoggingStreak(val days: Int) : WeeklyRecapHighlight
    data class MoreWorkouts(val count: Int) : WeeklyRecapHighlight
    data class MoreCalorieTargetDays(val count: Int) : WeeklyRecapHighlight
    data class MoreProteinGoalDays(val count: Int) : WeeklyRecapHighlight
    data object AverageCaloriesOnTarget : WeeklyRecapHighlight
    data class MoreLoggedDays(val count: Int) : WeeklyRecapHighlight
}

/** The recap's energy figures as shown, in the user's display unit (#520). Totals, the
 *  ±10% target window and the comparisons all stay kcal; only these convert. */
internal data class WeeklyRecapEnergyFigures(
    /** Unitless average, e.g. "1,850" or "7,740"; null when nothing was logged. */
    val averageCalories: String?,
    /** Unitless calorie target for the average's caption. */
    val calorieGoal: String,
    /** Active burn in display units, shown with the unit label. */
    val activeBurn: Int,
    /** Change between the two weeks' shown burns, e.g. "+209". */
    val activeBurnChange: String
)

/** The Progress tab's recap of one completed week, compared with the week before it
 *  (#431). Mirrors ios/calorietracker/Models/WeeklyRecap.swift. */
internal data class WeeklyRecap(
    /** First local day of the recapped week. */
    val weekStart: LocalDate,
    /** Last local day of the recapped week. */
    val weekEnd: LocalDate,
    val current: WeeklyRecapWeekStats,
    /** The week just before, for the comparisons. */
    val previous: WeeklyRecapWeekStats,
    val highlights: List<WeeklyRecapHighlight>
)

internal object WeeklyRecapCalculator {
    const val CALORIE_TOLERANCE = 0.10
    const val MINIMUM_HIGHLIGHT_STREAK = 3
    /** An average over fewer days says little about the week. */
    const val MINIMUM_DAYS_FOR_AVERAGE_HIGHLIGHT = 3
    const val MAXIMUM_HIGHLIGHTS = 3

    /** The first day of a recap week for the app's Week starts on setting (Monday by
     *  default), not the locale's, matching iOS WeeklyRecap.calendar(weekStartsOnMonday:). */
    fun firstDayOfWeek(weekStartsOnMonday: Boolean): DayOfWeek =
        if (weekStartsOnMonday) DayOfWeek.MONDAY else DayOfWeek.SUNDAY

    /** Start of the recapped week. Offset 0 is the most recent completed week (the one
     *  before the week containing [today]), 1 the week before that. Weeks begin on
     *  [firstDayOfWeek] (see [firstDayOfWeek] for the setting). */
    fun weekStart(today: LocalDate, offset: Int, firstDayOfWeek: DayOfWeek): LocalDate =
        today.with(TemporalAdjusters.previousOrSame(firstDayOfWeek))
            .minusWeeks(offset.coerceAtLeast(0) + 1L)

    fun compute(
        foods: List<FoodEntry>,
        workouts: List<WeeklyRecapWorkoutDay>,
        weights: List<WeightEntry>,
        calorieGoal: Int,
        proteinGoal: Int,
        today: LocalDate,
        offset: Int,
        firstDayOfWeek: DayOfWeek,
        zone: ZoneId
    ): WeeklyRecap {
        val start = weekStart(today, offset, firstDayOfWeek)
        val current = stats(start, foods, workouts, weights, calorieGoal, proteinGoal, zone)
        val previous = stats(start.minusWeeks(1), foods, workouts, weights, calorieGoal, proteinGoal, zone)
        return WeeklyRecap(
            weekStart = start,
            weekEnd = start.plusDays(6),
            current = current,
            previous = previous,
            highlights = highlights(current, previous, calorieGoal)
        )
    }

    fun stats(
        weekStart: LocalDate,
        foods: List<FoodEntry>,
        workouts: List<WeeklyRecapWorkoutDay>,
        weights: List<WeightEntry>,
        calorieGoal: Int,
        proteinGoal: Int,
        zone: ZoneId
    ): WeeklyRecapWeekStats {
        val first = weekStart.atStartOfDay(zone).toInstant()
        val nextWeek = weekStart.plusWeeks(1).atStartOfDay(zone).toInstant()
        // The cheap instant check skips the day conversion for everything outside the week.
        fun dayIndex(instant: java.time.Instant): Int? {
            if (instant < first || instant >= nextWeek) return null
            val index = (instant.atZone(zone).toLocalDate().toEpochDay() - weekStart.toEpochDay()).toInt()
            return index.takeIf { it in 0..6 }
        }

        val logged = BooleanArray(7)
        val calories = IntArray(7)
        val protein = DoubleArray(7)
        for (entry in foods) {
            val index = dayIndex(entry.timestamp) ?: continue
            logged[index] = true
            calories[index] += entry.calories
            protein[index] += entry.protein
        }

        var loggedDays = 0
        var calorieTargetDays = 0
        var proteinGoalDays = 0
        var longestStreak = 0
        var streak = 0
        var totalCalories = 0L
        for (index in 0 until 7) {
            if (!logged[index]) {
                streak = 0
                continue
            }
            loggedDays += 1
            totalCalories += calories[index]
            streak += 1
            longestStreak = maxOf(longestStreak, streak)
            if (isOnCalorieTarget(calories[index], calorieGoal)) calorieTargetDays += 1
            // Rounded like the protein totals on screen, so "150 / 150 g" counts.
            if (proteinGoal > 0 && protein[index].roundToInt() >= proteinGoal) proteinGoalDays += 1
        }

        // One workout per diary day; the burn is that day's calculated estimate.
        val burnByDay = mutableMapOf<Long, Int>()
        val workoutDays = mutableSetOf<Long>()
        for (workout in workouts) {
            val offset = workout.date.toEpochDay() - weekStart.toEpochDay()
            if (offset !in 0L..6L) continue
            workoutDays += offset
            val burn = workout.calories?.takeIf { it > 0 } ?: continue
            burnByDay[offset] = maxOf(burnByDay[offset] ?: 0, burn)
        }

        val readings = weights.filter { dayIndex(it.date) != null }.sortedBy { it.date }
        return WeeklyRecapWeekStats(
            loggedDays = loggedDays,
            calorieTargetDays = calorieTargetDays,
            proteinGoalDays = proteinGoalDays,
            averageCalories = if (loggedDays > 0) (totalCalories.toDouble() / loggedDays).roundToInt() else null,
            workouts = workoutDays.size,
            activeBurnCalories = burnByDay.values.sum(),
            weighIns = readings.size,
            weightChangeKg = if (readings.size >= 2) readings.last().weightKg - readings.first().weightKg else null,
            longestLoggingStreak = longestStreak
        )
    }

    fun highlights(
        current: WeeklyRecapWeekStats,
        previous: WeeklyRecapWeekStats,
        calorieGoal: Int
    ): List<WeeklyRecapHighlight> = buildList {
        if (current.loggedDays == 7) {
            add(WeeklyRecapHighlight.LoggedEveryDay)
        } else if (current.longestLoggingStreak >= MINIMUM_HIGHLIGHT_STREAK) {
            add(WeeklyRecapHighlight.LoggingStreak(current.longestLoggingStreak))
        }
        if (current.workouts > previous.workouts) {
            add(WeeklyRecapHighlight.MoreWorkouts(current.workouts - previous.workouts))
        }
        if (current.calorieTargetDays > previous.calorieTargetDays) {
            add(WeeklyRecapHighlight.MoreCalorieTargetDays(current.calorieTargetDays - previous.calorieTargetDays))
        }
        if (current.proteinGoalDays > previous.proteinGoalDays) {
            add(WeeklyRecapHighlight.MoreProteinGoalDays(current.proteinGoalDays - previous.proteinGoalDays))
        }
        val average = current.averageCalories
        if (current.loggedDays >= MINIMUM_DAYS_FOR_AVERAGE_HIGHLIGHT && average != null &&
            isOnCalorieTarget(average, calorieGoal)
        ) {
            add(WeeklyRecapHighlight.AverageCaloriesOnTarget)
        }
        // A full week is already called out above.
        if (current.loggedDays < 7 && current.loggedDays > previous.loggedDays) {
            add(WeeklyRecapHighlight.MoreLoggedDays(current.loggedDays - previous.loggedDays))
        }
    }.take(MAXIMUM_HIGHLIGHTS)

    /** Within ±10% of a positive calorie target. */
    fun isOnCalorieTarget(calories: Int, goal: Int): Boolean =
        goal > 0 && abs((calories - goal).toDouble()) <= goal * CALORIE_TOLERANCE

    /** Workout diary days from [start] through [end]: a day counts when its plan has
     *  work the user did (sets with reps or a saved timer) or a calculated burn. */
    fun workoutDays(
        start: LocalDate,
        end: LocalDate,
        dayPlans: Map<String, WorkoutDayPlan>,
        burnSessions: List<WorkoutSession>
    ): List<WeeklyRecapWorkoutDay> {
        val burnByDay = preferredDailyWorkoutBurns(burnSessions).toMap()
        return generateSequence(start) { it.plusDays(1) }
            .takeWhile { !it.isAfter(end) }
            .mapNotNull { day ->
                val performed = dayPlans[WorkoutDate.key(day)]?.exercises?.any { it.hasCalculableWork } == true
                val burn = burnByDay[day]
                if (performed || burn != null) WeeklyRecapWorkoutDay(day, burn) else null
            }
            .toList()
    }

    /** The recap's energy amounts in [unit]. The burn change is the difference of the two
     *  shown values, so "1,464 kJ" after "1,255 kJ" reads "+209". */
    fun energyFigures(
        current: WeeklyRecapWeekStats,
        previous: WeeklyRecapWeekStats,
        calorieGoal: Int,
        unit: EnergyUnit,
        locale: Locale = Locale.getDefault()
    ): WeeklyRecapEnergyFigures {
        val burn = unit.displayValue(current.activeBurnCalories)
        return WeeklyRecapEnergyFigures(
            averageCalories = current.averageCalories?.let { unit.number(it, locale) },
            calorieGoal = unit.number(calorieGoal, locale),
            activeBurn = burn,
            activeBurnChange = signedChange(burn - unit.displayValue(previous.activeBurnCalories), locale)
        )
    }

    /** "+2", "−1" or "0" for the small change line under a recap stat. */
    fun signedChange(delta: Int, locale: Locale = Locale.getDefault()): String {
        val magnitude = NumberFormat.getIntegerInstance(locale).format(abs(delta.toLong()))
        return when {
            delta > 0 -> "+$magnitude"
            delta < 0 -> "−$magnitude"
            else -> magnitude
        }
    }
}
