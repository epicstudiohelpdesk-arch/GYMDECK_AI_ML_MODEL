package com.apoorvdarshan.calorietracker.services.ai

import com.apoorvdarshan.calorietracker.data.ExerciseItem
import com.apoorvdarshan.calorietracker.data.ExerciseRecord
import com.apoorvdarshan.calorietracker.models.CompletedExercise
import com.apoorvdarshan.calorietracker.models.CompletedSet
import com.apoorvdarshan.calorietracker.models.ExerciseTimer
import com.apoorvdarshan.calorietracker.models.PlannedExercise
import com.apoorvdarshan.calorietracker.models.PlannedSet
import com.apoorvdarshan.calorietracker.models.WorkoutDayPlan
import com.apoorvdarshan.calorietracker.models.WorkoutIssue
import com.apoorvdarshan.calorietracker.models.WorkoutIntensity
import com.apoorvdarshan.calorietracker.models.WorkoutPreferences
import com.apoorvdarshan.calorietracker.models.WorkoutRpeScale
import com.apoorvdarshan.calorietracker.models.WorkoutSession
import com.apoorvdarshan.calorietracker.models.WorkoutSplit
import com.apoorvdarshan.calorietracker.models.WorkoutStrengthNumbers
import com.apoorvdarshan.calorietracker.models.WorkoutWeightUnit
import com.apoorvdarshan.calorietracker.services.voice.RepoFiles
import com.google.gson.Gson
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import com.google.gson.reflect.TypeToken
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.Clock
import java.time.ZoneOffset
import java.util.UUID

class CoachWorkoutToolsTest {

    @Test
    fun savedCardioCountsAsPerformedAndKeepsDurationWithoutSetsOrReps() {
        val cardio = plannedExercise(emptyList()).copy(
            itemId = "Running_Treadmill",
            name = "Running, Treadmill",
            category = "cardio",
            timer = ExerciseTimer(accumulatedSeconds = 600.5, savedDurationSeconds = 600.5, intensity = WorkoutIntensity.VIGOROUS)
        )
        val completed = CompletedExercise(
            itemId = cardio.itemId,
            name = cardio.name,
            targetMuscles = cardio.primaryMuscles,
            equipment = cardio.equipment,
            sets = emptyList(),
            durationSeconds = 600.5,
            intensity = WorkoutIntensity.VIGOROUS
        )
        val workout = session("2026-07-20", "2026-07-20T10:00:00Z", durationSeconds = 0, caloriesBurned = 120,
            exercise = cardio.name, sets = emptyList()).copy(exercises = listOf(completed))
        val tools = tools(workoutSessions = listOf(workout), workoutPlans = listOf(WorkoutDayPlan("2026-07-20", listOf(cardio))))
        val range = mapOf("from" to "2026-07-20", "to" to "2026-07-20")
        val planExercise = json(tools.execute("get_workout_plans", range)).getAsJsonArray("plans")[0].asJsonObject
            .getAsJsonArray("exercises")[0].asJsonObject
        assertTrue(planExercise["performed"].asBoolean)
        assertEquals(600.5, planExercise["duration_seconds"].asDouble, 0.001)
        assertEquals("saved", planExercise.getAsJsonObject("timer")["state"].asString)
        val historyExercise = json(tools.execute("get_workout_history", range)).getAsJsonArray("workouts")[0].asJsonObject
            .getAsJsonArray("exercises")[0].asJsonObject
        assertTrue(historyExercise["performed"].asBoolean)
        assertEquals(600.5, historyExercise["duration_seconds"].asDouble, 0.001)
        assertEquals("Vigorous", historyExercise["intensity"].asString)
        assertEquals(0, historyExercise.getAsJsonArray("sets").size())
        val summary = json(tools.execute("get_training_summary", range))
        assertEquals(0, summary["sets"].asInt)
        assertEquals(0, summary["reps"].asInt)
        assertEquals(600.5, summary["timed_exercise_seconds"].asDouble, 0.001)
        assertEquals(600.5, summary.getAsJsonArray("by_exercise")[0].asJsonObject["duration_seconds"].asDouble, 0.001)
    }

    @Test
    fun runningAndPausedPlanTimersRemainUnsaved() {
        val now = Instant.parse("2026-07-20T10:00:00Z")
        val running = plannedExercise(emptyList()).copy(
            timer = ExerciseTimer(accumulatedSeconds = 30.0, runningSince = now.minusSeconds(90))
        )
        val paused = running.copy(timer = ExerciseTimer(accumulatedSeconds = 45.0))
        val tools = CoachTools(
            weights = emptyList(), bodyFats = emptyList(), foods = emptyList(),
            workoutPlans = listOf(WorkoutDayPlan("2026-07-20", listOf(running, paused))),
            clock = Clock.fixed(now, ZoneOffset.UTC)
        )
        val exercises = json(tools.execute("get_workout_plans", mapOf("from" to "2026-07-20", "to" to "2026-07-20")))
            .getAsJsonArray("plans")[0].asJsonObject.getAsJsonArray("exercises")
        val runningPayload = exercises[0].asJsonObject
        val pausedPayload = exercises[1].asJsonObject
        assertEquals("running", runningPayload.getAsJsonObject("timer")["state"].asString)
        assertEquals(120.0, runningPayload.getAsJsonObject("timer")["elapsed_seconds"].asDouble, 0.001)
        assertEquals("2026-07-20T09:58:30Z", runningPayload.getAsJsonObject("timer")["running_since"].asString)
        assertEquals("paused", pausedPayload.getAsJsonObject("timer")["state"].asString)
        assertEquals(45.0, pausedPayload.getAsJsonObject("timer")["elapsed_seconds"].asDouble, 0.001)
        for (payload in listOf(runningPayload, pausedPayload)) {
            assertFalse(payload.has("duration_seconds"))
            assertFalse(payload["performed"].asBoolean)
        }
    }

    @Test
    fun workoutToolsAreAlwaysAvailableAndOnlyRangeQueriesRequireDates() {
        assertTrue(CoachTools.TOOL_NAMES.containsAll(CoachTools.WORKOUT_TOOL_NAMES))

        for (name in listOf("get_data_summary", "get_workout_plans", "get_workout_preferences")) {
            assertFalse(CoachTools.parameterSchemaFor(name).containsKey("required"))
        }
        @Suppress("UNCHECKED_CAST")
        val planProperties = CoachTools.parameterSchemaFor("get_workout_plans")["properties"] as Map<String, Any>
        assertTrue(planProperties.containsKey("from"))
        assertTrue(planProperties.containsKey("to"))

        for (name in listOf("get_workout_history", "get_training_summary")) {
            assertEquals(listOf("from", "to"), CoachTools.parameterSchemaFor(name)["required"])
        }
        assertEquals(listOf("exercise"), CoachTools.parameterSchemaFor("get_exercise_lift_history")["required"])
    }

    @Test
    fun exerciseLiftHistoryReturnsRecentSetsForOneLift() {
        val logged = session(
            dateKey = "2026-07-19",
            completedAt = "2026-07-19T10:00:00Z",
            caloriesBurned = 180,
            exercise = "Bench Press",
            sets = listOf(set(1, "60", "8", "7"))
        )
        val payload = json(
            tools(workoutSessions = listOf(logged), workoutPlanWeightUnit = WorkoutWeightUnit.KG)
                .execute("get_exercise_lift_history", mapOf("exercise" to "Bench Press", "to" to "2026-07-20"))
        )
        assertEquals(1, payload["count"].asInt)
        val sessions = payload.getAsJsonArray("sessions")
        assertEquals("2026-07-19", sessions[0].asJsonObject["date"].asString)
        val sets = sessions[0].asJsonObject.getAsJsonArray("sets")
        assertEquals("60", sets[0].asJsonObject["weight"].asString)
        assertEquals(8, sets[0].asJsonObject["reps"].asInt)
        assertEquals("2026-07-19", payload.getAsJsonObject("last_session")["date"].asString)
    }

    @Test
    fun exerciseLiftHistoryIgnoresUnsavedDayPlans() {
        val plan = WorkoutDayPlan(
            dateKey = "2026-07-19",
            exercises = listOf(
                plannedExercise(
                    listOf(PlannedSet(weight = "60", weightUnit = WorkoutWeightUnit.KG, reps = "8"))
                ).copy(itemId = "bench", name = "Bench Press")
            )
        )
        val payload = json(
            tools(workoutPlans = listOf(plan), workoutPlanWeightUnit = WorkoutWeightUnit.KG)
                .execute("get_exercise_lift_history", mapOf("exercise" to "Bench Press", "to" to "2026-07-20"))
        )
        assertEquals(0, payload["count"].asInt)
        assertFalse(payload.has("last_session"))
    }

    @Test
    fun exerciseLiftHistoryToleratesMalformedDates() {
        val logged = session(
            dateKey = "2026-07-19",
            completedAt = "2026-07-19T10:00:00Z",
            caloriesBurned = 180,
            exercise = "Bench Press",
            sets = listOf(set(1, "60", "8", "7"))
        )
        val payload = json(
            tools(
                workoutSessions = listOf(logged),
                workoutPlanWeightUnit = WorkoutWeightUnit.KG,
                clock = Clock.fixed(Instant.parse("2026-07-20T12:00:00Z"), ZoneOffset.UTC)
            ).execute(
                "get_exercise_lift_history",
                mapOf("exercise" to "Bench Press", "from" to "not-a-date", "to" to "also-bad")
            )
        )
        assertEquals(1, payload["count"].asInt)
    }

    @Test
    fun exerciseLiftHistoryRespectsCatalogIdOverSameName() {
        val catalogBench = session(
            dateKey = "2026-07-19",
            completedAt = "2026-07-19T10:00:00Z",
            caloriesBurned = 180,
            exercise = "Bench Press",
            sets = listOf(set(1, "60", "8", "7"))
        )
        val customBench = session(
            dateKey = "2026-07-18",
            completedAt = "2026-07-18T10:00:00Z",
            caloriesBurned = 170,
            exercise = "Bench Press",
            sets = listOf(set(1, "100", "5", "8"))
        ).copy(
            exercises = listOf(
                CompletedExercise(
                    itemId = "custom-bench",
                    name = "Bench Press",
                    targetMuscles = listOf("Chest"),
                    equipment = "Barbell",
                    sets = listOf(set(1, "100", "5", "8"))
                )
            )
        )
        val payload = json(
            tools(workoutSessions = listOf(catalogBench, customBench), workoutPlanWeightUnit = WorkoutWeightUnit.KG)
                .execute(
                    "get_exercise_lift_history",
                    mapOf(
                        "exercise" to "Bench Press",
                        "catalog_id" to "bench-press",
                        "to" to "2026-07-20"
                    )
                )
        )
        assertEquals(1, payload["count"].asInt)
        val sets = payload.getAsJsonArray("sessions")[0].asJsonObject.getAsJsonArray("sets")
        assertEquals("60", sets[0].asJsonObject["weight"].asString)
    }

    @Test
    fun exerciseLiftHistoryUsesAuthoritativeSameDaySnapshot() {
        val legacy = session(
            dateKey = "2026-07-12",
            completedAt = "2026-07-12T08:00:00Z",
            exercise = "Bench Press",
            sets = listOf(set(1, "80", "5", "7"))
        )
        val newerClockButOlderVersion = session(
            dateKey = "2026-07-12",
            completedAt = "2026-07-12T11:00:00Z",
            caloriesBurned = 190,
            healthSyncVersion = 1,
            exercise = "Bench Press",
            sets = listOf(set(1, "82.5", "6", "7.5"))
        )
        val authoritative = session(
            dateKey = "2026-07-12",
            completedAt = "2026-07-12T10:00:00Z",
            caloriesBurned = 210,
            healthSyncVersion = 2,
            exercise = "Bench Press",
            sets = listOf(set(1, "85", "8", "8"))
        )
        val payload = json(
            tools(workoutSessions = listOf(legacy, newerClockButOlderVersion, authoritative))
                .execute(
                    "get_exercise_lift_history",
                    mapOf("exercise" to "Bench Press", "to" to "2026-07-20")
                )
        )
        val sets = payload.getAsJsonArray("sessions")[0].asJsonObject.getAsJsonArray("sets")
        assertEquals("85", sets[0].asJsonObject["weight"].asString)
        assertEquals(8, sets[0].asJsonObject["reps"].asInt)
    }

    @Test
    fun summaryAndHistoryUseNewestCalculatedSameDaySnapshot() {
        val legacy = session(
            dateKey = "2026-07-12",
            completedAt = "2026-07-12T08:00:00Z",
            exercise = "Bench Press",
            sets = listOf(set(1, "80", "5", "7"))
        )
        val newerClockButOlderVersion = session(
            dateKey = "2026-07-12",
            completedAt = "2026-07-12T11:00:00Z",
            caloriesBurned = 190,
            healthSyncVersion = 1,
            exercise = "Bench Press",
            sets = listOf(set(1, "82.5", "6", "7.5"))
        )
        val authoritative = session(
            dateKey = "2026-07-12",
            completedAt = "2026-07-12T10:00:00Z",
            caloriesBurned = 210,
            healthSyncVersion = 2,
            exercise = "Bench Press",
            sets = listOf(set(1, "85", "8", "8"))
        )
        val otherDay = session(
            dateKey = "2026-07-18",
            completedAt = "2026-07-18T10:00:00Z",
            exercise = "Back Squat",
            sets = listOf(set(1, "120", "3", "9"))
        )
        val tools = tools(
            workoutSessions = listOf(legacy, newerClockButOlderVersion, authoritative, otherDay),
            workoutPlans = listOf(WorkoutDayPlan("2026-07-20"))
        )

        val dataSummary = json(tools.execute("get_data_summary"))
        val workouts = dataSummary.getAsJsonObject("workouts")
        assertEquals(2, workouts["count"].asInt)
        assertEquals("2026-07-12", workouts["first_date"].asString)
        assertEquals("2026-07-18", workouts["last_date"].asString)
        assertEquals(1, dataSummary.getAsJsonObject("workout_plans")["count"].asInt)

        val history = json(
            tools.execute(
                "get_workout_history",
                mapOf("from" to "2026-07-12", "to" to "2026-07-12")
            )
        )
        assertEquals(1, history["count"].asInt)
        val workout = history.getAsJsonArray("workouts")[0].asJsonObject
        assertEquals(authoritative.id.toString(), workout["id"].asString)
        assertEquals(210, workout["calories_burned"].asInt)
        assertEquals("2026-07-12T10:00:00Z", workout["completed_at"].asString)
        val loggedSet = workout.getAsJsonArray("exercises")[0].asJsonObject
            .getAsJsonArray("sets")[0].asJsonObject
        assertTrue(loggedSet["performed"].asBoolean)
        assertEquals(85.0, loggedSet["weight_kg"].asDouble, 0.0001)
        assertEquals(8, loggedSet["reps"].asInt)
        assertEquals(WorkoutRpeScale.STRENGTH.title, loggedSet["rpe_scale"].asString)
    }

    @Test
    fun planAndPreferencePayloadsPreserveWorkoutConfiguration() {
        val plan = WorkoutDayPlan(
            dateKey = "2026-07-20",
            exercises = listOf(
                plannedExercise(
                    sets = listOf(
                        PlannedSet(
                            weight = "32.5",
                            weightUnit = WorkoutWeightUnit.KG,
                            reps = "10",
                            rpe = "8.5",
                            rpeScale = WorkoutRpeScale.CR10
                        ),
                        PlannedSet()
                    )
                )
            )
        )
        val preferences = WorkoutPreferences(
            targetMuscles = setOf("Shoulders", "Chest"),
            issues = setOf(WorkoutIssue.WRIST, WorkoutIssue.SHOULDER),
            additionalIssues = "No overhead lockout",
            frequencyDays = 4,
            durationMinutes = 75,
            split = WorkoutSplit.UPPER_LOWER,
            equipment = setOf("Dumbbells", "Bench"),
            rpeScale = WorkoutRpeScale.CR10,
            strength = WorkoutStrengthNumbers(
                benchPressKg = 110.0,
                squatKg = 150.0,
                deadliftKg = null,
                overheadPressKg = 65.0
            )
        )
        val tools = tools(
            workoutPlans = listOf(WorkoutDayPlan("2026-07-19"), plan),
            workoutPreferences = preferences,
            workoutPlanWeightUnit = WorkoutWeightUnit.LBS
        )

        val plans = json(
            tools.execute(
                "get_workout_plans",
                mapOf("from" to "2026-07-20", "to" to "2026-07-20")
            )
        )
        assertEquals(1, plans["count"].asInt)
        val exercise = plans.getAsJsonArray("plans")[0].asJsonObject
            .getAsJsonArray("exercises")[0].asJsonObject
        assertEquals("incline-bench", exercise["catalog_id"].asString)
        assertEquals("Incline Bench Press", exercise["name"].asString)
        val sets = exercise.getAsJsonArray("sets")
        assertEquals("32.5", sets[0].asJsonObject["weight"].asString)
        assertEquals("kg", sets[0].asJsonObject["weight_unit"].asString)
        assertEquals(10, sets[0].asJsonObject["reps"].asInt)
        assertEquals(8.5, sets[0].asJsonObject["rpe"].asDouble, 0.0001)
        assertEquals(WorkoutRpeScale.CR10.title, sets[0].asJsonObject["rpe_scale"].asString)
        assertFalse(sets[1].asJsonObject.has("weight"))
        assertEquals("lbs", sets[1].asJsonObject["weight_unit"].asString)

        val prefs = json(tools.execute("get_workout_preferences"))
        assertTrue(prefs["configured"].asBoolean)
        assertEquals(listOf("Chest", "Shoulders"), prefs.getAsJsonArray("target_muscles").map { it.asString })
        assertEquals(listOf("Shoulder", "Wrist"), prefs.getAsJsonArray("issues_or_injuries").map { it.asString })
        assertEquals(4, prefs["frequency_days_per_week"].asInt)
        assertEquals(75, prefs["duration_minutes"].asInt)
        assertEquals(WorkoutSplit.UPPER_LOWER.title, prefs["split"].asString)
        assertEquals(WorkoutRpeScale.CR10.title, prefs["rpe_scale"].asString)
        val strength = prefs.getAsJsonObject("strength_kg")
        assertEquals(110.0, strength["bench_press"].asDouble, 0.0001)
        assertTrue(strength["deadlift"].isJsonNull)
    }

    @Test
    fun trainingSummaryCalculatesSetsRepsVolumeBestLoadBurnAndAverageRpe() {
        val first = session(
            dateKey = "2026-07-08",
            completedAt = "2026-07-08T10:00:00Z",
            durationSeconds = 60,
            caloriesBurned = 120,
            exercise = "Bench Press",
            sets = listOf(
                set(1, "100", "5", "8"),
                set(2, "200", "", "10")
            )
        )
        val second = session(
            dateKey = "2026-07-09",
            completedAt = "2026-07-09T10:00:00Z",
            durationSeconds = 61,
            caloriesBurned = 80,
            exercise = "Bench Press",
            sets = listOf(set(1, "220.46226218", "3", "9", WorkoutWeightUnit.LBS))
        )
        val outsideRange = session(
            dateKey = "2026-06-01",
            completedAt = "2026-06-01T10:00:00Z",
            caloriesBurned = 999,
            exercise = "Bench Press",
            sets = listOf(set(1, "300", "10", "10"))
        )
        val summary = json(
            tools(workoutSessions = listOf(outsideRange, first, second)).execute(
                "get_training_summary",
                mapOf("from" to "2026-07-08", "to" to "2026-07-09")
            )
        )

        assertEquals(2, summary["sessions"].asInt)
        assertEquals(2, summary["sets"].asInt)
        assertEquals(8, summary["reps"].asInt)
        assertEquals(200, summary["calories_burned"].asInt)
        assertEquals(3, summary["minutes"].asInt)
        val bench = summary.getAsJsonArray("by_exercise")[0].asJsonObject
        assertEquals(2, bench["sessions"].asInt)
        assertEquals(800.0, bench["external_load_volume_kg"].asDouble, 0.0001)
        assertEquals(100.0, bench["best_load_kg"].asDouble, 0.0001)
        assertEquals(8.5, bench["average_rpe"].asDouble, 0.0001)
        assertEquals(WorkoutRpeScale.STRENGTH.title, bench["rpe_scale"].asString)
    }

    @Test
    fun trainingSummaryKeepsDifferentRpeScalesSeparate() {
        val strength = session(
            dateKey = "2026-07-09",
            completedAt = "2026-07-09T09:00:00Z",
            exercise = "Back Squat",
            sets = listOf(set(1, "100", "5", "8", rpeScale = WorkoutRpeScale.STRENGTH))
        )
        val borg = session(
            dateKey = "2026-07-09",
            completedAt = "2026-07-09T10:00:00Z",
            exercise = "Back Squat",
            sets = listOf(set(1, "90", "8", "16", rpeScale = WorkoutRpeScale.BORG))
        )
        val summary = json(
            tools(workoutSessions = listOf(strength, borg)).execute(
                "get_training_summary",
                mapOf("from" to "2026-07-09", "to" to "2026-07-09")
            )
        )
        val squat = summary.getAsJsonArray("by_exercise")[0].asJsonObject
        val averages = squat.getAsJsonObject("average_rpe_by_scale")
        assertEquals(8.0, averages[WorkoutRpeScale.STRENGTH.title].asDouble, 0.0001)
        assertEquals(16.0, averages[WorkoutRpeScale.BORG.title].asDouble, 0.0001)
        assertFalse(squat.has("average_rpe"))
        assertNull(squat.get("rpe_scale"))
    }

    @Test
    fun exerciseLibrarySearchIsAWorkoutToolWithARequiredQuery() {
        assertTrue("search_exercise_library" in CoachTools.WORKOUT_TOOL_NAMES)
        assertTrue("search_exercise_library" in CoachTools.TOOL_NAMES)
        val schema = CoachTools.parameterSchemaFor("search_exercise_library")
        assertEquals(listOf("query"), schema["required"])
        @Suppress("UNCHECKED_CAST")
        val properties = schema["properties"] as Map<String, Any>
        assertEquals(setOf("query", "muscle", "equipment", "limit"), properties.keys)
        assertTrue(CoachTools.TOOL_DESCRIPTIONS.getValue("search_exercise_library").contains("Read-only"))
    }

    @Test
    fun exerciseLibrarySearchRanksNameMatchesAndFlagsCustomExercises() {
        val tools = libraryTools()
        val payload = json(tools.execute("search_exercise_library", mapOf("query" to "chest press")))
        val exercises = payload.getAsJsonArray("exercises").map { it.asJsonObject }

        // Leg Press only shares "press", so it is left out once other exercises match both words.
        assertEquals(
            listOf("Hammer Strength Chest Press", "Leverage Chest Press", "Machine Bench Press"),
            exercises.map { it["name"].asString }
        )
        assertEquals(3, payload["total_matches"].asInt)
        assertEquals("user_exercise_hammer", exercises[0]["catalog_id"].asString)
        assertTrue(exercises[0]["is_custom"].asBoolean)
        assertFalse(exercises[1]["is_custom"].asBoolean)
        assertEquals("Machine", exercises[1]["equipment"].asString)
        assertEquals(listOf("Chest"), exercises[1].getAsJsonArray("primary_muscles").map { it.asString })

        val chestOnly = json(
            tools.execute("search_exercise_library", mapOf("query" to "press", "muscle" to "chest", "limit" to 1))
        )
        assertEquals(1, chestOnly["count"].asInt)
        assertEquals(3, chestOnly["total_matches"].asInt)
        assertEquals("chest", chestOnly["muscle"].asString)
    }

    @Test
    fun exerciseLibrarySearchMatchesWordPrefixesAndFilters() {
        val library = searchLibrary()
        assertEquals("Leg Press", CoachTools.rankedLibraryMatches(library, "leg press").first().name)
        assertEquals(
            listOf("Seated Cable Rows"),
            CoachTools.rankedLibraryMatches(library, "rows", equipment = "cable").map { it.name }
        )
        // "row" must not match "Narrow"; "quads" still finds the quadriceps squat via its muscles.
        assertFalse(CoachTools.rankedLibraryMatches(library, "row").any { it.name == "Narrow Stance Squats" })
        assertEquals(
            listOf("Narrow Stance Squats"),
            CoachTools.rankedLibraryMatches(library, "squats", muscle = "quads").map { it.name }
        )
        assertTrue(CoachTools.rankedLibraryMatches(library, "zercher").isEmpty())

        val tools = libraryTools()
        assertEquals("query is required.", json(tools.execute("search_exercise_library"))["error"].asString)
        val empty = json(tools.execute("search_exercise_library", mapOf("query" to "zercher")))
        assertEquals(0, empty["count"].asInt)
        assertEquals(0, empty.getAsJsonArray("exercises").size())
    }

    @Test
    fun exerciseLibrarySearchKeepsOnlyFullMatchesWhenThereAreAny() {
        val library = listOf(
            libraryItem("Incline_Dumbbell_Press", "Incline Dumbbell Press", "Dumbbell", listOf("Chest")),
            libraryItem("Alternate_Incline_Dumbbell_Curl", "Alternate Incline Dumbbell Curl", "Dumbbell", listOf("Biceps"))
        )
        assertEquals(
            listOf("Incline Dumbbell Press"),
            CoachTools.rankedLibraryMatches(library, "incline press").map { it.name }
        )
        // No exercise matches every word, so the closest name matches are still offered.
        assertEquals(
            listOf("Incline Dumbbell Press", "Alternate Incline Dumbbell Curl"),
            CoachTools.rankedLibraryMatches(library, "hammer strength incline press").map { it.name }
        )
    }

    @Test
    fun exerciseLibrarySearchFiltersBeforeKeepingOnlyFullNameMatches() {
        val tools = CoachTools(
            weights = emptyList(),
            bodyFats = emptyList(),
            foods = emptyList(),
            exerciseLibrary = listOf(
                libraryItem("Incline_Barbell_Bench_Press", "Incline Barbell Bench Press", "Barbell", listOf("Chest")),
                libraryItem("Incline_Cable_Chest_Press", "Incline Cable Chest Press", "Cable", listOf("Chest"))
            )
        )
        // The barbell press matches every query word, but the cable filter must still find the
        // cable press instead of falling back to the unfiltered barbell result.
        val result = json(
            tools.execute("search_exercise_library", mapOf("query" to "incline bench press", "equipment" to "cable"))
        )
        assertEquals("Incline Cable Chest Press", result.getAsJsonArray("exercises")[0].asJsonObject["name"].asString)
        assertEquals(1, result["total_matches"].asInt)
        assertNull(result["filters_ignored"])
        assertEquals(1, result["excluded_by_filters"].asInt)
    }

    @Test
    fun exerciseLibrarySearchIgnoresOneAndTwoLetterWordsUnlessTheQueryIsThatShort() {
        val library = listOf(
            libraryItem("Barbell_Curl", "Barbell Curl", "Barbell", listOf("Biceps")),
            libraryItem("Ab_Roller", "Ab Roller", "Other", listOf("Abdominals")),
            libraryItem("EZ-Bar_Curl", "EZ-Bar Curl", "E-Z Curl Bar", listOf("Biceps"))
        )
        // "a" used to prefix-match "Ab" and pull the ab roller into a curl search.
        assertEquals(
            listOf("Barbell Curl", "EZ-Bar Curl"),
            CoachTools.rankedLibraryMatches(library, "a curl").map { it.name }
        )
        assertEquals("EZ-Bar Curl", CoachTools.rankedLibraryMatches(library, "ez bar curl").first().name)
        assertEquals(listOf("Ab Roller"), CoachTools.rankedLibraryMatches(library, "ab").map { it.name })
    }

    @Test
    fun exerciseLibrarySearchMapsCommonFilterNamesAndReportsWhatFiltersRemoved() {
        val library = searchLibrary()
        assertEquals(listOf("Leg Press"), CoachTools.rankedLibraryMatches(library, "press", muscle = "legs").map { it.name })
        // Cable stations are often called machines, so a "machine" filter keeps cable exercises.
        assertEquals(
            listOf("Seated Cable Rows"),
            CoachTools.rankedLibraryMatches(library, "rows", equipment = "machine").map { it.name }
        )

        val tools = libraryTools()
        val narrowed = json(tools.execute("search_exercise_library", mapOf("query" to "press", "muscle" to "pecs")))
        assertEquals(3, narrowed["total_matches"].asInt)
        assertEquals(1, narrowed["excluded_by_filters"].asInt)
        assertNull(narrowed["filters_ignored"])

        // A filter the library never uses must not hide every match and make Coach call it missing.
        val ignored = json(
            tools.execute("search_exercise_library", mapOf("query" to "leg press", "muscle" to "upper chest"))
        )
        assertEquals("Leg Press", ignored.getAsJsonArray("exercises")[0].asJsonObject["name"].asString)
        assertEquals(1, ignored["total_matches"].asInt)
        assertTrue(ignored["filters_ignored"].asBoolean)
        assertTrue(ignored["note"].asString.isNotEmpty())
        assertEquals("upper chest", ignored["muscle"].asString)
        assertNull(ignored["excluded_by_filters"])

        val none = json(tools.execute("search_exercise_library", mapOf("query" to "zercher", "muscle" to "abs")))
        assertEquals(0, none["count"].asInt)
        assertNull(none["filters_ignored"])
    }

    @Test
    fun exerciseLibrarySearchFiltersFindBundledCatalogExercisesByCommonNames() {
        val library = bundledCatalog()
        assertTrue(library.size > 800)
        fun names(query: String, muscle: String = "", equipment: String = "") =
            CoachTools.rankedLibraryMatches(library, query, muscle, equipment).map { it.name }
        // "abs" is not a prefix of "abdominals", so this filter used to drop all 93 ab exercises.
        assertEquals("Ab Crunch Machine", names("ab crunch machine", muscle = "abs").first())
        assertTrue("Ab Crunch Machine" in names("crunch", muscle = "core"))
        assertTrue("Donkey Calf Raises" in names("calf raise", muscle = "calf"))
        assertTrue(names("squat", muscle = "legs").isNotEmpty())
        assertTrue(names("fly", muscle = "pecs").isNotEmpty())
        assertTrue(names("raise", muscle = "delts").isNotEmpty())
        assertEquals("Smith Machine Squat", names("smith machine squat", equipment = "smith machine").first())
        assertEquals("Pushups", names("pushups", equipment = "bodyweight").first())
        assertEquals("Pushups", names("pushups", equipment = "body weight").first())
        assertTrue("EZ-Bar Curl" in names("curl", equipment = "ez bar"))
        assertEquals("Band Pull Apart", names("pull apart", equipment = "resistance band").first())
        assertTrue("Wide-Grip Lat Pulldown" in names("lat pulldown", equipment = "machine"))
    }

    @Test
    fun exerciseLibrarySearchSchemaListsEveryCatalogMuscleAndEquipmentName() {
        val library = bundledCatalog()
        val muscles = library.flatMap { it.primaryMuscles + it.secondaryMuscles }.map { it.lowercase() }.toSet()
        val equipment = library.map { it.equipment.lowercase() }.toSet() - "unspecified"
        assertEquals(muscles, CoachTools.LIBRARY_MUSCLE_NAMES.split(", ").toSet())
        assertEquals(equipment, CoachTools.LIBRARY_EQUIPMENT_NAMES.split(", ").toSet())

        @Suppress("UNCHECKED_CAST")
        val properties = CoachTools.parameterSchemaFor("search_exercise_library")["properties"] as Map<String, Map<String, Any>>
        assertTrue((properties.getValue("muscle")["description"] as String).endsWith(CoachTools.LIBRARY_MUSCLE_NAMES))
        assertTrue((properties.getValue("equipment")["description"] as String).endsWith(CoachTools.LIBRARY_EQUIPMENT_NAMES))
    }

    /** The catalog the app bundles (merged into Android assets from the iOS resources). */
    private fun bundledCatalog(): List<ExerciseItem> {
        val file = RepoFiles.find("../../ios/calorietracker/Resources/FreeExerciseDB/dist/exercises.json")
        val records: List<ExerciseRecord> = Gson().fromJson(file.readText(), object : TypeToken<List<ExerciseRecord>>() {}.type)
        return records.mapNotNull { ExerciseItem.from(it) }
    }

    private fun libraryTools() = CoachTools(
        weights = emptyList(),
        bodyFats = emptyList(),
        foods = emptyList(),
        exerciseLibrary = searchLibrary()
    )

    private fun searchLibrary(): List<ExerciseItem> = listOf(
        libraryItem("Leverage_Chest_Press", "Leverage Chest Press", "Machine", listOf("Chest"), listOf("Shoulders", "Triceps")),
        libraryItem("Machine_Bench_Press", "Machine Bench Press", "Machine", listOf("Chest"), listOf("Triceps")),
        libraryItem("Leg_Press", "Leg Press", "Machine", listOf("Quadriceps")),
        libraryItem("Seated_Cable_Rows", "Seated Cable Rows", "Cable", listOf("Middle Back")),
        libraryItem("Narrow_Stance_Squats", "Narrow Stance Squats", "Barbell", listOf("Quadriceps")),
        libraryItem("user_exercise_hammer", "Hammer Strength Chest Press", "Machine", listOf("Chest"))
    )

    private fun libraryItem(
        id: String,
        name: String,
        equipment: String,
        primaryMuscles: List<String>,
        secondaryMuscles: List<String> = emptyList()
    ) = ExerciseItem(
        id = id,
        name = name,
        level = "Beginner",
        imagePaths = emptyList(),
        force = "Push",
        mechanic = "Compound",
        category = "Strength",
        equipment = equipment,
        primaryMuscles = primaryMuscles,
        secondaryMuscles = secondaryMuscles,
        instructions = emptyList()
    )

    private fun tools(
        workoutSessions: List<WorkoutSession> = emptyList(),
        workoutPlans: List<WorkoutDayPlan> = emptyList(),
        workoutPreferences: WorkoutPreferences = WorkoutPreferences(),
        workoutPlanWeightUnit: WorkoutWeightUnit = WorkoutWeightUnit.LBS,
        clock: Clock = Clock.systemDefaultZone()
    ) = CoachTools(
        weights = emptyList(),
        bodyFats = emptyList(),
        foods = emptyList(),
        workoutSessions = workoutSessions,
        workoutPlans = workoutPlans,
        workoutPreferences = workoutPreferences,
        workoutPlanWeightUnit = workoutPlanWeightUnit,
        clock = clock
    )

    private fun session(
        dateKey: String,
        completedAt: String,
        durationSeconds: Int = 600,
        caloriesBurned: Int? = null,
        healthSyncVersion: Int? = null,
        exercise: String,
        sets: List<CompletedSet>
    ): WorkoutSession {
        val completed = Instant.parse(completedAt)
        return WorkoutSession(
            id = UUID.randomUUID(),
            diaryDateKey = dateKey,
            startedAt = completed.minusSeconds(durationSeconds.toLong()),
            completedAt = completed,
            durationSeconds = durationSeconds,
            exercises = listOf(
                CompletedExercise(
                    itemId = exercise.lowercase().replace(' ', '-'),
                    name = exercise,
                    targetMuscles = listOf("Chest"),
                    equipment = "Barbell",
                    sets = sets
                )
            ),
            caloriesBurned = caloriesBurned,
            healthSyncVersion = healthSyncVersion
        )
    }

    private fun set(
        number: Int,
        weight: String,
        reps: String,
        rpe: String,
        unit: WorkoutWeightUnit = WorkoutWeightUnit.KG,
        rpeScale: WorkoutRpeScale = WorkoutRpeScale.STRENGTH
    ) = CompletedSet(
        setNumber = number,
        weight = weight,
        weightUnit = unit,
        reps = reps,
        rpe = rpe,
        rpeScale = rpeScale
    )

    private fun plannedExercise(sets: List<PlannedSet>) = PlannedExercise(
        itemId = "incline-bench",
        name = "Incline Bench Press",
        level = "intermediate",
        imagePaths = emptyList(),
        force = "push",
        mechanic = "compound",
        category = "strength",
        equipment = "dumbbell",
        primaryMuscles = listOf("upper chest"),
        secondaryMuscles = listOf("triceps"),
        instructions = emptyList(),
        sets = sets
    )

    private fun json(value: String): JsonObject = JsonParser.parseString(value).asJsonObject
}
