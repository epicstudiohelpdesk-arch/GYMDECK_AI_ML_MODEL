package com.apoorvdarshan.calorietracker.ui.progress

import com.apoorvdarshan.calorietracker.models.EnergyUnit
import com.apoorvdarshan.calorietracker.models.ExerciseTimer
import com.apoorvdarshan.calorietracker.models.FoodEntry
import com.apoorvdarshan.calorietracker.models.FoodSource
import com.apoorvdarshan.calorietracker.models.PlannedExercise
import com.apoorvdarshan.calorietracker.models.PlannedSet
import com.apoorvdarshan.calorietracker.models.WeightEntry
import com.apoorvdarshan.calorietracker.models.WorkoutDayPlan
import com.apoorvdarshan.calorietracker.models.WorkoutSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.util.Locale

class WeeklyRecapTest {
    private val zone = ZoneOffset.UTC
    private val weekStart = LocalDate.parse("2026-10-05")

    // Week boundaries

    @Test
    fun recapsTheLastCompletedWeekFromTheFirstDayOfWeek() {
        // Saturday, October 17, 2026.
        val saturday = LocalDate.parse("2026-10-17")
        assertEquals(LocalDate.parse("2026-10-05"), WeeklyRecapCalculator.weekStart(saturday, 0, DayOfWeek.MONDAY))
        assertEquals(LocalDate.parse("2026-09-28"), WeeklyRecapCalculator.weekStart(saturday, 1, DayOfWeek.MONDAY))
        assertEquals(LocalDate.parse("2026-10-04"), WeeklyRecapCalculator.weekStart(saturday, 0, DayOfWeek.SUNDAY))
    }

    @Test
    fun weeksFollowTheWeekStartsOnSettingInsteadOfTheLocale() {
        // Whatever the locale's first day, the setting picks it (Monday by default).
        assertEquals(DayOfWeek.MONDAY, WeeklyRecapCalculator.firstDayOfWeek(weekStartsOnMonday = true))
        assertEquals(DayOfWeek.SUNDAY, WeeklyRecapCalculator.firstDayOfWeek(weekStartsOnMonday = false))

        // A Sunday meal belongs to the recapped week only when weeks start on Sunday.
        val foods = listOf(food(2_000, protein = 150.0, at = "2026-10-04T12:00"))
        fun recap(weekStartsOnMonday: Boolean) = WeeklyRecapCalculator.compute(
            foods = foods,
            workouts = emptyList(),
            weights = emptyList(),
            calorieGoal = 2_000,
            proteinGoal = 150,
            today = LocalDate.parse("2026-10-17"),
            offset = 0,
            firstDayOfWeek = WeeklyRecapCalculator.firstDayOfWeek(weekStartsOnMonday),
            zone = zone
        )

        val mondayFirst = recap(weekStartsOnMonday = true)
        assertEquals(LocalDate.parse("2026-10-05"), mondayFirst.weekStart)
        assertEquals(LocalDate.parse("2026-10-11"), mondayFirst.weekEnd)
        assertEquals(0, mondayFirst.current.loggedDays)
        assertEquals(1, mondayFirst.previous.loggedDays)

        val sundayFirst = recap(weekStartsOnMonday = false)
        assertEquals(LocalDate.parse("2026-10-04"), sundayFirst.weekStart)
        assertEquals(LocalDate.parse("2026-10-10"), sundayFirst.weekEnd)
        assertEquals(1, sundayFirst.current.loggedDays)
    }

    @Test
    fun theCurrentWeekIsNeverRecappedBeforeItEnds() {
        // On the current week's final day the recap still shows the week before it.
        assertEquals(
            LocalDate.parse("2026-10-05"),
            WeeklyRecapCalculator.weekStart(LocalDate.parse("2026-10-18"), 0, DayOfWeek.MONDAY)
        )
        // The next day the finished week becomes the recap.
        assertEquals(
            LocalDate.parse("2026-10-12"),
            WeeklyRecapCalculator.weekStart(LocalDate.parse("2026-10-19"), 0, DayOfWeek.MONDAY)
        )
    }

    @Test
    fun aTimeZoneChangeOnTheSameLocalDateRegroupsLateNightEntries() {
        // The card caches the recap by its inputs, so the zone is one of them: travel
        // can move entries across midnight while "today" stays Saturday the 17th.
        val sundayNightUtc = Instant.parse("2026-10-11T20:00:00Z")
        val foods = listOf(
            FoodEntry(
                name = "Meal",
                calories = 2_000,
                protein = 150.0,
                carbs = 0.0,
                fat = 0.0,
                timestamp = sundayNightUtc,
                source = FoodSource.MANUAL
            )
        )
        val weights = listOf(
            WeightEntry(date = Instant.parse("2026-10-05T08:00:00Z"), weightKg = 80.0),
            WeightEntry(date = sundayNightUtc, weightKg = 79.5)
        )
        fun recap(zone: java.time.ZoneId) = WeeklyRecapCalculator.compute(
            foods = foods,
            workouts = emptyList(),
            weights = weights,
            calorieGoal = 2_000,
            proteinGoal = 150,
            today = LocalDate.parse("2026-10-17"),
            offset = 0,
            firstDayOfWeek = DayOfWeek.MONDAY,
            zone = zone
        )

        // Sunday 20:00 in UTC ends the recapped week (October 5–11)...
        val utc = recap(ZoneOffset.UTC)
        assertEquals(1, utc.current.loggedDays)
        assertEquals(2, utc.current.weighIns)
        assertEquals(-0.5, utc.current.weightChangeKg!!, 1e-9)

        // ...but is Monday 05:00 in Tokyo, the current week, so it leaves the recap.
        val tokyo = recap(java.time.ZoneId.of("Asia/Tokyo"))
        assertEquals(0, tokyo.current.loggedDays)
        assertEquals(1, tokyo.current.weighIns)
        assertNull(tokyo.current.weightChangeKg)
    }

    // Week stats

    @Test
    fun countsLoggedTargetAndProteinDaysInsideTheWeek() {
        val foods = listOf(
            food(2_000, protein = 150.0, at = "2026-10-05T12:00"),
            // 2,150 is within 10% of 2,000; 149.6 g shows as 150 g.
            food(2_150, protein = 149.6, at = "2026-10-06T12:00"),
            food(2_300, protein = 100.0, at = "2026-10-07T12:00"),
            // Two meals that together miss the range but reach protein.
            food(900, protein = 80.0, at = "2026-10-09T09:00"),
            food(800, protein = 80.0, at = "2026-10-09T19:00"),
            // Exactly 10% under still counts.
            food(1_800, protein = 50.0, at = "2026-10-10T12:00"),
            food(500, protein = 20.0, at = "2026-10-11T23:59"),
            // Outside the week on either side.
            food(2_000, protein = 150.0, at = "2026-10-04T23:59"),
            food(2_000, protein = 150.0, at = "2026-10-12T00:00")
        )

        val stats = stats(foods = foods)

        assertEquals(6, stats.loggedDays)
        assertEquals(3, stats.calorieTargetDays)
        assertEquals(3, stats.proteinGoalDays)
        assertEquals(1_742, stats.averageCalories) // 10,450 / 6 days
        assertEquals(3, stats.longestLoggingStreak)
        assertTrue(stats.hasActivity)
    }

    @Test
    fun anEmptyWeekHasNoAverageOrActivity() {
        val stats = stats()
        assertEquals(WeeklyRecapWeekStats(), stats)
        assertNull(stats.averageCalories)
        assertFalse(stats.hasActivity)
    }

    @Test
    fun countsOneWorkoutPerDayWithItsBurn() {
        val workouts = listOf(
            WeeklyRecapWorkoutDay(LocalDate.parse("2026-10-06"), null),
            WeeklyRecapWorkoutDay(LocalDate.parse("2026-10-06"), 300),
            WeeklyRecapWorkoutDay(LocalDate.parse("2026-10-08"), 250),
            WeeklyRecapWorkoutDay(LocalDate.parse("2026-10-12"), 900)
        )

        val stats = stats(workouts = workouts)

        assertEquals(2, stats.workouts)
        assertEquals(550, stats.activeBurnCalories)
        assertTrue(stats.hasActivity)
    }

    @Test
    fun weightChangeIsLastMinusFirstReadingOfTheWeek() {
        val weights = listOf(
            weight(79.4, at = "2026-10-11T20:00"),
            weight(80.0, at = "2026-10-05T08:00"),
            weight(79.9, at = "2026-10-08T08:00"),
            weight(70.0, at = "2026-10-12T08:00")
        )

        val stats = stats(weights = weights)
        assertEquals(3, stats.weighIns)
        assertEquals(-0.6, stats.weightChangeKg!!, 0.0001)

        val single = stats(weights = listOf(weights[2]))
        assertEquals(1, single.weighIns)
        assertNull(single.weightChangeKg)
    }

    @Test
    fun comparesTheRecappedWeekWithTheOneBefore() {
        val foods = listOf(
            food(2_000, protein = 150.0, at = "2026-09-29T12:00"),
            food(2_000, protein = 150.0, at = "2026-09-22T12:00"),
            food(2_000, protein = 150.0, at = "2026-09-23T12:00")
        )

        val recap = WeeklyRecapCalculator.compute(
            foods = foods,
            workouts = emptyList(),
            weights = emptyList(),
            calorieGoal = 2_000,
            proteinGoal = 150,
            today = LocalDate.parse("2026-10-17"),
            offset = 1,
            firstDayOfWeek = DayOfWeek.MONDAY,
            zone = zone
        )

        assertEquals(LocalDate.parse("2026-09-28"), recap.weekStart)
        assertEquals(LocalDate.parse("2026-10-04"), recap.weekEnd)
        assertEquals(1, recap.current.loggedDays)
        assertEquals(2, recap.previous.loggedDays)
        // A quieter week is never called out.
        assertEquals(emptyList<WeeklyRecapHighlight>(), recap.highlights)
    }

    // Highlights

    @Test
    fun highlightsOnlyImprovementsInPriorityOrder() {
        val current = WeeklyRecapWeekStats(
            loggedDays = 7,
            longestLoggingStreak = 7,
            workouts = 3,
            calorieTargetDays = 5,
            proteinGoalDays = 4,
            averageCalories = 2_050
        )
        val previous = WeeklyRecapWeekStats(
            loggedDays = 5,
            workouts = 1,
            calorieTargetDays = 2,
            proteinGoalDays = 4
        )

        assertEquals(
            listOf(
                WeeklyRecapHighlight.LoggedEveryDay,
                WeeklyRecapHighlight.MoreWorkouts(2),
                WeeklyRecapHighlight.MoreCalorieTargetDays(3)
            ),
            WeeklyRecapCalculator.highlights(current, previous, calorieGoal = 2_000)
        )
    }

    @Test
    fun aStreakAndMoreLoggedDaysAreCalledOutWithoutAFullWeek() {
        val current = WeeklyRecapWeekStats(loggedDays = 5, longestLoggingStreak = 4, averageCalories = 2_190)
        val previous = WeeklyRecapWeekStats(loggedDays = 3)

        assertEquals(
            listOf(
                WeeklyRecapHighlight.LoggingStreak(4),
                WeeklyRecapHighlight.AverageCaloriesOnTarget,
                WeeklyRecapHighlight.MoreLoggedDays(2)
            ),
            WeeklyRecapCalculator.highlights(current, previous, calorieGoal = 2_000)
        )

        // Short streaks, a missed average and fewer days stay quiet.
        val quieter = WeeklyRecapWeekStats(loggedDays = 2, longestLoggingStreak = 2, averageCalories = 2_300)
        assertEquals(
            emptyList<WeeklyRecapHighlight>(),
            WeeklyRecapCalculator.highlights(quieter, previous, calorieGoal = 2_000)
        )
    }

    @Test
    fun averageCaloriesNeedEnoughLoggedDays() {
        val current = WeeklyRecapWeekStats(loggedDays = 2, longestLoggingStreak = 2, averageCalories = 2_000)
        assertEquals(
            emptyList<WeeklyRecapHighlight>(),
            WeeklyRecapCalculator.highlights(current, current, calorieGoal = 2_000)
        )
        assertFalse(WeeklyRecapCalculator.isOnCalorieTarget(2_000, goal = 0))
    }

    // Workout diary days

    @Test
    fun workoutDaysComeFromPerformedPlansAndCalculatedBurns() {
        val strength = exercise("bench", "strength").copy(sets = listOf(PlannedSet(reps = "8")))
        val plannedOnly = exercise("squat", "strength")
        val cardio = exercise("run", "cardio").copy(
            timer = ExerciseTimer(accumulatedSeconds = 1_200.0, savedDurationSeconds = 1_200.0)
        )
        val plans = mapOf(
            "2026-10-05" to WorkoutDayPlan("2026-10-05", listOf(strength)),
            // Added but not done yet.
            "2026-10-06" to WorkoutDayPlan("2026-10-06", listOf(plannedOnly)),
            "2026-10-07" to WorkoutDayPlan("2026-10-07", listOf(cardio)),
            // Outside the range.
            "2026-10-12" to WorkoutDayPlan("2026-10-12", listOf(strength))
        )
        val burns = listOf(
            burn("2026-10-07", 320),
            // A burn whose diary plan was cleared afterwards still counts.
            burn("2026-10-09", 180)
        )

        assertEquals(
            listOf(
                WeeklyRecapWorkoutDay(LocalDate.parse("2026-10-05"), null),
                WeeklyRecapWorkoutDay(LocalDate.parse("2026-10-07"), 320),
                WeeklyRecapWorkoutDay(LocalDate.parse("2026-10-09"), 180)
            ),
            WeeklyRecapCalculator.workoutDays(
                start = weekStart,
                end = weekStart.plusDays(6),
                dayPlans = plans,
                burnSessions = burns
            )
        )
    }

    // Formatting

    @Test
    fun changesShowTheirSign() {
        assertEquals("+2", WeeklyRecapCalculator.signedChange(2, Locale.US))
        assertEquals("−1", WeeklyRecapCalculator.signedChange(-1, Locale.US))
        assertEquals("0", WeeklyRecapCalculator.signedChange(0, Locale.US))
        assertEquals("+1,234", WeeklyRecapCalculator.signedChange(1_234, Locale.US))
    }

    @Test
    fun energyFiguresInKilocaloriesAreUnchanged() {
        val current = WeeklyRecapWeekStats(loggedDays = 3, averageCalories = 1_850, activeBurnCalories = 350)
        val previous = WeeklyRecapWeekStats(loggedDays = 2, averageCalories = 2_400, activeBurnCalories = 300)

        assertEquals(
            WeeklyRecapEnergyFigures(averageCalories = "1,850", calorieGoal = "2,000", activeBurn = 350, activeBurnChange = "+50"),
            WeeklyRecapCalculator.energyFigures(current, previous, 2_000, EnergyUnit.KCAL, Locale.US)
        )
    }

    @Test
    fun energyFiguresConvertToKilojoules() {
        val current = WeeklyRecapWeekStats(loggedDays = 3, averageCalories = 1_850, activeBurnCalories = 350)

        // 1,850 kcal = 7,740 kJ, 2,000 = 8,368, 350 = 1,464 and 300 = 1,255.
        assertEquals(
            WeeklyRecapEnergyFigures(averageCalories = "7,740", calorieGoal = "8,368", activeBurn = 1_464, activeBurnChange = "+209"),
            WeeklyRecapCalculator.energyFigures(current, WeeklyRecapWeekStats(activeBurnCalories = 300), 2_000, EnergyUnit.KJ, Locale.US)
        )
        // The change is between the shown values (1,464 − 1,674), not −50 kcal converted (−209).
        val more = WeeklyRecapCalculator.energyFigures(current, WeeklyRecapWeekStats(activeBurnCalories = 400), 2_000, EnergyUnit.KJ, Locale.US)
        assertEquals("−210", more.activeBurnChange)
        // Locale grouping still applies, and an empty week has no average.
        val german = WeeklyRecapCalculator.energyFigures(WeeklyRecapWeekStats(), WeeklyRecapWeekStats(), 2_000, EnergyUnit.KJ, Locale.GERMANY)
        assertNull(german.averageCalories)
        assertEquals("8.368", german.calorieGoal)
        assertEquals("0", german.activeBurnChange)
    }

    @Test
    fun theCalorieTargetWindowStaysInKilocalories() {
        // 1,850 kcal is within ±10% of 2,000 kcal whatever unit the card shows it in.
        val recap = WeeklyRecapCalculator.compute(
            foods = (5..7).map { day -> food(1_850, protein = 0.0, at = "2026-10-0${day}T12:00") },
            workouts = emptyList(),
            weights = emptyList(),
            calorieGoal = 2_000,
            proteinGoal = 0,
            today = LocalDate.parse("2026-10-17"),
            offset = 0,
            firstDayOfWeek = DayOfWeek.MONDAY,
            zone = zone
        )
        assertEquals(3, recap.current.calorieTargetDays)
        assertEquals(1_850, recap.current.averageCalories)
        assertTrue(WeeklyRecapHighlight.AverageCaloriesOnTarget in recap.highlights)
        assertEquals("7,740", WeeklyRecapCalculator.energyFigures(recap.current, recap.previous, 2_000, EnergyUnit.KJ, Locale.US).averageCalories)
    }

    // Helpers

    private fun stats(
        foods: List<FoodEntry> = emptyList(),
        workouts: List<WeeklyRecapWorkoutDay> = emptyList(),
        weights: List<WeightEntry> = emptyList()
    ) = WeeklyRecapCalculator.stats(
        weekStart = weekStart,
        foods = foods,
        workouts = workouts,
        weights = weights,
        calorieGoal = 2_000,
        proteinGoal = 150,
        zone = zone
    )

    private fun food(calories: Int, protein: Double, at: String) = FoodEntry(
        name = "Meal",
        calories = calories,
        protein = protein,
        carbs = 0.0,
        fat = 0.0,
        timestamp = LocalDateTime.parse(at).toInstant(zone),
        source = FoodSource.MANUAL
    )

    private fun weight(kg: Double, at: String) =
        WeightEntry(date = LocalDateTime.parse(at).toInstant(zone), weightKg = kg)

    private fun exercise(id: String, category: String) = PlannedExercise(
        itemId = id,
        name = id,
        level = "beginner",
        imagePaths = emptyList(),
        force = "",
        mechanic = "",
        category = category,
        equipment = "",
        primaryMuscles = emptyList(),
        secondaryMuscles = emptyList(),
        instructions = emptyList()
    )

    private fun burn(date: String, calories: Int): WorkoutSession {
        val completed = Instant.parse("${date}T18:00:00Z")
        return WorkoutSession(
            diaryDateKey = date,
            startedAt = completed,
            completedAt = completed,
            exercises = emptyList(),
            caloriesBurned = calories,
            healthSyncVersion = 1
        )
    }
}
