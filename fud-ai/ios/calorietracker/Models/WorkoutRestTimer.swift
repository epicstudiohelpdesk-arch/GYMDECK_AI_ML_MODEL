import Foundation

/// The global rest countdown preference in Workouts settings: off, or 30 s to 5 min.
nonisolated enum WorkoutRestTimerSetting {
    static let defaultSeconds = 90
    static let minimumSeconds = 30
    static let maximumSeconds = 300
    /// 0 means off.
    static let options = [0, 30, 45, 60, 90, 120, 150, 180, 240, 300]

    /// A missing value (diaries saved before the rest timer) uses the default.
    static func sanitized(_ seconds: Int?) -> Int {
        guard let seconds else { return defaultSeconds }
        guard seconds > 0 else { return 0 }
        return min(max(seconds, minimumSeconds), maximumSeconds)
    }

    static func label(for seconds: Int) -> String {
        guard seconds > 0 else { return String(localized: "Off") }
        return Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
    }
}

/// One rest period after a logged strength set. The countdown is anchored to
/// wall-clock timestamps, so it stays exact while the app is in the background,
/// and it is saved while it runs so a relaunch brings it back.
struct WorkoutRestTimer: Equatable, Codable {
    static let extensionSeconds: TimeInterval = 15
    /// A countdown that ran out longer ago than this ended while the app was in
    /// the background; its notification already announced it.
    static let inAppAlertWindow: TimeInterval = 3

    let exerciseID: UUID
    let setID: UUID
    let exerciseName: String
    let startedAt: Date
    private(set) var endsAt: Date

    /// Nil when the rest timer is off.
    init?(exerciseID: UUID, setID: UUID, exerciseName: String, durationSeconds: Int, now: Date = .now) {
        guard durationSeconds > 0 else { return nil }
        self.exerciseID = exerciseID
        self.setID = setID
        self.exerciseName = exerciseName
        startedAt = now
        endsAt = now.addingTimeInterval(TimeInterval(durationSeconds))
    }

    func remainingSeconds(at now: Date = .now) -> Int {
        let remaining = endsAt.timeIntervalSince(now)
        guard remaining.isFinite, remaining > 0 else { return 0 }
        return Int(remaining.rounded(.up))
    }

    func isFinished(at now: Date = .now) -> Bool { now >= endsAt }

    /// Fraction of the rest already elapsed, 0...1.
    func progress(at now: Date = .now) -> Double {
        let total = endsAt.timeIntervalSince(startedAt)
        guard total > 0 else { return 1 }
        return min(max(now.timeIntervalSince(startedAt) / total, 0), 1)
    }

    /// Adds time to the countdown; once it has already run out it counts again from now.
    mutating func extend(by seconds: TimeInterval = extensionSeconds, now: Date = .now) {
        endsAt = max(endsAt, now).addingTimeInterval(seconds)
    }

    func shouldAlertInApp(at now: Date = .now) -> Bool {
        isFinished(at: now) && now.timeIntervalSince(endsAt) < Self.inAppAlertWindow
    }

    /// A set counts as logged once its reps are first filled in, so that edit
    /// starts rest. Only today's log rests; planning or back-filling another day
    /// does not. A set that already rested is being corrected (its reps cleared
    /// and typed again), which leaves the running rest alone.
    static func shouldStart(
        previousReps: String,
        newReps: String,
        restSeconds: Int,
        isToday: Bool,
        alreadyRested: Bool = false
    ) -> Bool {
        guard restSeconds > 0, isToday, !alreadyRested else { return false }
        let wasLogged = !previousReps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isLogged = !newReps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !wasLogged && isLogged
    }

    /// The set stepper adds the next set prefilled from the one before it, so
    /// its reps never go from blank to filled. Adding a set with the stepper
    /// therefore finishes the previous one: returns that set when its reps are
    /// filled in and it should rest now. A rest that is still counting down for
    /// it keeps running, so adding sets ahead never restarts it.
    static func setFinishedByAddingSets(
        before: [StrengthPlannedSet],
        after: [StrengthPlannedSet],
        restSeconds: Int,
        isToday: Bool,
        running: WorkoutRestTimer?,
        now: Date = .now
    ) -> UUID? {
        guard let finished = before.last,
              after.count > before.count,
              after.contains(where: { $0.id == finished.id }),
              shouldStart(previousReps: "", newReps: finished.reps, restSeconds: restSeconds, isToday: isToday)
        else { return nil }
        if let running, running.setID == finished.id, !running.isFinished(at: now) { return nil }
        return finished.id
    }

    /// "m:ss", the same in every language.
    static func clockText(seconds: Int) -> String {
        let safe = max(0, seconds)
        return String(format: "%d:%02d", safe / 60, safe % 60)
    }
}
