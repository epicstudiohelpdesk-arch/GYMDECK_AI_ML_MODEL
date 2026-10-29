import Foundation
import Testing
@testable import calorietracker

@MainActor
struct CoachWorkoutToolsTests {
    @Test func savedCardioCountsAsPerformedAndKeepsDurationWithoutSetsOrReps() throws {
        let date = WorkoutTestFixture.date(2026, 7, 20)
        var cardio = StrengthPlannedExercise(item: WorkoutTestFixture.exercise(id: "Running_Treadmill", name: "Running, Treadmill"))
        cardio.category = "cardio"
        cardio.sets = []
        cardio.timer = StrengthExerciseTimer(accumulatedSeconds: 600.5, savedDurationSeconds: 600.5, intensity: .vigorous)
        let completed = StrengthCompletedExercise(
            itemID: cardio.itemID, name: cardio.name, targetMuscles: cardio.primaryMuscles,
            equipment: cardio.rawEquipment, sets: [], durationSeconds: 600.5, intensity: .vigorous
        )
        let session = StrengthWorkoutSession(
            diaryDate: date, startedAt: date, completedAt: date,
            durationSeconds: 0, exercises: [completed], caloriesBurned: 120
        )
        let tools = CoachTools(
            weights: [], bodyFats: [], foods: [], workoutSessions: [session],
            workoutPlans: [StrengthWorkoutDayPlan(dateKey: "2026-07-20", exercises: [cardio])],
            workoutAccessEnabled: true
        )
        let range: [String: Any] = ["from": "2026-07-20", "to": "2026-07-20"]
        let plans = try WorkoutCoachFixture.jsonObject(tools.execute(name: "get_workout_plans", arguments: range))
        let planPayloads = try #require(plans["plans"] as? [[String: Any]])
        let planned = try #require(planPayloads[0]["exercises"] as? [[String: Any]])
        #expect(planned[0]["performed"] as? Bool == true)
        #expect(planned[0]["duration_seconds"] as? Double == 600.5)
        let timer = try #require(planned[0]["timer"] as? [String: Any])
        #expect(timer["state"] as? String == "saved")
        let history = try WorkoutCoachFixture.jsonObject(tools.execute(name: "get_workout_history", arguments: range))
        let workouts = try #require(history["workouts"] as? [[String: Any]])
        let exercises = try #require(workouts[0]["exercises"] as? [[String: Any]])
        #expect(exercises[0]["performed"] as? Bool == true)
        #expect(exercises[0]["duration_seconds"] as? Double == 600.5)
        #expect(exercises[0]["intensity"] as? String == "Vigorous")
        let sets = try #require(exercises[0]["sets"] as? [[String: Any]])
        #expect(sets.isEmpty)
        let summary = try WorkoutCoachFixture.jsonObject(tools.execute(name: "get_training_summary", arguments: range))
        #expect(summary["sets"] as? Int == 0)
        #expect(summary["reps"] as? Int == 0)
        #expect(summary["timed_exercise_seconds"] as? Double == 600.5)
        let byExercise = try #require(summary["by_exercise"] as? [[String: Any]])
        #expect(byExercise[0]["duration_seconds"] as? Double == 600.5)
    }

    @Test func runningAndPausedPlanTimersRemainUnsaved() throws {
        let now = Date.now
        var running = StrengthPlannedExercise(item: WorkoutTestFixture.exercise(id: "run", name: "Running"))
        running.sets = []
        running.timer = StrengthExerciseTimer(accumulatedSeconds: 30, runningSince: now.addingTimeInterval(-90))
        var paused = running
        paused.timer = StrengthExerciseTimer(accumulatedSeconds: 45)
        let tools = CoachTools(
            weights: [], bodyFats: [], foods: [],
            workoutPlans: [StrengthWorkoutDayPlan(dateKey: "2026-07-20", exercises: [running, paused])],
            workoutAccessEnabled: true
        )
        let plans = try WorkoutCoachFixture.jsonObject(tools.execute(
            name: "get_workout_plans", arguments: ["from": "2026-07-20", "to": "2026-07-20"]
        ))
        let planPayloads = try #require(plans["plans"] as? [[String: Any]])
        let exercises = try #require(planPayloads[0]["exercises"] as? [[String: Any]])
        let runningTimer = try #require(exercises[0]["timer"] as? [String: Any])
        let pausedTimer = try #require(exercises[1]["timer"] as? [String: Any])
        #expect(runningTimer["state"] as? String == "running")
        #expect((runningTimer["elapsed_seconds"] as? Double ?? 0) >= 120)
        #expect(runningTimer["running_since"] as? String != nil)
        #expect(pausedTimer["state"] as? String == "paused")
        #expect(pausedTimer["elapsed_seconds"] as? Double == 45)
        for exercise in exercises {
            #expect(exercise["duration_seconds"] == nil)
            #expect(exercise["performed"] as? Bool == false)
        }
    }

    @Test func disabledWorkoutAccessDoesNotAdvertiseOrReturnWorkoutData() throws {
        let session = WorkoutCoachFixture.session(
            date: WorkoutTestFixture.date(2026, 7, 10),
            exercise: "Private Bench Session",
            sets: [WorkoutCoachFixture.set(number: 1, weight: "100", reps: "5", rpe: "8")]
        )
        let tools = CoachTools(
            weights: [],
            bodyFats: [],
            foods: [],
            workoutSessions: [session],
            workoutPlans: [],
            workoutPreferences: StrengthWorkoutPreferences(),
            workoutAccessEnabled: false
        )

        #expect(tools.availableToolNames == CoachTools.nutritionToolNames)
        #expect(!tools.availableToolNames.contains("get_workout_history"))

        let summary = try WorkoutCoachFixture.jsonObject(tools.execute(name: "get_data_summary", arguments: [:]))
        #expect(summary["workouts"] == nil)
        #expect(summary["workout_plans"] == nil)

        let blocked = try WorkoutCoachFixture.jsonObject(
            tools.execute(
                name: "get_workout_history",
                arguments: ["from": "2026-07-01", "to": "2026-07-31"]
            )
        )
        let error = try #require(blocked["error"] as? String)
        #expect(error == "Workout access is disabled.")
        #expect(!tools.execute(name: "get_workout_history", arguments: [:]).contains("Private Bench Session"))
    }

    @Test func enabledSummaryAndHistoryExposeOnlyRequestedWorkoutRange() throws {
        let firstDate = WorkoutTestFixture.date(2026, 7, 4)
        let secondDate = WorkoutTestFixture.date(2026, 7, 18)
        let first = WorkoutCoachFixture.session(
            date: firstDate,
            exercise: "Bench Press",
            sets: [WorkoutCoachFixture.set(number: 1, weight: "100", reps: "5", rpe: "8")]
        )
        let second = WorkoutCoachFixture.session(
            date: secondDate,
            caloriesBurned: 345,
            exercise: "Back Squat",
            sets: [WorkoutCoachFixture.set(number: 1, weight: "120", reps: "3", rpe: "9")]
        )
        let plan = StrengthWorkoutDayPlan(
            dateKey: "2026-07-20",
            exercises: [StrengthPlannedExercise(item: WorkoutTestFixture.exercise(id: "row", name: "Barbell Row"))]
        )
        let tools = CoachTools(
            weights: [],
            bodyFats: [],
            foods: [],
            workoutSessions: [second, first],
            workoutPlans: [plan],
            workoutAccessEnabled: true
        )

        #expect(Set(CoachTools.workoutToolNames).isSubset(of: Set(tools.availableToolNames)))
        let summary = try WorkoutCoachFixture.jsonObject(tools.execute(name: "get_data_summary", arguments: [:]))
        let workoutSummary = try #require(summary["workouts"] as? [String: Any])
        let planSummary = try #require(summary["workout_plans"] as? [String: Any])
        #expect(workoutSummary["count"] as? Int == 2)
        #expect(workoutSummary["first_date"] as? String == "2026-07-04")
        #expect(workoutSummary["last_date"] as? String == "2026-07-18")
        #expect(planSummary["count"] as? Int == 1)

        let history = try WorkoutCoachFixture.jsonObject(
            tools.execute(
                name: "get_workout_history",
                arguments: ["from": "2026-07-18", "to": "2026-07-18"]
            )
        )
        let workouts = try #require(history["workouts"] as? [[String: Any]])
        #expect(history["count"] as? Int == 1)
        #expect(workouts.count == 1)
        #expect(workouts[0]["date"] as? String == "2026-07-18")
        #expect(workouts[0]["calories_burned"] as? Int == 345)
        let exercises = try #require(workouts[0]["exercises"] as? [[String: Any]])
        #expect(exercises[0]["name"] as? String == "Back Squat")
        let sets = try #require(exercises[0]["sets"] as? [[String: Any]])
        #expect(sets[0]["performed"] as? Bool == true)
        #expect(sets[0]["weight"] as? Double == 120)
        #expect(sets[0]["weight_kg"] as? Double == 120)
        #expect(sets[0]["reps"] as? Int == 3)
        #expect(sets[0]["rpe"] as? Double == 9)
    }

    @Test func planAndPreferencePayloadsPreserveWorkoutConfiguration() throws {
        let item = WorkoutTestFixture.exercise(
            id: "incline-bench",
            name: "Incline Bench Press",
            equipment: "dumbbell",
            muscles: ["upper chest"]
        )
        var plannedExercise = StrengthPlannedExercise(item: item)
        plannedExercise.sets = [
            StrengthPlannedSet(
                weight: "32.5",
                weightUnit: WeightUnit.kg.rawValue,
                reps: "10",
                rpe: "8.5",
                rpeScale: .cr10
            ),
            StrengthPlannedSet(),
        ]
        let plan = StrengthWorkoutDayPlan(dateKey: "2026-07-20", exercises: [plannedExercise])
        var preferences = StrengthWorkoutPreferences()
        preferences.targetMuscles = ["Chest", "Shoulders"]
        preferences.issues = [.shoulder, .wrist]
        preferences.additionalIssues = "No overhead lockout"
        preferences.frequencyDays = 4
        preferences.duration = .seventyFive
        preferences.split = .upperLower
        preferences.equipment = ["Bench", "Dumbbells"]
        preferences.rpeScale = .cr10
        preferences.strength = StrengthWorkoutNumbers(
            benchPressKg: 110,
            squatKg: 150,
            deadliftKg: nil,
            overheadPressKg: 65
        )
        let tools = CoachTools(
            weights: [],
            bodyFats: [],
            foods: [],
            workoutPlans: [StrengthWorkoutDayPlan(dateKey: "2026-07-19"), plan],
            workoutPreferences: preferences,
            workoutAccessEnabled: true
        )

        let plans = try WorkoutCoachFixture.jsonObject(
            tools.execute(
                name: "get_workout_plans",
                arguments: ["from": "2026-07-20", "to": "2026-07-20"]
            )
        )
        let planPayloads = try #require(plans["plans"] as? [[String: Any]])
        #expect(plans["count"] as? Int == 1)
        #expect(planPayloads[0]["date"] as? String == "2026-07-20")
        let exercises = try #require(planPayloads[0]["exercises"] as? [[String: Any]])
        #expect(exercises[0]["catalog_id"] as? String == item.id)
        #expect(exercises[0]["name"] as? String == item.name)
        #expect(exercises[0]["target_muscles"] as? [String] == item.primaryMuscles)
        let sets = try #require(exercises[0]["sets"] as? [[String: Any]])
        #expect(sets.count == 2)
        #expect(sets[0]["weight"] as? String == "32.5")
        #expect(sets[0]["weight_unit"] as? String == WeightUnit.kg.rawValue)
        #expect(sets[0]["reps"] as? Int == 10)
        #expect(sets[0]["rpe"] as? Double == 8.5)
        #expect(sets[0]["rpe_scale"] as? String == StrengthWorkoutRPEScale.cr10.title)
        #expect(sets[1]["weight"] == nil)

        let preferencesPayload = try WorkoutCoachFixture.jsonObject(
            tools.execute(name: "get_workout_preferences", arguments: [:])
        )
        #expect(preferencesPayload["configured"] as? Bool == true)
        #expect(preferencesPayload["target_muscles"] as? [String] == ["Chest", "Shoulders"])
        #expect(preferencesPayload["issues_or_injuries"] as? [String] == ["Shoulder", "Wrist"])
        #expect(preferencesPayload["frequency_days_per_week"] as? Int == 4)
        #expect(preferencesPayload["duration_minutes"] as? Int == 75)
        #expect(preferencesPayload["split"] as? String == StrengthWorkoutSplit.upperLower.title)
        #expect(preferencesPayload["rpe_scale"] as? String == StrengthWorkoutRPEScale.cr10.title)
        let strength = try #require(preferencesPayload["strength_kg"] as? [String: Any])
        #expect(strength["bench_press"] as? Double == 110)
        #expect(strength["squat"] as? Double == 150)
        #expect(strength["deadlift"] is NSNull)
        #expect(strength["overhead_press"] as? Double == 65)
    }

    @Test func trainingSummaryCalculatesPerformedSetsRepsVolumeBestLoadAndAverageRPE() throws {
        let first = WorkoutCoachFixture.session(
            date: WorkoutTestFixture.date(2026, 7, 8),
            durationSeconds: 60,
            caloriesBurned: 120,
            exercise: "Bench Press",
            sets: [
                WorkoutCoachFixture.set(number: 1, weight: "100", unit: .kg, reps: "5", rpe: "8"),
                WorkoutCoachFixture.set(number: 2, weight: "200", unit: .kg, reps: "", rpe: "10"),
            ]
        )
        let second = WorkoutCoachFixture.session(
            date: WorkoutTestFixture.date(2026, 7, 9),
            durationSeconds: 61,
            caloriesBurned: 80,
            exercise: "Bench Press",
            sets: [WorkoutCoachFixture.set(number: 1, weight: "220.462", unit: .lbs, reps: "3", rpe: "9")]
        )
        let outsideRange = WorkoutCoachFixture.session(
            date: WorkoutTestFixture.date(2026, 6, 1),
            durationSeconds: 900,
            exercise: "Bench Press",
            sets: [WorkoutCoachFixture.set(number: 1, weight: "300", unit: .kg, reps: "10", rpe: "10")]
        )
        let tools = CoachTools(
            weights: [],
            bodyFats: [],
            foods: [],
            workoutSessions: [outsideRange, first, second],
            workoutAccessEnabled: true
        )

        let summary = try WorkoutCoachFixture.jsonObject(
            tools.execute(
                name: "get_training_summary",
                arguments: ["from": "2026-07-08", "to": "2026-07-09"]
            )
        )
        #expect(summary["sessions"] as? Int == 2)
        #expect(summary["sets"] as? Int == 2)
        #expect(summary["reps"] as? Int == 8)
        #expect(summary["calories_burned"] as? Int == 200)
        #expect(summary["minutes"] as? Int == 3)

        let exercises = try #require(summary["by_exercise"] as? [[String: Any]])
        #expect(exercises.count == 1)
        let bench = exercises[0]
        #expect(bench["name"] as? String == "Bench Press")
        #expect(bench["sessions"] as? Int == 2)
        #expect(bench["sets"] as? Int == 2)
        #expect(bench["reps"] as? Int == 8)
        #expect(bench["external_load_volume_kg"] as? Double == 800)
        #expect(bench["best_load_kg"] as? Double == 100)
        #expect(bench["average_rpe"] as? Double == 8.5)
        #expect(bench["rpe_scale"] as? String == StrengthWorkoutRPEScale.strength.title)
    }

    @Test func trainingSummaryKeepsDifferentRPEScalesSeparate() throws {
        let date = WorkoutTestFixture.date(2026, 7, 9)
        let strength = WorkoutCoachFixture.session(
            date: date,
            exercise: "Back Squat",
            sets: [WorkoutCoachFixture.set(number: 1, weight: "100", reps: "5", rpe: "8", rpeScale: .strength)]
        )
        let borg = WorkoutCoachFixture.session(
            date: date,
            exercise: "Back Squat",
            sets: [WorkoutCoachFixture.set(number: 1, weight: "90", reps: "8", rpe: "16", rpeScale: .borg)]
        )
        let tools = CoachTools(
            weights: [],
            bodyFats: [],
            foods: [],
            workoutSessions: [strength, borg],
            workoutAccessEnabled: true
        )

        let summary = try WorkoutCoachFixture.jsonObject(
            tools.execute(
                name: "get_training_summary",
                arguments: ["from": "2026-07-09", "to": "2026-07-09"]
            )
        )
        let exercises = try #require(summary["by_exercise"] as? [[String: Any]])
        let squat = try #require(exercises.first)
        let averages = try #require(squat["average_rpe_by_scale"] as? [String: Any])
        #expect(averages[StrengthWorkoutRPEScale.strength.title] as? Double == 8)
        #expect(averages[StrengthWorkoutRPEScale.borg.title] as? Double == 16)
        #expect(squat["average_rpe"] == nil)
    }

    @Test func calculatedDailyBurnSupersedesTimerEraSnapshotForCoach() throws {
        let date = WorkoutTestFixture.date(2026, 7, 12)
        let legacy = WorkoutCoachFixture.session(
            date: date,
            exercise: "Bench Press",
            sets: [WorkoutCoachFixture.set(number: 1, weight: "80", reps: "5", rpe: "7")]
        )
        let calculated = WorkoutCoachFixture.session(
            date: date.addingTimeInterval(60),
            caloriesBurned: 210,
            exercise: "Bench Press",
            sets: [WorkoutCoachFixture.set(number: 1, weight: "85", reps: "8", rpe: "8")]
        )
        let tools = CoachTools(
            weights: [],
            bodyFats: [],
            foods: [],
            workoutSessions: [legacy, calculated],
            workoutAccessEnabled: true
        )

        let summary = try WorkoutCoachFixture.jsonObject(
            tools.execute(
                name: "get_training_summary",
                arguments: ["from": "2026-07-12", "to": "2026-07-12"]
            )
        )
        #expect(summary["sessions"] as? Int == 1)
        #expect(summary["sets"] as? Int == 1)
        #expect(summary["reps"] as? Int == 8)
        #expect(summary["calories_burned"] as? Int == 210)
    }

    @Test func workoutToolSchemasRequireDatesOnlyForRangeQueries() throws {
        let noArgumentSchemaNames = ["get_data_summary", "get_workout_plans", "get_workout_preferences"]
        for name in noArgumentSchemaNames {
            let schema = CoachTools.parameterSchema(for: name)
            #expect(schema["required"] == nil)
        }

        let planProperties = try #require(
            CoachTools.parameterSchema(for: "get_workout_plans")["properties"] as? [String: Any]
        )
        #expect(planProperties["from"] != nil)
        #expect(planProperties["to"] != nil)

        for name in ["get_workout_history", "get_training_summary"] {
            let schema = CoachTools.parameterSchema(for: name)
            #expect(schema["required"] as? [String] == ["from", "to"])
        }

        let liftSchema = CoachTools.parameterSchema(for: "get_exercise_lift_history")
        #expect(liftSchema["required"] as? [String] == ["exercise"])
    }

    @Test func exerciseLiftHistoryReturnsRecentSetsForOneLift() throws {
        let bench = WorkoutTestFixture.exercise(id: "bench", name: "Bench Press")
        let yesterday = WorkoutTestFixture.date(2026, 7, 19)
        let today = WorkoutTestFixture.date(2026, 7, 20)
        let store = WorkoutTestFixture().makeStore()
        store.toggleExercise(bench, on: yesterday)
        var planned = try #require(store.exercises(for: yesterday).first)
        var firstSet = try #require(planned.sets.first)
        store.updateSet(
            exerciseID: planned.id,
            setID: firstSet.id,
            on: yesterday,
            weight: "60",
            weightUnit: .kg,
            reps: "8"
        )
        _ = store.upsertCalculatedWorkout(on: yesterday, caloriesBurned: 180, weightUnit: .kg)
        store.toggleExercise(bench, on: today)

        let tools = CoachTools(
            weights: [],
            bodyFats: [],
            foods: [],
            workoutSessions: store.completedSessions,
            workoutPlans: Array(store.dayPlans.values),
            workoutPreferences: store.preferences,
            workoutPlanWeightUnit: .kg,
            workoutAccessEnabled: true
        )
        let payload = try WorkoutCoachFixture.jsonObject(
            tools.execute(
                name: "get_exercise_lift_history",
                arguments: ["exercise": "Bench Press", "to": "2026-07-20"]
            )
        )
        let sessions = try #require(payload["sessions"] as? [[String: Any]])
        #expect(payload["count"] as? Int == 1)
        #expect(sessions.first?["date"] as? String == "2026-07-19")
        let sets = try #require(sessions.first?["sets"] as? [[String: Any]])
        #expect(sets.first?["weight"] as? String == "60")
        #expect(sets.first?["reps"] as? Int == 8)
        let last = try #require(payload["last_session"] as? [String: Any])
        #expect(last["date"] as? String == "2026-07-19")
    }

    @Test func exerciseLiftHistoryRespectsCatalogIdOverSameName() throws {
        let catalogBench = WorkoutCoachFixture.session(
            date: WorkoutTestFixture.date(2026, 7, 19),
            caloriesBurned: 180,
            exercise: "Bench Press",
            sets: [WorkoutCoachFixture.set(number: 1, weight: "60", reps: "8", rpe: "7")]
        )
        let customBench = StrengthWorkoutSession(
            diaryDate: WorkoutTestFixture.date(2026, 7, 18),
            startedAt: WorkoutTestFixture.date(2026, 7, 18),
            completedAt: WorkoutTestFixture.date(2026, 7, 18),
            durationSeconds: 600,
            exercises: [
                StrengthCompletedExercise(
                    itemID: "custom-bench",
                    name: "Bench Press",
                    targetMuscles: ["Chest"],
                    equipment: "Barbell",
                    sets: [WorkoutCoachFixture.set(number: 1, weight: "100", reps: "5", rpe: "8")]
                )
            ],
            caloriesBurned: 170
        )
        let tools = CoachTools(
            weights: [],
            bodyFats: [],
            foods: [],
            workoutSessions: [catalogBench, customBench],
            workoutPlans: [],
            workoutPlanWeightUnit: .kg,
            workoutAccessEnabled: true
        )
        let payload = try WorkoutCoachFixture.jsonObject(
            tools.execute(
                name: "get_exercise_lift_history",
                arguments: [
                    "exercise": "Bench Press",
                    "catalog_id": "bench-press",
                    "to": "2026-07-20",
                ]
            )
        )
        let sessions = try #require(payload["sessions"] as? [[String: Any]])
        #expect(payload["count"] as? Int == 1)
        let sets = try #require(sessions.first?["sets"] as? [[String: Any]])
        #expect(sets.first?["weight"] as? String == "60")
    }

    @Test func exerciseLiftHistoryUsesAuthoritativeSameDaySnapshot() throws {
        let legacy = WorkoutCoachFixture.session(
            date: WorkoutTestFixture.date(2026, 7, 12),
            exercise: "Bench Press",
            sets: [WorkoutCoachFixture.set(number: 1, weight: "80", reps: "5", rpe: "7")]
        )
        var newerClockButOlderVersion = WorkoutCoachFixture.session(
            date: WorkoutTestFixture.date(2026, 7, 12),
            caloriesBurned: 190,
            exercise: "Bench Press",
            sets: [WorkoutCoachFixture.set(number: 1, weight: "82.5", reps: "6", rpe: "7.5")]
        )
        newerClockButOlderVersion = StrengthWorkoutSession(
            id: newerClockButOlderVersion.id,
            diaryDate: newerClockButOlderVersion.diaryDate,
            diaryDateKey: newerClockButOlderVersion.diaryDateKey,
            startedAt: newerClockButOlderVersion.startedAt,
            completedAt: WorkoutTestFixture.date(2026, 7, 12).addingTimeInterval(11 * 3600),
            durationSeconds: newerClockButOlderVersion.durationSeconds,
            exercises: newerClockButOlderVersion.exercises,
            caloriesBurned: 190,
            healthSyncVersion: 1
        )
        var authoritative = WorkoutCoachFixture.session(
            date: WorkoutTestFixture.date(2026, 7, 12),
            caloriesBurned: 210,
            exercise: "Bench Press",
            sets: [WorkoutCoachFixture.set(number: 1, weight: "85", reps: "8", rpe: "8")]
        )
        authoritative = StrengthWorkoutSession(
            id: authoritative.id,
            diaryDate: authoritative.diaryDate,
            diaryDateKey: authoritative.diaryDateKey,
            startedAt: authoritative.startedAt,
            completedAt: WorkoutTestFixture.date(2026, 7, 12).addingTimeInterval(10 * 3600),
            durationSeconds: authoritative.durationSeconds,
            exercises: authoritative.exercises,
            caloriesBurned: 210,
            healthSyncVersion: 2
        )
        let tools = CoachTools(
            weights: [],
            bodyFats: [],
            foods: [],
            workoutSessions: [legacy, newerClockButOlderVersion, authoritative],
            workoutPlans: [],
            workoutAccessEnabled: true
        )
        let payload = try WorkoutCoachFixture.jsonObject(
            tools.execute(
                name: "get_exercise_lift_history",
                arguments: ["exercise": "Bench Press", "to": "2026-07-20"]
            )
        )
        let sessions = try #require(payload["sessions"] as? [[String: Any]])
        let sets = try #require(sessions.first?["sets"] as? [[String: Any]])
        #expect(sets.first?["weight"] as? String == "85")
        #expect(sets.first?["reps"] as? Int == 8)
    }

    @Test func exerciseLibrarySearchIsReadOnlyAndGatedByWorkoutAccess() throws {
        let off = CoachTools(weights: [], bodyFats: [], foods: [], workoutAccessEnabled: false, exerciseLibrary: ExerciseSearchFixture.library)
        #expect(!off.availableToolNames.contains("search_exercise_library"))
        let blocked = try WorkoutCoachFixture.jsonObject(off.execute(name: "search_exercise_library", arguments: ["query": "chest press"]))
        #expect(blocked["error"] as? String == "Workout access is disabled.")

        let on = CoachTools(weights: [], bodyFats: [], foods: [], workoutAccessEnabled: true, exerciseLibrary: ExerciseSearchFixture.library)
        #expect(on.availableToolNames.contains("search_exercise_library"))
        let schema = CoachTools.parameterSchema(for: "search_exercise_library")
        #expect(schema["required"] as? [String] == ["query"])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(Set(properties.keys) == ["query", "muscle", "equipment", "limit"])
        #expect(CoachTools.toolDescriptions["search_exercise_library"]?.contains("Read-only") == true)
    }

    @Test func exerciseLibrarySearchRanksNameMatchesAndFlagsCustomExercises() throws {
        let tools = CoachTools(weights: [], bodyFats: [], foods: [], workoutAccessEnabled: true, exerciseLibrary: ExerciseSearchFixture.library)
        let payload = try WorkoutCoachFixture.jsonObject(
            tools.execute(name: "search_exercise_library", arguments: ["query": "chest press"])
        )
        let exercises = try #require(payload["exercises"] as? [[String: Any]])

        // Leg Press only shares "press", so it is left out once other exercises match both words.
        #expect(exercises.map { $0["name"] as? String } == [
            "Hammer Strength Chest Press", "Leverage Chest Press", "Machine Bench Press",
        ])
        #expect(payload["total_matches"] as? Int == 3)
        #expect(exercises[0]["catalog_id"] as? String == "user_exercise_hammer")
        #expect(exercises[0]["is_custom"] as? Bool == true)
        #expect(exercises[1]["is_custom"] as? Bool == false)
        #expect(exercises[1]["equipment"] as? String == "Machine")
        #expect(exercises[1]["primary_muscles"] as? [String] == ["Chest"])

        let chestOnly = try WorkoutCoachFixture.jsonObject(
            tools.execute(name: "search_exercise_library", arguments: ["query": "press", "muscle": "chest", "limit": 1])
        )
        #expect(chestOnly["count"] as? Int == 1)
        #expect(chestOnly["total_matches"] as? Int == 3)
        #expect(chestOnly["muscle"] as? String == "chest")
    }

    @Test func exerciseLibrarySearchMatchesWordPrefixesAndFilters() throws {
        let library = ExerciseSearchFixture.library
        #expect(CoachTools.rankedLibraryMatches(library, query: "leg press").first?.name == "Leg Press")
        #expect(CoachTools.rankedLibraryMatches(library, query: "rows", equipment: "cable").map(\.name) == ["Seated Cable Rows"])
        // "row" must not match "Narrow"; "quads" still finds the quadriceps squat via its muscles.
        #expect(!CoachTools.rankedLibraryMatches(library, query: "row").map(\.name).contains("Narrow Stance Squats"))
        #expect(CoachTools.rankedLibraryMatches(library, query: "squats", muscle: "quads").map(\.name) == ["Narrow Stance Squats"])
        #expect(CoachTools.rankedLibraryMatches(library, query: "zercher").isEmpty)

        let tools = CoachTools(weights: [], bodyFats: [], foods: [], workoutAccessEnabled: true, exerciseLibrary: library)
        let missing = try WorkoutCoachFixture.jsonObject(tools.execute(name: "search_exercise_library", arguments: [:]))
        #expect(missing["error"] as? String == "query is required.")
        let empty = try WorkoutCoachFixture.jsonObject(
            tools.execute(name: "search_exercise_library", arguments: ["query": "zercher"])
        )
        #expect(empty["count"] as? Int == 0)
        #expect((empty["exercises"] as? [Any])?.isEmpty == true)
    }

    @Test func exerciseLibrarySearchKeepsOnlyFullMatchesWhenThereAreAny() {
        let library = [
            ExerciseLibraryItem(id: "Incline_Dumbbell_Press", name: "Incline Dumbbell Press", category: "strength", rawEquipment: "dumbbell", primaryMuscles: ["chest"]),
            ExerciseLibraryItem(id: "Alternate_Incline_Dumbbell_Curl", name: "Alternate Incline Dumbbell Curl", category: "strength", rawEquipment: "dumbbell", primaryMuscles: ["biceps"]),
        ]
        #expect(CoachTools.rankedLibraryMatches(library, query: "incline press").map(\.name) == ["Incline Dumbbell Press"])
        // No exercise matches every word, so the closest name matches are still offered.
        #expect(CoachTools.rankedLibraryMatches(library, query: "hammer strength incline press").map(\.name) == [
            "Incline Dumbbell Press", "Alternate Incline Dumbbell Curl",
        ])
    }

    @Test func exerciseLibrarySearchFiltersBeforeKeepingOnlyFullNameMatches() throws {
        let library = [
            ExerciseLibraryItem(id: "Incline_Barbell_Bench_Press", name: "Incline Barbell Bench Press", category: "strength", rawEquipment: "barbell", primaryMuscles: ["chest"]),
            ExerciseLibraryItem(id: "Incline_Cable_Chest_Press", name: "Incline Cable Chest Press", category: "strength", rawEquipment: "cable", primaryMuscles: ["chest"]),
        ]
        let tools = CoachTools(weights: [], bodyFats: [], foods: [], workoutAccessEnabled: true, exerciseLibrary: library)
        // The barbell press matches every query word, but the cable filter must still find the
        // cable press instead of falling back to the unfiltered barbell result.
        let result = try WorkoutCoachFixture.jsonObject(
            tools.execute(name: "search_exercise_library", arguments: ["query": "incline bench press", "equipment": "cable"])
        )
        let exercises = try #require(result["exercises"] as? [[String: Any]])
        #expect(exercises.first?["name"] as? String == "Incline Cable Chest Press")
        #expect(result["total_matches"] as? Int == 1)
        #expect(result["filters_ignored"] == nil)
        #expect(result["excluded_by_filters"] as? Int == 1)
    }

    @Test func exerciseLibrarySearchIgnoresOneAndTwoLetterWordsUnlessTheQueryIsThatShort() {
        let library = [
            ExerciseLibraryItem(id: "Barbell_Curl", name: "Barbell Curl", category: "strength", rawEquipment: "barbell", primaryMuscles: ["biceps"]),
            ExerciseLibraryItem(id: "Ab_Roller", name: "Ab Roller", category: "strength", rawEquipment: "other", primaryMuscles: ["abdominals"]),
            ExerciseLibraryItem(id: "EZ-Bar_Curl", name: "EZ-Bar Curl", category: "strength", rawEquipment: "e-z curl bar", primaryMuscles: ["biceps"]),
        ]
        // "a" used to prefix-match "Ab" and pull the ab roller into a curl search.
        #expect(CoachTools.rankedLibraryMatches(library, query: "a curl").map(\.name) == ["Barbell Curl", "EZ-Bar Curl"])
        #expect(CoachTools.rankedLibraryMatches(library, query: "ez bar curl").first?.name == "EZ-Bar Curl")
        #expect(CoachTools.rankedLibraryMatches(library, query: "ab").map(\.name) == ["Ab Roller"])
    }

    @Test func exerciseLibrarySearchMapsCommonFilterNamesAndReportsWhatFiltersRemoved() throws {
        let library = ExerciseSearchFixture.library
        #expect(CoachTools.rankedLibraryMatches(library, query: "press", muscle: "legs").map(\.name) == ["Leg Press"])
        // Cable stations are often called machines, so a "machine" filter keeps cable exercises.
        #expect(CoachTools.rankedLibraryMatches(library, query: "rows", equipment: "machine").map(\.name) == ["Seated Cable Rows"])

        let tools = CoachTools(weights: [], bodyFats: [], foods: [], workoutAccessEnabled: true, exerciseLibrary: library)
        let narrowed = try WorkoutCoachFixture.jsonObject(
            tools.execute(name: "search_exercise_library", arguments: ["query": "press", "muscle": "pecs"])
        )
        #expect(narrowed["total_matches"] as? Int == 3)
        #expect(narrowed["excluded_by_filters"] as? Int == 1)
        #expect(narrowed["filters_ignored"] == nil)

        // A filter the library never uses must not hide every match and make Coach call it missing.
        let ignored = try WorkoutCoachFixture.jsonObject(
            tools.execute(name: "search_exercise_library", arguments: ["query": "leg press", "muscle": "upper chest"])
        )
        let exercises = try #require(ignored["exercises"] as? [[String: Any]])
        #expect(exercises.first?["name"] as? String == "Leg Press")
        #expect(ignored["total_matches"] as? Int == 1)
        #expect(ignored["filters_ignored"] as? Bool == true)
        #expect((ignored["note"] as? String)?.isEmpty == false)
        #expect(ignored["muscle"] as? String == "upper chest")
        #expect(ignored["excluded_by_filters"] == nil)

        let none = try WorkoutCoachFixture.jsonObject(
            tools.execute(name: "search_exercise_library", arguments: ["query": "zercher", "muscle": "abs"])
        )
        #expect(none["count"] as? Int == 0)
        #expect(none["filters_ignored"] == nil)
    }

    @Test func exerciseLibrarySearchFiltersFindBundledCatalogExercisesByCommonNames() throws {
        let library = FreeExerciseDBLoader.load()
        try #require(library.count > 800)
        // "abs" is not a prefix of "abdominals", so this filter used to drop all 93 ab exercises.
        #expect(CoachTools.rankedLibraryMatches(library, query: "ab crunch machine", muscle: "abs").first?.name == "Ab Crunch Machine")
        #expect(CoachTools.rankedLibraryMatches(library, query: "crunch", muscle: "core").map(\.name).contains("Ab Crunch Machine"))
        #expect(CoachTools.rankedLibraryMatches(library, query: "calf raise", muscle: "calf").map(\.name).contains("Donkey Calf Raises"))
        #expect(!CoachTools.rankedLibraryMatches(library, query: "squat", muscle: "legs").isEmpty)
        #expect(!CoachTools.rankedLibraryMatches(library, query: "fly", muscle: "pecs").isEmpty)
        #expect(!CoachTools.rankedLibraryMatches(library, query: "raise", muscle: "delts").isEmpty)
        #expect(CoachTools.rankedLibraryMatches(library, query: "smith machine squat", equipment: "smith machine").first?.name == "Smith Machine Squat")
        #expect(CoachTools.rankedLibraryMatches(library, query: "pushups", equipment: "bodyweight").first?.name == "Pushups")
        #expect(CoachTools.rankedLibraryMatches(library, query: "pushups", equipment: "body weight").first?.name == "Pushups")
        #expect(CoachTools.rankedLibraryMatches(library, query: "curl", equipment: "ez bar").map(\.name).contains("EZ-Bar Curl"))
        #expect(CoachTools.rankedLibraryMatches(library, query: "pull apart", equipment: "resistance band").first?.name == "Band Pull Apart")
        #expect(CoachTools.rankedLibraryMatches(library, query: "lat pulldown", equipment: "machine").map(\.name).contains("Wide-Grip Lat Pulldown"))
    }

    @Test func exerciseLibrarySearchSchemaListsEveryCatalogMuscleAndEquipmentName() throws {
        let library = FreeExerciseDBLoader.load()
        try #require(!library.isEmpty)
        let muscles = Set(library.flatMap { $0.primaryMuscles + $0.secondaryMuscles }.map { $0.lowercased() })
        let equipment = Set(library.map { $0.rawEquipment.lowercased() }).subtracting(["unspecified"])
        #expect(Set(CoachTools.libraryMuscleNames.components(separatedBy: ", ")) == muscles)
        #expect(Set(CoachTools.libraryEquipmentNames.components(separatedBy: ", ")) == equipment)

        let properties = try #require(
            CoachTools.parameterSchema(for: "search_exercise_library")["properties"] as? [String: [String: Any]]
        )
        #expect((properties["muscle"]?["description"] as? String)?.hasSuffix(CoachTools.libraryMuscleNames) == true)
        #expect((properties["equipment"]?["description"] as? String)?.hasSuffix(CoachTools.libraryEquipmentNames) == true)
    }
}

@MainActor
private enum ExerciseSearchFixture {
    static let library: [ExerciseLibraryItem] = [
        ExerciseLibraryItem(id: "Leverage_Chest_Press", name: "Leverage Chest Press", category: "strength", rawEquipment: "machine", primaryMuscles: ["chest"], secondaryMuscles: ["shoulders", "triceps"]),
        ExerciseLibraryItem(id: "Machine_Bench_Press", name: "Machine Bench Press", category: "strength", rawEquipment: "machine", primaryMuscles: ["chest"], secondaryMuscles: ["triceps"]),
        ExerciseLibraryItem(id: "Leg_Press", name: "Leg Press", category: "strength", rawEquipment: "machine", primaryMuscles: ["quadriceps"]),
        ExerciseLibraryItem(id: "Seated_Cable_Rows", name: "Seated Cable Rows", category: "strength", rawEquipment: "cable", primaryMuscles: ["middle back"]),
        ExerciseLibraryItem(id: "Narrow_Stance_Squats", name: "Narrow Stance Squats", category: "strength", rawEquipment: "barbell", primaryMuscles: ["quadriceps"]),
        ExerciseLibraryItem(id: "user_exercise_hammer", name: "Hammer Strength Chest Press", category: "strength", rawEquipment: "machine", primaryMuscles: ["chest"]),
    ]
}

@MainActor
private enum WorkoutCoachFixture {
    static func set(
        number: Int,
        weight: String,
        unit: WeightUnit = .kg,
        reps: String,
        rpe: String,
        rpeScale: StrengthWorkoutRPEScale = .strength
    ) -> StrengthCompletedSet {
        StrengthCompletedSet(
            setNumber: number,
            weight: weight,
            weightUnit: unit.rawValue,
            reps: reps,
            rpe: rpe,
            rpeScale: rpeScale
        )
    }

    static func session(
        date: Date,
        durationSeconds: Int = 600,
        caloriesBurned: Int? = nil,
        exercise: String,
        sets: [StrengthCompletedSet]
    ) -> StrengthWorkoutSession {
        StrengthWorkoutSession(
            diaryDate: Calendar.current.startOfDay(for: date),
            startedAt: date.addingTimeInterval(-Double(durationSeconds)),
            completedAt: date,
            durationSeconds: durationSeconds,
            exercises: [
                StrengthCompletedExercise(
                    itemID: exercise.lowercased().replacingOccurrences(of: " ", with: "-"),
                    name: exercise,
                    targetMuscles: ["Chest"],
                    equipment: "Barbell",
                    sets: sets
                )
            ],
            caloriesBurned: caloriesBurned
        )
    }

    static func jsonObject(_ value: String) throws -> [String: Any] {
        let data = try #require(value.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
