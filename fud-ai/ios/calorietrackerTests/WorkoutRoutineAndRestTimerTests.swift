import Foundation
import Testing
@testable import calorietracker

@MainActor
struct WorkoutRestTimerTests {
    private let start = Date(timeIntervalSince1970: 1_792_000_000)
    private let exerciseID = UUID()
    private let setID = UUID()

    private func timer(_ seconds: Int = 90) throws -> WorkoutRestTimer {
        try #require(WorkoutRestTimer(
            exerciseID: exerciseID,
            setID: setID,
            exerciseName: "Bench Press",
            durationSeconds: seconds,
            now: start
        ))
    }

    @Test func settingIsOffOrClampedToHalfAMinuteThroughFiveMinutes() {
        #expect(WorkoutRestTimerSetting.sanitized(nil) == 90)
        #expect(WorkoutRestTimerSetting.sanitized(0) == 0)
        #expect(WorkoutRestTimerSetting.sanitized(-15) == 0)
        #expect(WorkoutRestTimerSetting.sanitized(10) == 30)
        #expect(WorkoutRestTimerSetting.sanitized(900) == 300)
        #expect(WorkoutRestTimerSetting.options.map { WorkoutRestTimerSetting.sanitized($0) } == WorkoutRestTimerSetting.options)
        #expect(WorkoutRestTimerSetting.options.first == 0)
        #expect(WorkoutRestTimerSetting.options.last == 300)
        #expect(WorkoutRestTimerSetting.label(for: 0) == String(localized: "Off"))
    }

    @Test func preferencesSavedBeforeTheRestTimerUseTheDefault() throws {
        let legacy = Data(#"{"targetMuscles":[],"issues":[],"additionalIssues":"","frequencyDays":4,"duration":60,"split":"fullBody","customSplit":"","equipment":[],"rpeScale":"cr10","strength":{}}"#.utf8)
        let decoded = try JSONDecoder().decode(StrengthWorkoutPreferences.self, from: legacy)
        #expect(decoded.restTimerSeconds == nil)
        #expect(decoded.restSeconds == 90)
        #expect(decoded.rpeScale == .cr10)

        var preferences = StrengthWorkoutPreferences()
        preferences.restTimerSeconds = 1_200
        preferences.sanitize()
        #expect(preferences.restTimerSeconds == 300)
        preferences.restTimerSeconds = 0
        preferences.sanitize()
        #expect(preferences.restSeconds == 0)
    }

    @Test func startingWithTheTimerOffCreatesNoCountdown() {
        #expect(WorkoutRestTimer(exerciseID: exerciseID, setID: setID, exerciseName: "Bench", durationSeconds: 0, now: start) == nil)
    }

    @Test func countdownRoundsUpToWholeSecondsAndFinishesAtItsEnd() throws {
        let rest = try timer(90)
        #expect(rest.remainingSeconds(at: start) == 90)
        #expect(rest.remainingSeconds(at: start.addingTimeInterval(0.2)) == 90)
        #expect(rest.remainingSeconds(at: start.addingTimeInterval(89.001)) == 1)
        #expect(rest.remainingSeconds(at: start.addingTimeInterval(90)) == 0)
        #expect(rest.remainingSeconds(at: start.addingTimeInterval(500)) == 0)
        #expect(!rest.isFinished(at: start.addingTimeInterval(89.9)))
        #expect(rest.isFinished(at: start.addingTimeInterval(90)))
        #expect(abs(rest.progress(at: start.addingTimeInterval(45)) - 0.5) < 0.0001)
        #expect(rest.progress(at: start.addingTimeInterval(120)) == 1)
    }

    @Test func addingFifteenSecondsExtendsARunningRestAndRestartsAFinishedOneFromNow() throws {
        var running = try timer(60)
        running.extend(now: start.addingTimeInterval(20))
        #expect(running.endsAt == start.addingTimeInterval(75))
        #expect(running.remainingSeconds(at: start.addingTimeInterval(20)) == 55)

        var finished = try timer(60)
        finished.extend(now: start.addingTimeInterval(100))
        #expect(finished.endsAt == start.addingTimeInterval(115))
    }

    @Test func onlyAJustFinishedRestAlertsInApp() throws {
        let rest = try timer(30)
        #expect(!rest.shouldAlertInApp(at: start.addingTimeInterval(29)))
        #expect(rest.shouldAlertInApp(at: start.addingTimeInterval(30)))
        #expect(rest.shouldAlertInApp(at: start.addingTimeInterval(32.9)))
        // A rest that ran out while the app was in the background was announced by its notification.
        #expect(!rest.shouldAlertInApp(at: start.addingTimeInterval(60)))
    }

    @Test func loggingASetStartsRestOnlyWhenItsRepsAreFirstFilledInToday() {
        #expect(WorkoutRestTimer.shouldStart(previousReps: "", newReps: "8", restSeconds: 90, isToday: true))
        #expect(WorkoutRestTimer.shouldStart(previousReps: " ", newReps: "12", restSeconds: 90, isToday: true))
        // Editing a logged set, or clearing it, keeps the current rest.
        #expect(!WorkoutRestTimer.shouldStart(previousReps: "8", newReps: "10", restSeconds: 90, isToday: true))
        #expect(!WorkoutRestTimer.shouldStart(previousReps: "8", newReps: "", restSeconds: 90, isToday: true))
        #expect(!WorkoutRestTimer.shouldStart(previousReps: "", newReps: "", restSeconds: 90, isToday: true))
        // Off, or planning/back-filling another day.
        #expect(!WorkoutRestTimer.shouldStart(previousReps: "", newReps: "8", restSeconds: 0, isToday: true))
        #expect(!WorkoutRestTimer.shouldStart(previousReps: "", newReps: "8", restSeconds: 90, isToday: false))
        // A set that already rested is being corrected: its reps cleared and typed again.
        #expect(!WorkoutRestTimer.shouldStart(
            previousReps: "", newReps: "8", restSeconds: 90, isToday: true, alreadyRested: true
        ))
    }

    private func restDefaults() throws -> (UserDefaults, String) {
        let suite = "WorkoutRestTimerTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    private func notification(endingAt endsAt: Date) -> [AnyHashable: Any] {
        [WorkoutRestTimerController.endsAtUserInfoKey: endsAt.timeIntervalSince1970]
    }

    @Test func aRunningRestIsSavedAndComesBackAfterARelaunch() throws {
        let (defaults, suite) = try restDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date.now
        let first = WorkoutRestTimerController(defaults: defaults, isAppActive: { true }, now: now)
        #expect(!first.hasRested(setID: setID))
        first.start(exerciseID: exerciseID, setID: setID, exerciseName: "Bench Press", durationSeconds: 90, now: now)
        let running = try #require(first.timer)
        #expect(first.hasRested(setID: setID))

        // A relaunch before the end brings the countdown back, and the set still counts as rested.
        let relaunched = WorkoutRestTimerController(defaults: defaults, isAppActive: { true }, now: now.addingTimeInterval(30))
        #expect(relaunched.timer == running)
        #expect(relaunched.hasRested(setID: setID))
        // Its notification arriving while the app is open stays silent: the haptic follows.
        #expect(!relaunched.presentsNotificationInForeground(userInfo: notification(endingAt: running.endsAt)))

        relaunched.skip()
        #expect(relaunched.timer == nil)
        #expect(defaults.data(forKey: WorkoutRestTimerController.storageKey) == nil)
        first.skip()
    }

    @Test func aRestThatEndedWhileTheAppWasClosedIsLeftToItsNotification() throws {
        let (defaults, suite) = try restDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = try timer(60)
        defaults.set(try JSONEncoder().encode(saved), forKey: WorkoutRestTimerController.storageKey)

        let controller = WorkoutRestTimerController(defaults: defaults, isAppActive: { true }, now: start.addingTimeInterval(90))
        #expect(controller.timer == nil)
        #expect(defaults.data(forKey: WorkoutRestTimerController.storageKey) == nil)
        #expect(controller.hasRested(setID: setID))
        // Its notification may still arrive once the app is open, and then it shows.
        #expect(controller.presentsNotificationInForeground(userInfo: notification(endingAt: saved.endsAt)))
        // Another rest's notification, or one without an end, stays silent.
        #expect(!controller.presentsNotificationInForeground(
            userInfo: notification(endingAt: saved.endsAt.addingTimeInterval(15))
        ))
        #expect(!controller.presentsNotificationInForeground(userInfo: [:]))
    }

    @Test func onlyARestThatEndedOutOfSightShowsItsNotificationInTheForeground() async throws {
        for appIsActive in [false, true] {
            let (defaults, suite) = try restDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            let controller = WorkoutRestTimerController(defaults: defaults, isAppActive: { appIsActive })
            // Started almost a full rest ago, so it ends a moment from now.
            controller.start(
                exerciseID: exerciseID,
                setID: setID,
                exerciseName: "Bench Press",
                durationSeconds: 30,
                now: Date.now.addingTimeInterval(-29.8)
            )
            let rest = try #require(controller.timer)
            for _ in 0..<100 where controller.timer != nil {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(controller.timer == nil)
            #expect(defaults.data(forKey: WorkoutRestTimerController.storageKey) == nil)
            // Ended in front of the user, the haptic was the alert; out of sight, the notification is.
            #expect(controller.presentsNotificationInForeground(userInfo: notification(endingAt: rest.endsAt)) == !appIsActive)
        }
    }

    @Test func addingASetWithTheStepperFinishesThePreviousLoggedSet() throws {
        let first = StrengthPlannedSet(weight: "60", reps: "8")
        let second = first.copyingFromPrevious()
        let third = second.copyingFromPrevious()
        func finished(
            _ before: [StrengthPlannedSet],
            _ after: [StrengthPlannedSet],
            restSeconds: Int = 90,
            isToday: Bool = true,
            running: WorkoutRestTimer? = nil,
            at now: Date? = nil
        ) -> UUID? {
            WorkoutRestTimer.setFinishedByAddingSets(
                before: before,
                after: after,
                restSeconds: restSeconds,
                isToday: isToday,
                running: running,
                now: now ?? start
            )
        }

        // The new set arrives with the reps already filled in, so typing never starts its rest.
        #expect(second.reps == "8")
        #expect(finished([first], [first, second]) == first.id)
        #expect(finished([first, second], [first, second, third]) == second.id)

        // A set whose reps are still blank is not logged yet, and removing or keeping sets logs nothing.
        let blank = StrengthPlannedSet()
        #expect(finished([blank], [blank, blank.copyingFromPrevious()]) == nil)
        #expect(finished([first, second], [first]) == nil)
        #expect(finished([first], [first]) == nil)
        #expect(finished([], [first]) == nil)
        // Off, or planning/back-filling another day.
        #expect(finished([first], [first, second], restSeconds: 0) == nil)
        #expect(finished([first], [first, second], isToday: false) == nil)

        // Adding sets ahead while the previous set rests keeps that countdown; once it ran out,
        // or while another set rests, the previous set starts its own rest.
        let resting = try #require(WorkoutRestTimer(
            exerciseID: exerciseID,
            setID: first.id,
            exerciseName: "Bench Press",
            durationSeconds: 90,
            now: start
        ))
        #expect(finished([first], [first, second], running: resting, at: start.addingTimeInterval(30)) == nil)
        #expect(finished([first], [first, second], running: resting, at: start.addingTimeInterval(90)) == first.id)
        #expect(finished([first, second], [first, second, third], running: resting) == second.id)
    }

    @Test func clockTextIsMinutesAndPaddedSeconds() {
        #expect(WorkoutRestTimer.clockText(seconds: 90) == "1:30")
        #expect(WorkoutRestTimer.clockText(seconds: 5) == "0:05")
        #expect(WorkoutRestTimer.clockText(seconds: 300) == "5:00")
        #expect(WorkoutRestTimer.clockText(seconds: -3) == "0:00")
    }
}

@MainActor
struct WorkoutRoutineTests {
    private func exercise(
        _ id: String,
        sets: [StrengthPlannedSet]? = nil,
        category: String = "strength",
        timer: StrengthExerciseTimer? = nil
    ) -> StrengthPlannedExercise {
        var exercise = StrengthPlannedExercise(item: WorkoutTestFixture.exercise(
            id: id,
            name: id.capitalized,
            category: category
        ))
        exercise.sets = sets ?? [StrengthPlannedSet()]
        exercise.timer = timer
        return exercise
    }

    private func logged(_ weight: String, _ reps: String, rpe: String = "") -> StrengthPlannedSet {
        StrengthPlannedSet(
            weight: weight,
            weightUnit: WeightUnit.kg.rawValue,
            reps: reps,
            rpe: rpe,
            rpeScale: rpe.isEmpty ? nil : .strength
        )
    }

    @Test func namesAreTrimmedCollapsedAndCapped() {
        #expect(StrengthWorkoutRoutinePlanner.sanitizedName("  Push \n  day  ") == "Push day")
        #expect(StrengthWorkoutRoutinePlanner.sanitizedName("   ").isEmpty)
        #expect(StrengthWorkoutRoutinePlanner.sanitizedName(String(repeating: "x", count: 90)).count == StrengthWorkoutRoutinePlanner.maxNameLength)
    }

    @Test func templateKeepsPlannedLoadsAndRepsButNotRpeTimersOrIdentities() {
        let bench = exercise(
            "bench",
            sets: [logged("60", "10", rpe: "8"), logged("62.5", "8", rpe: "9")],
            timer: StrengthExerciseTimer(accumulatedSeconds: 30, savedDurationSeconds: 30)
        )
        let run = exercise(
            "run",
            sets: [StrengthPlannedSet(reps: "5")],
            category: "cardio",
            timer: StrengthExerciseTimer(accumulatedSeconds: 600, savedDurationSeconds: 600)
        )

        let template = StrengthWorkoutRoutinePlanner.template(from: [bench, run])

        #expect(template.map(\.itemID) == ["bench", "run"])
        #expect(template[0].id != bench.id)
        #expect(template[0].timer == nil)
        #expect(template[0].sets.map(\.weight) == ["60", "62.5"])
        #expect(template[0].sets.map(\.reps) == ["10", "8"])
        #expect(template[0].sets.map(\.weightUnit) == ["kg", "kg"])
        #expect(template[0].sets.allSatisfy { $0.rpe.isEmpty && $0.rpeScale == nil })
        #expect(Set(template[0].sets.map(\.id)).isDisjoint(with: bench.sets.map(\.id)))
        // Cardio keeps only the shape of a newly picked exercise: no time, no hidden set values.
        #expect(template[1].timer == nil)
        #expect(template[1].sets.count == 1)
        #expect(!template[1].sets[0].hasLoggedValue)
    }

    @Test func applyingToAnEmptyDayAddsFreshCopiesOfEveryRoutineExercise() {
        let routine = StrengthWorkoutRoutinePlanner.template(from: [
            exercise("bench", sets: [logged("60", "10"), logged("60", "10")]),
            exercise("row"),
        ])

        let day = StrengthWorkoutRoutinePlanner.merged(day: [], routine: routine)
        let again = StrengthWorkoutRoutinePlanner.merged(day: [], routine: routine)

        #expect(day.map(\.itemID) == ["bench", "row"])
        #expect(day[0].sets.map(\.reps) == ["10", "10"])
        // Each application is its own diary entry with its own identities.
        #expect(day.map(\.id) != again.map(\.id))
        #expect(Set(day.map(\.id)).isDisjoint(with: routine.map(\.id)))
        #expect(Set(day.flatMap(\.sets).map(\.id)).isDisjoint(with: routine.flatMap(\.sets).map(\.id)))
    }

    @Test func applyingToADayNeverOverwritesLoggedSetsAndAppendsTheRest() {
        let loggedBench = exercise("bench", sets: [logged("70", "5", rpe: "9")])
        let blankSquat = exercise("squat")
        let timedPlank = exercise("plank", timer: StrengthExerciseTimer(runningSince: Date(timeIntervalSince1970: 1_792_000_000)))
        let routine = StrengthWorkoutRoutinePlanner.template(from: [
            exercise("bench", sets: [logged("60", "10"), logged("60", "10"), logged("60", "10")]),
            exercise("squat", sets: [logged("100", "5"), logged("100", "5")]),
            exercise("plank", sets: [logged("", "60")]),
            exercise("row", sets: [logged("50", "12")]),
        ])

        let merged = StrengthWorkoutRoutinePlanner.merged(day: [loggedBench, blankSquat, timedPlank], routine: routine)

        #expect(merged.map(\.itemID) == ["bench", "squat", "plank", "row"])
        // Logged work stays exactly as it was.
        #expect(merged[0] == loggedBench)
        #expect(merged[2] == timedPlank)
        // A matching entry with nothing logged takes the planned sets, keeping its identity.
        #expect(merged[1].id == blankSquat.id)
        #expect(merged[1].sets.map(\.weight) == ["100", "100"])
        #expect(merged[1].sets.map(\.reps) == ["5", "5"])
        #expect(merged[3].sets.map(\.reps) == ["12"])
    }

    @Test func repeatedExercisesInARoutineMatchDayEntriesInOrder() {
        let day = [exercise("bench", sets: [logged("80", "3")])]
        let routine = StrengthWorkoutRoutinePlanner.template(from: [
            exercise("bench", sets: [logged("80", "3")]),
            exercise("bench", sets: [logged("60", "12"), logged("60", "12")]),
        ])

        let merged = StrengthWorkoutRoutinePlanner.merged(day: day, routine: routine)

        // The first bench meets the logged entry and leaves it alone; the back-off bench is added.
        #expect(merged.count == 2)
        #expect(merged[0] == day[0])
        #expect(merged[1].sets.map(\.reps) == ["12", "12"])
    }

    @Test func onlyEntriesWithoutLoggedValuesCanReceiveAPlan() {
        #expect(StrengthWorkoutRoutinePlanner.canReceivePlan(exercise("bench")))
        #expect(StrengthWorkoutRoutinePlanner.canReceivePlan(exercise("bench", timer: StrengthExerciseTimer(intensity: .vigorous))))
        #expect(!StrengthWorkoutRoutinePlanner.canReceivePlan(exercise("bench", sets: [StrengthPlannedSet(weight: "40")])))
        #expect(!StrengthWorkoutRoutinePlanner.canReceivePlan(exercise("bench", sets: [StrengthPlannedSet(rpe: "7")])))
        #expect(!StrengthWorkoutRoutinePlanner.canReceivePlan(exercise("bench", timer: StrengthExerciseTimer(accumulatedSeconds: 12))))
    }

    // MARK: - Store

    private let monday = WorkoutTestFixture.date(2026, 10, 12)
    private let thursday = WorkoutTestFixture.date(2026, 10, 15)

    /// Monday: bench 2 x 10 @ 60 kg (RPE 8) and rows with one blank set.
    private func logMonday(_ store: StrengthWorkoutStore) throws {
        store.toggleExercise(WorkoutTestFixture.exercise(id: "bench", name: "Bench Press"), on: monday)
        store.toggleExercise(WorkoutTestFixture.exercise(id: "row", name: "Barbell Row"), on: monday)
        let bench = try #require(store.exercises(for: monday).first { $0.itemID == "bench" })
        store.setSetCount(2, exerciseID: bench.id, on: monday)
        for set in try #require(store.exercises(for: monday).first { $0.itemID == "bench" }).sets {
            store.updateSet(exerciseID: bench.id, setID: set.id, on: monday, weight: "60", weightUnit: .kg, reps: "10", rpe: "8")
        }
    }

    @Test func steppingUpAfterALoggedSetRestsThatSetEachTime() throws {
        let fixture = WorkoutTestFixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        store.toggleExercise(WorkoutTestFixture.exercise(id: "bench", name: "Bench Press"), on: monday)
        let bench = try #require(store.exercises(for: monday).first)
        let firstSetID = try #require(bench.sets.first).id
        store.updateSet(exerciseID: bench.id, setID: firstSetID, on: monday, weight: "60", weightUnit: .kg, reps: "8")
        func sets() -> [StrengthPlannedSet] { store.exercises(for: monday).first?.sets ?? [] }

        // What the workout log does when + is tapped: compare the sets before and after.
        func restAfterAddingSet() -> UUID? {
            let before = sets()
            store.setSetCount(before.count + 1, exerciseID: bench.id, on: monday)
            return WorkoutRestTimer.setFinishedByAddingSets(
                before: before,
                after: sets(),
                restSeconds: 90,
                isToday: true,
                running: nil
            )
        }

        let first = try #require(sets().first)
        #expect(restAfterAddingSet() == first.id)
        // Set 2 arrived with set 1's reps, so adding set 3 finishes set 2 without any typing.
        let second = sets()[1]
        #expect(second.reps == "8")
        #expect(restAfterAddingSet() == second.id)
        #expect(sets().count == 3)
    }

    @Test func savingKeepsTheDaysPlanAndRejectsEmptyDaysAndNames() throws {
        let fixture = WorkoutTestFixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        try logMonday(store)

        #expect(store.saveRoutine(named: "   ", from: monday) == nil)
        #expect(store.saveRoutine(named: "Push", from: thursday) == nil)
        let saved = try #require(store.saveRoutine(named: "  Push   day ", from: monday))

        #expect(store.routines == [saved])
        #expect(saved.name == "Push day")
        #expect(saved.exercises.map(\.itemID) == ["bench", "row"])
        #expect(saved.exercises[0].sets.map(\.weight) == ["60", "60"])
        #expect(saved.exercises[0].sets.map(\.reps) == ["10", "10"])
        #expect(saved.exercises[0].sets.allSatisfy { $0.rpe.isEmpty })
        // The day itself is untouched.
        #expect(store.exercises(for: monday)[0].sets[0].rpe == "8")
    }

    @Test func routinesPersistRenameAndDeleteWithoutTouchingTheDiary() throws {
        let fixture = WorkoutTestFixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        try logMonday(store)
        let push = try #require(store.saveRoutine(named: "Push", from: monday))
        let pull = try #require(store.saveRoutine(named: "Pull", from: monday))

        #expect(store.renameRoutine(push.id, to: "Push A"))
        #expect(!store.renameRoutine(push.id, to: "  "))
        #expect(!store.renameRoutine(UUID(), to: "Ghost"))
        #expect(fixture.makeStore().routines.map(\.name) == ["Push A", "Pull"])
        #expect(fixture.makeStore().sortedRoutines.map(\.name) == ["Pull", "Push A"])

        store.deleteRoutine(pull.id)
        let reloaded = fixture.makeStore()
        #expect(reloaded.routines.map(\.id) == [push.id])
        #expect(reloaded.exercises(for: monday).count == 2)
    }

    @Test func applyingFillsAnEmptyDayAndAppendsWithoutTouchingLoggedSets() throws {
        let fixture = WorkoutTestFixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        try logMonday(store)
        let routine = try #require(store.saveRoutine(named: "Push", from: monday))

        #expect(store.applyRoutine(routine.id, to: thursday))
        let thursdayPlan = store.exercises(for: thursday)
        #expect(thursdayPlan.map(\.itemID) == ["bench", "row"])
        #expect(thursdayPlan[0].sets.map(\.weight) == ["60", "60"])

        // Friday already has a logged bench set and a blank squat.
        let friday = WorkoutTestFixture.date(2026, 10, 16)
        store.toggleExercise(WorkoutTestFixture.exercise(id: "bench", name: "Bench Press"), on: friday)
        store.toggleExercise(WorkoutTestFixture.exercise(id: "squat", name: "Squat"), on: friday)
        let fridayBench = store.exercises(for: friday)[0]
        store.updateSet(exerciseID: fridayBench.id, setID: fridayBench.sets[0].id, on: friday, weight: "80", weightUnit: .kg, reps: "3")
        let loggedBench = store.exercises(for: friday)[0]

        #expect(store.applyRoutine(routine.id, to: friday))
        let fridayPlan = fixture.makeStore().exercises(for: friday)
        #expect(fridayPlan.map(\.itemID) == ["bench", "squat", "row"])
        #expect(fridayPlan[0] == loggedBench)

        #expect(!store.applyRoutine(UUID(), to: friday))
    }

    @Test func diariesSavedBeforeRoutinesStillLoad() throws {
        let fixture = WorkoutTestFixture()
        defer { fixture.cleanUp() }
        let legacy = Data(#"{"version":1,"dayPlans":{},"completedSessions":[],"savedExerciseIDs":["bench"],"preferences":{"targetMuscles":[],"issues":[],"additionalIssues":"","frequencyDays":3,"duration":60,"split":"fullBody","customSplit":"","equipment":[],"rpeScale":"strength","strength":{}}}"#.utf8)
        fixture.defaults.set(legacy, forKey: fixture.storageKey)

        let store = fixture.makeStore()

        #expect(!store.isPersistenceBlocked)
        #expect(store.routines.isEmpty)
        #expect(store.savedExerciseIDs == ["bench"])
        #expect(store.preferences.restSeconds == 90)
    }

    @Test func clearingTheDiaryRemovesRoutines() throws {
        let fixture = WorkoutTestFixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        try logMonday(store)
        store.saveRoutine(named: "Push", from: monday)

        store.clearAll()

        #expect(store.routines.isEmpty)
        #expect(fixture.makeStore().routines.isEmpty)
    }
}
