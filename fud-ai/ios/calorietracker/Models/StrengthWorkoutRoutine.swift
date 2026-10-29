import Foundation

/// A named, reusable exercise list saved from a diary day, with each
/// exercise's planned sets, reps and loads.
struct StrengthWorkoutRoutine: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var exercises: [StrengthPlannedExercise]
    var createdAt: Date

    var exerciseSummary: String {
        exercises.map(\.name).joined(separator: ", ")
    }
}

enum StrengthWorkoutRoutinePlanner {
    static let maxNameLength = 60

    /// Trims, collapses inner whitespace and caps the length.
    static func sanitizedName(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return String(words.joined(separator: " ").prefix(maxNameLength))
    }

    /// The day's exercises as a plan: fresh identities, the planned load, unit
    /// and reps of every set. RPE (how a set felt) and exercise timers belong to
    /// the day they were logged, so they are not part of a routine.
    static func template(from exercises: [StrengthPlannedExercise]) -> [StrengthPlannedExercise] {
        exercises.map { exercise in
            var copy = exercise.copiedForNewDay(includeSetDetails: true)
            copy.timer = nil
            if copy.isCardio {
                // Cardio cards have no set fields; keep the shape of a newly picked exercise.
                copy.sets = [StrengthPlannedSet()]
            } else {
                copy.sets = copy.sets.map {
                    StrengthPlannedSet(weight: $0.weight, weightUnit: $0.weightUnit, reps: $0.reps)
                }
                if copy.sets.isEmpty { copy.sets = [StrengthPlannedSet()] }
            }
            return copy
        }
    }

    /// Adds a routine to a day without touching anything already logged there.
    ///
    /// Each routine exercise is matched, in order, to an unmatched entry of the
    /// same exercise already on the day. A matched entry that holds no logged
    /// value yet (no weight, reps or RPE and no started timer) takes the
    /// routine's planned sets; one with logged work is left exactly as it is.
    /// Routine exercises with no match are appended as new entries.
    static func merged(
        day: [StrengthPlannedExercise],
        routine: [StrengthPlannedExercise]
    ) -> [StrengthPlannedExercise] {
        var result = day
        var matchedDayIndices = Set<Int>()
        for template in routine {
            if let index = day.indices.first(where: {
                !matchedDayIndices.contains($0) && day[$0].itemID == template.itemID
            }) {
                matchedDayIndices.insert(index)
                guard canReceivePlan(result[index]) else { continue }
                result[index].sets = template.copiedForNewDay(includeSetDetails: true).sets
            } else {
                var added = template.copiedForNewDay(includeSetDetails: true)
                added.timer = nil
                result.append(added)
            }
        }
        return result
    }

    /// True while a day entry holds nothing the user logged.
    static func canReceivePlan(_ exercise: StrengthPlannedExercise) -> Bool {
        !exercise.sets.contains(where: \.hasLoggedValue) && exercise.timer?.hasStarted != true
    }
}
