import Foundation

/// A workout change Coach suggests in chat. Coach can only propose: nothing is written until
/// the user taps Add on the card shown under the reply, and a resolved card never applies again.
/// Mirrors Android CoachExerciseProposal.
struct CoachExerciseProposal: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case customExercise = "custom_exercise"
        case addToDay = "add_to_day"
    }

    enum Status: String, Codable {
        case pending
        case added
        case dismissed
    }

    let id: String
    let kind: Kind
    var status: Status = .pending
    /// The new exercise's name, or the library exercise being added.
    let name: String
    /// Custom exercise: the id it is saved under, chosen up front so Add can never create it twice.
    /// Add to day: the catalog or custom exercise id.
    let itemID: String
    var category: String?
    var equipment: String?
    var primaryMuscles: [String] = []
    var secondaryMuscles: [String] = []
    var instructions: [String] = []
    /// Add to day: the Gregorian ISO day (yyyy-MM-dd) Coach proposed. This is not a diary key:
    /// the diary keys days in the phone's calendar, so read and write it through `day`.
    var dateKey: String?
    var sets: Int?
    var reps: Int?
    var durationMinutes: Int?
    /// The diary entry's id, chosen up front so Add can never append the exercise twice.
    var entryID: UUID?

    /// True when two proposals suggest the same change, so a repeated tool call in one reply
    /// shows one card instead of two.
    func suggestsSameChange(as other: CoachExerciseProposal) -> Bool {
        guard kind == other.kind else { return false }
        switch kind {
        case .customExercise:
            return name.lowercased() == other.name.lowercased()
        case .addToDay:
            return itemID == other.itemID && dateKey == other.dateKey && sets == other.sets
                && reps == other.reps && durationMinutes == other.durationMinutes
        }
    }

    /// Coach reads and writes dates as Gregorian ISO days whatever calendar the phone uses, and
    /// a saved card has to keep its day even if that setting changes later.
    static func dateKey(for date: Date) -> String {
        StrengthWorkoutDate.key(for: date, calendar: isoCalendar)
    }

    /// The start of the proposed day, which the diary turns into its own key.
    var day: Date? {
        dateKey.flatMap { StrengthWorkoutDate.date(for: $0, calendar: Self.isoCalendar) }
    }

    /// The diary's key for the proposed day, in the calendar the diary uses.
    func diaryDateKey(calendar: Calendar = .current) -> String? {
        day.map { StrengthWorkoutStore.dateKey(for: $0, calendar: calendar) }
    }

    private static var isoCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// What the model is told about this card on later turns, so it knows what the user did.
    var contextLine: String {
        let outcome: String
        switch status {
        case .pending: outcome = "waiting for the user to tap Add"
        case .added: outcome = "added by the user"
        case .dismissed: outcome = "dismissed by the user"
        }
        switch kind {
        case .customExercise:
            return "[Coach proposed creating the custom exercise \"\(name)\": \(outcome)]"
        case .addToDay:
            return "[Coach proposed adding \"\(name)\" (catalog_id \(itemID)) to the workout diary on \(dateKey ?? "today"): \(outcome)]"
        }
    }
}

/// Collects the proposals Coach makes while answering one message, for the chat to show as cards.
final class CoachExerciseProposalCollector {
    static let maxProposals = 10

    private(set) var proposals: [CoachExerciseProposal] = []

    /// A provider fallback re-runs the whole reply, so proposals from a failed attempt are dropped.
    func reset() {
        proposals = []
    }

    /// Keeps the proposal and returns it, or returns the earlier card for the same change.
    /// Returns nil once a reply already holds the maximum number of proposals.
    func add(_ proposal: CoachExerciseProposal) -> CoachExerciseProposal? {
        if let existing = proposals.first(where: { $0.suggestsSameChange(as: proposal) }) {
            return existing
        }
        guard proposals.count < Self.maxProposals else { return nil }
        proposals.append(proposal)
        return proposal
    }
}

/// Performs a confirmed proposal through the workout store. Both writes use ids fixed when the
/// proposal was made, so repeating an apply leaves the diary and library unchanged.
enum CoachExerciseProposalApplier {
    enum ApplyError: LocalizedError, Equatable {
        case exerciseMissing
        case nameTaken
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .exerciseMissing:
                return String(
                    localized: "This exercise is no longer in your library.",
                    comment: "Coach chat error when the user taps Add on a suggested workout entry whose exercise was deleted."
                )
            case .nameTaken:
                return String(
                    localized: "An exercise with this name is already in your library.",
                    comment: "Coach chat error when the user taps Add on a suggested custom exercise whose name was saved to the library after Coach suggested it."
                )
            case .saveFailed:
                return String(
                    localized: "Couldn't save this change. Try again.",
                    comment: "Coach chat error when a suggested exercise could not be saved to the workout diary or library."
                )
            }
        }
    }

    static func apply(_ proposal: CoachExerciseProposal, to store: StrengthWorkoutStore) throws {
        switch proposal.kind {
        case .customExercise:
            // Already saved under the card's own id, so a repeated Add is a no-op.
            guard store.userExerciseTemplate(for: proposal.itemID) == nil else { return }
            // The name was free when Coach proposed it, but another card or the user may have
            // saved it while this card waited. Same match CoachTools uses when proposing.
            let name = proposal.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !store.exerciseLibrary.exercises.contains(where: {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame
            }) else { throw ApplyError.nameTaken }
            let draft = UserExerciseDraft(
                name: proposal.name,
                instructions: proposal.instructions.joined(separator: "\n"),
                category: proposal.category ?? "Strength",
                rawEquipment: proposal.equipment ?? "Unspecified",
                primaryMuscles: proposal.primaryMuscles,
                secondaryMuscles: proposal.secondaryMuscles
            )
            guard store.saveUserExercise(draft, existingItemID: proposal.itemID) != nil else {
                throw ApplyError.saveFailed
            }
        case .addToDay:
            guard let item = store.exerciseLibrary.exercises.first(where: { $0.id == proposal.itemID }) else {
                throw ApplyError.exerciseMissing
            }
            guard let date = proposal.day,
                  let entryID = proposal.entryID
            else { throw ApplyError.saveFailed }
            guard store.addPlannedExercise(plannedExercise(for: proposal, item: item, entryID: entryID), on: date) else {
                throw ApplyError.saveFailed
            }
        }
    }

    /// The diary entry an add-to-day proposal creates: its sets (each with the proposed reps)
    /// and, for timed work, a saved timer like a quick cardio log.
    static func plannedExercise(
        for proposal: CoachExerciseProposal,
        item: ExerciseLibraryItem,
        entryID: UUID
    ) -> StrengthPlannedExercise {
        var exercise = StrengthPlannedExercise(item: item)
        exercise.id = entryID
        let reps = proposal.reps.map(String.init) ?? ""
        if let sets = proposal.sets {
            exercise.sets = (0..<sets).map { _ in StrengthPlannedSet(reps: reps) }
        } else if proposal.reps != nil {
            exercise.sets = [StrengthPlannedSet(reps: reps)]
        } else if proposal.durationMinutes != nil {
            exercise.sets = []
        }
        if let minutes = proposal.durationMinutes {
            let seconds = Double(minutes * 60)
            exercise.timer = StrengthExerciseTimer(accumulatedSeconds: seconds, savedDurationSeconds: seconds)
        }
        return exercise
    }
}
