import Foundation
import Testing
@testable import calorietracker

@MainActor
struct CoachExerciseProposalTests {
    // MARK: - Tool availability

    @Test func proposalToolsAreOfferedOnlyToCoachChatWithWorkoutAccess() throws {
        let withoutCards = CoachTools(weights: [], bodyFats: [], foods: [], workoutAccessEnabled: true, exerciseLibrary: ProposalFixture.library)
        #expect(!withoutCards.availableToolNames.contains("propose_custom_exercise"))
        #expect(!withoutCards.availableToolNames.contains("propose_add_exercise_to_day"))
        let unavailable = try ProposalFixture.json(withoutCards.execute(name: "propose_add_exercise_to_day", arguments: ["catalog_id": "Leg_Press"]))
        #expect(unavailable["error"] as? String == "Proposals are only available in Coach chat.")

        let collector = CoachExerciseProposalCollector()
        let gated = CoachTools(weights: [], bodyFats: [], foods: [], workoutAccessEnabled: false, exerciseLibrary: ProposalFixture.library, proposals: collector)
        #expect(!gated.availableToolNames.contains("propose_add_exercise_to_day"))
        let blocked = try ProposalFixture.json(gated.execute(name: "propose_add_exercise_to_day", arguments: ["catalog_id": "Leg_Press"]))
        #expect(blocked["error"] as? String == "Workout access is disabled.")
        #expect(collector.proposals.isEmpty)

        let chat = ProposalFixture.tools(collector)
        #expect(chat.availableToolNames.suffix(2) == ["propose_custom_exercise", "propose_add_exercise_to_day"])
        // The voice assistant offers the static workout list, which has no confirmation card.
        #expect(!CoachTools.workoutToolNames.contains("propose_add_exercise_to_day"))
        #expect(CoachTools.parameterSchema(for: "propose_custom_exercise")["required"] as? [String] == ["name", "primary_muscles"])
        #expect(CoachTools.parameterSchema(for: "propose_add_exercise_to_day")["required"] as? [String] == ["catalog_id"])
        #expect(CoachTools.toolDescriptions["propose_custom_exercise"]?.contains("does NOT save anything") == true)
        #expect(CoachTools.toolDescriptions["propose_add_exercise_to_day"]?.contains("does NOT save anything") == true)
    }

    // MARK: - Validation

    @Test func customExerciseProposalUsesTheLibraryVocabulary() throws {
        let collector = CoachExerciseProposalCollector()
        let tools = ProposalFixture.tools(collector)
        let result = try ProposalFixture.json(tools.execute(name: "propose_custom_exercise", arguments: [
            "name": "  Iso-Lateral Row  ",
            "equipment": "Machine",
            "primary_muscles": ["middle back", "LATS", "lats"],
            "secondary_muscles": ["biceps", "lats"],
            "instructions": "Sit tall.\n\n Pull both handles. ",
        ]))
        #expect(result["status"] as? String == "pending_user_confirmation")
        #expect(result["saved"] as? Bool == false)
        #expect((result["note"] as? String)?.contains("Nothing was saved") == true)
        let proposal = try #require(collector.proposals.first)
        #expect(result["proposal_id"] as? String == proposal.id)
        #expect(proposal.kind == .customExercise)
        #expect(proposal.status == .pending)
        #expect(proposal.name == "Iso-Lateral Row")
        #expect(proposal.category == "Strength")
        #expect(proposal.equipment == "Machine")
        #expect(proposal.primaryMuscles == ["Middle Back", "Lats"])
        #expect(proposal.secondaryMuscles == ["Biceps"])
        #expect(proposal.instructions == ["Sit tall.", "Pull both handles."])
        #expect(UserExercise.isUserExercise(proposal.itemID))

        let commaSeparated = try ProposalFixture.json(tools.execute(name: "propose_custom_exercise", arguments: [
            "name": "Belt Squat", "category": "olympic weightlifting", "equipment": "e-z curl bar",
            "primary_muscles": "quadriceps, glutes",
        ]))
        #expect(commaSeparated["error"] == nil)
        #expect(collector.proposals.last?.category == "Olympic Weightlifting")
        #expect(collector.proposals.last?.equipment == "E-Z Curl Bar")
        #expect(collector.proposals.last?.primaryMuscles == ["Quadriceps", "Glutes"])
    }

    @Test func proposalVocabularyMatchesTheBundledCatalog() throws {
        let library = FreeExerciseDBLoader.load()
        try #require(!library.isEmpty)
        #expect(Set(CoachTools.libraryCategories) == Set(library.map { $0.category.lowercased() }))

        // Proposed values use the library's own title case, so the exercise editor's pickers match them.
        let collector = CoachExerciseProposalCollector()
        _ = ProposalFixture.tools(collector).execute(name: "propose_custom_exercise", arguments: [
            "name": "Coach Vocabulary Check", "category": "olympic weightlifting", "equipment": "e-z curl bar",
            "primary_muscles": CoachTools.libraryMuscles,
        ])
        let proposal = try #require(collector.proposals.first)
        #expect(Set(proposal.primaryMuscles) == Set(library.flatMap { $0.primaryMuscles + $0.secondaryMuscles }))
        #expect(library.contains { $0.category == proposal.category })
        #expect(library.contains { $0.rawEquipment == proposal.equipment })
    }

    @Test func invalidCustomExerciseProposalsAreRejectedWithoutACard() throws {
        let collector = CoachExerciseProposalCollector()
        let tools = ProposalFixture.tools(collector)
        func error(_ arguments: [String: Any]) throws -> String? {
            try ProposalFixture.json(tools.execute(name: "propose_custom_exercise", arguments: arguments))["error"] as? String
        }
        #expect(try error(["primary_muscles": ["chest"]]) == "name is required.")
        #expect(try error(["name": String(repeating: "x", count: 81), "primary_muscles": ["chest"]]) == "name must be at most 80 characters.")
        #expect(try error(["name": "Cable Fly", "primary_muscles": []])?.hasPrefix("primary_muscles needs at least one of:") == true)
        #expect(try error(["name": "Cable Fly", "primary_muscles": ["pecs"]])?.hasPrefix("Unknown muscle \"pecs\" in primary_muscles.") == true)
        #expect(try error(["name": "Cable Fly", "primary_muscles": ["chest"], "equipment": "smith machine"])?.hasPrefix("equipment must be one of:") == true)
        #expect(try error(["name": "Cable Fly", "primary_muscles": ["chest"], "category": "bodybuilding"])?.hasPrefix("category must be one of:") == true)
        // An exercise the library already has is added, not duplicated.
        #expect(try error(["name": "leg press", "primary_muscles": ["quadriceps"]])?.contains("catalog_id Leg_Press") == true)
        #expect(collector.proposals.isEmpty)
    }

    @Test func addToDayProposalChecksTheExerciseDateAndAmounts() throws {
        let collector = CoachExerciseProposalCollector()
        let tools = ProposalFixture.tools(collector)
        func error(_ arguments: [String: Any]) throws -> String? {
            try ProposalFixture.json(tools.execute(name: "propose_add_exercise_to_day", arguments: arguments))["error"] as? String
        }
        #expect(try error([:]) == "catalog_id is required.")
        #expect(try error(["catalog_id": "Zercher_Squat"])?.hasPrefix("Unknown catalog_id \"Zercher_Squat\".") == true)
        #expect(try error(["catalog_id": "Leg_Press", "date": "next week"]) == "date must be an ISO date yyyy-MM-dd.")
        #expect(try error(["catalog_id": "Leg_Press", "date": ProposalFixture.isoDate(days: 400)]) == "date must be within one year of today.")
        #expect(try error(["catalog_id": "Leg_Press", "sets": 0]) == "sets must be a whole number from 1 to 12.")
        #expect(try error(["catalog_id": "Leg_Press", "sets": 13]) == "sets must be a whole number from 1 to 12.")
        #expect(try error(["catalog_id": "Leg_Press", "reps": 2.5]) == "reps must be a whole number from 1 to 999.")
        #expect(try error(["catalog_id": "Leg_Press", "reps": true]) == "reps must be a whole number from 1 to 999.")
        #expect(try error(["catalog_id": "Leg_Press", "date": ProposalFixture.isoDate(days: 1), "reps": 10])?.hasPrefix("reps and duration_minutes record performed work") == true)
        #expect(try error(["catalog_id": "Running_Treadmill", "sets": 3]) == "Running, Treadmill is cardio: use duration_minutes instead of sets or reps.")
        #expect(collector.proposals.isEmpty)

        let today = try ProposalFixture.json(tools.execute(name: "propose_add_exercise_to_day", arguments: [
            "catalog_id": "Leg_Press", "sets": "3", "reps": 10.0,
        ]))
        let details = try #require(today["proposal"] as? [String: Any])
        #expect(details["date"] as? String == ProposalFixture.isoDate(days: 0))
        #expect(details["sets"] as? Int == 3)
        #expect(details["reps"] as? Int == 10)
        #expect(details["already_in_diary_that_day"] as? Bool == true)

        let planned = try ProposalFixture.json(tools.execute(name: "propose_add_exercise_to_day", arguments: [
            "catalog_id": "user_exercise_hammer", "date": ProposalFixture.isoDate(days: 3), "sets": 4,
        ]))
        #expect(planned["error"] == nil)
        let cardio = try ProposalFixture.json(tools.execute(name: "propose_add_exercise_to_day", arguments: [
            "catalog_id": "Running_Treadmill", "date": ProposalFixture.isoDate(days: -2), "duration_minutes": 25,
        ]))
        #expect(cardio["error"] == nil)
        #expect(collector.proposals.map(\.name) == ["Leg Press", "Hammer Strength Chest Press", "Running, Treadmill"])
        #expect(collector.proposals.allSatisfy { $0.entryID != nil && $0.status == .pending })
    }

    @Test func repeatedProposalsShareOneCardAndAReplyIsCapped() throws {
        let collector = CoachExerciseProposalCollector()
        let tools = ProposalFixture.tools(collector)
        let arguments: [String: Any] = ["catalog_id": "Leg_Press", "sets": 3]
        let first = try ProposalFixture.json(tools.execute(name: "propose_add_exercise_to_day", arguments: arguments))
        let again = try ProposalFixture.json(tools.execute(name: "propose_add_exercise_to_day", arguments: arguments))
        #expect(first["proposal_id"] as? String == again["proposal_id"] as? String)
        #expect(collector.proposals.count == 1)

        for sets in 1...CoachExerciseProposalCollector.maxProposals {
            _ = tools.execute(name: "propose_add_exercise_to_day", arguments: ["catalog_id": "Leg_Press", "sets": sets, "reps": 5])
        }
        #expect(collector.proposals.count == CoachExerciseProposalCollector.maxProposals)
        let overflow = try ProposalFixture.json(tools.execute(name: "propose_custom_exercise", arguments: ["name": "Cable Fly", "primary_muscles": ["chest"]]))
        #expect((overflow["error"] as? String)?.contains("already has 10 proposals") == true)

        collector.reset()
        #expect(collector.proposals.isEmpty)
    }

    @Test func proposedDaysMatchTheDiaryUnderEveryPhoneCalendar() throws {
        let collector = CoachExerciseProposalCollector()
        let tools = ProposalFixture.tools(collector)
        let today = Calendar.current.startOfDay(for: Date())
        _ = tools.execute(name: "propose_add_exercise_to_day", arguments: [
            "catalog_id": "Leg_Press", "date": ProposalFixture.isoDate(days: 0), "sets": 3,
        ])
        let proposal = try #require(collector.proposals.first)
        #expect(proposal.dateKey == ProposalFixture.isoDate(days: 0))
        #expect(proposal.day == today)

        // The diary keys days in the phone's calendar, so a Thai, Japanese or Saudi phone uses a
        // different year than the Gregorian date Coach sends. Both must name the same day.
        for identifier in [Calendar.Identifier.buddhist, .japanese, .islamicUmmAlQura] {
            var calendar = Calendar(identifier: identifier)
            calendar.timeZone = .current
            let diaryKey = StrengthWorkoutStore.dateKey(for: today, calendar: calendar)
            #expect(diaryKey != proposal.dateKey)
            #expect(proposal.diaryDateKey(calendar: calendar) == diaryKey)
            #expect(StrengthWorkoutStore.date(for: diaryKey, calendar: calendar) == proposal.day)
        }
    }

    // MARK: - Nothing is written until the user confirms

    @Test func onlyTheAddActionWritesToTheDiaryOrLibrary() throws {
        try ProposalFixture.withStore { store, defaults in
            let collector = CoachExerciseProposalCollector()
            let tools = ProposalFixture.tools(collector, library: store.exerciseLibrary.exercises)
            let before = defaults.data(forKey: ProposalFixture.workoutKey)

            _ = tools.execute(name: "propose_custom_exercise", arguments: ["name": "Coach Test Row", "primary_muscles": ["lats"]])
            _ = tools.execute(name: "propose_add_exercise_to_day", arguments: ["catalog_id": "Leg_Press", "sets": 3, "reps": 10])
            #expect(collector.proposals.count == 2)
            #expect(store.dayPlans.isEmpty)
            #expect(store.userExercises.isEmpty)
            #expect(defaults.data(forKey: ProposalFixture.workoutKey) == before)

            // Dismissing never runs the write; tapping Add on the other card does.
            let chatStore = ChatStore(defaults: defaults)
            let message = ChatMessage(role: .assistant, content: "Two ideas.", exerciseProposals: collector.proposals)
            chatStore.append(message)
            let custom = try #require(collector.proposals.first)
            let addToDay = try #require(collector.proposals.last)
            chatStore.dismissExerciseProposal(custom.id, in: message.id)
            #expect(store.userExercises.isEmpty)
            #expect(defaults.data(forKey: ProposalFixture.workoutKey) == before)

            try chatStore.addExerciseProposal(addToDay.id, in: message.id) { pending in
                try CoachExerciseProposalApplier.apply(pending, to: store)
            }
            let today = try #require(StrengthWorkoutStore.date(for: ProposalFixture.dateKey(days: 0)))
            let entryID = try #require(addToDay.entryID)
            #expect(store.exercises(for: today).map(\.id) == [entryID])
            #expect(store.userExercises.isEmpty)
        }
    }

    // MARK: - Applying

    @Test func applyingAnAddToDayProposalTwiceAddsOneEntry() throws {
        try ProposalFixture.withStore { store, _ in
            let collector = CoachExerciseProposalCollector()
            let tools = ProposalFixture.tools(collector, library: store.exerciseLibrary.exercises)
            _ = tools.execute(name: "propose_add_exercise_to_day", arguments: ["catalog_id": "Leg_Press", "sets": 3, "reps": 10])
            let proposal = try #require(collector.proposals.first)
            let today = try #require(StrengthWorkoutStore.date(for: ProposalFixture.dateKey(days: 0)))

            try CoachExerciseProposalApplier.apply(proposal, to: store)
            try CoachExerciseProposalApplier.apply(proposal, to: store)

            let entries = store.exercises(for: today)
            #expect(entries.count == 1)
            #expect(entries[0].id == proposal.entryID)
            #expect(entries[0].itemID == "Leg_Press")
            #expect(entries[0].sets.map(\.reps) == ["10", "10", "10"])
            #expect(entries[0].timer == nil)
        }
    }

    @Test func applyingATimedProposalSavesTheDurationWithoutSets() throws {
        try ProposalFixture.withStore { store, _ in
            let collector = CoachExerciseProposalCollector()
            let tools = ProposalFixture.tools(collector, library: store.exerciseLibrary.exercises)
            _ = tools.execute(name: "propose_add_exercise_to_day", arguments: [
                "catalog_id": "Running_Treadmill", "date": ProposalFixture.isoDate(days: -1), "duration_minutes": 25,
            ])
            let proposal = try #require(collector.proposals.first)
            try CoachExerciseProposalApplier.apply(proposal, to: store)

            let day = try #require(StrengthWorkoutStore.date(for: ProposalFixture.dateKey(days: -1)))
            let entry = try #require(store.exercises(for: day).first)
            #expect(entry.sets.isEmpty)
            #expect(entry.timer?.savedDurationSeconds == 1_500)
            #expect(entry.timer?.isSaved == true)
        }
    }

    @Test func applyingACustomExerciseProposalTwiceCreatesOneExercise() throws {
        try ProposalFixture.withStore { store, _ in
            let collector = CoachExerciseProposalCollector()
            let tools = ProposalFixture.tools(collector, library: store.exerciseLibrary.exercises)
            _ = tools.execute(name: "propose_custom_exercise", arguments: [
                "name": "Iso-Lateral Row", "equipment": "machine",
                "primary_muscles": ["middle back"], "secondary_muscles": ["biceps"], "instructions": "Pull.",
            ])
            let proposal = try #require(collector.proposals.first)

            try CoachExerciseProposalApplier.apply(proposal, to: store)
            try CoachExerciseProposalApplier.apply(proposal, to: store)

            #expect(store.userExercises.count == 1)
            let item = try #require(store.exerciseLibrary.exercises.first { $0.id == proposal.itemID })
            #expect(item.name == "Iso-Lateral Row")
            #expect(item.rawEquipment == "Machine")
            #expect(item.primaryMuscles == ["Middle Back"])
            #expect(item.secondaryMuscles == ["Biceps"])
            #expect(item.instructions == ["Pull."])
        }
    }

    @Test func aCustomExerciseNameSavedWhileTheCardWaitedIsRefused() throws {
        try ProposalFixture.withStore { store, defaults in
            // Each reply proposes against the library as it was, so two cards can share a name.
            @MainActor func propose(_ name: String) throws -> CoachExerciseProposal {
                let collector = CoachExerciseProposalCollector()
                _ = ProposalFixture.tools(collector, library: store.exerciseLibrary.exercises).execute(
                    name: "propose_custom_exercise", arguments: ["name": name, "primary_muscles": ["middle back"]]
                )
                return try #require(collector.proposals.first)
            }
            let earlier = try propose("Iso-Lateral Row")
            let later = try propose("Iso-Lateral Row")
            #expect(earlier.itemID != later.itemID)

            try CoachExerciseProposalApplier.apply(later, to: store)
            #expect(throws: CoachExerciseProposalApplier.ApplyError.nameTaken) {
                try CoachExerciseProposalApplier.apply(earlier, to: store)
            }
            // The card that saved still retries as a no-op.
            try CoachExerciseProposalApplier.apply(later, to: store)
            #expect(store.userExercises.count == 1)

            // An exercise the user made by hand, in another letter case, also blocks a waiting
            // card, and that card stays pending so the user can still dismiss it.
            let waiting = try propose("Cable Pullover")
            #expect(store.saveUserExercise(UserExerciseDraft(name: " cable pullover", primaryMuscles: ["Lats"])) != nil)
            let chatStore = ChatStore(defaults: defaults)
            let message = ChatMessage(role: .assistant, content: "Try this.", exerciseProposals: [waiting])
            chatStore.append(message)
            #expect(throws: CoachExerciseProposalApplier.ApplyError.nameTaken) {
                try chatStore.addExerciseProposal(waiting.id, in: message.id) { pending in
                    try CoachExerciseProposalApplier.apply(pending, to: store)
                }
            }
            #expect(chatStore.exerciseProposal(waiting.id, in: message.id)?.status == .pending)
            #expect(store.userExercises.count == 2)
            #expect(store.userExerciseTemplate(for: waiting.itemID) == nil)
        }
    }

    @Test func applyingAProposalForADeletedExerciseFailsWithoutWriting() throws {
        try ProposalFixture.withStore { store, _ in
            let collector = CoachExerciseProposalCollector()
            let tools = ProposalFixture.tools(collector)
            _ = tools.execute(name: "propose_add_exercise_to_day", arguments: ["catalog_id": "user_exercise_hammer"])
            let proposal = try #require(collector.proposals.first)

            #expect(throws: CoachExerciseProposalApplier.ApplyError.exerciseMissing) {
                try CoachExerciseProposalApplier.apply(proposal, to: store)
            }
            #expect(store.dayPlans.isEmpty)
        }
    }

    // MARK: - Chat cards

    @Test func chatStoreAppliesAPendingProposalOnlyOnce() throws {
        try ProposalFixture.withStore { _, defaults in
            let proposal = ProposalFixture.proposal(id: "p1")
            let message = ChatMessage(role: .assistant, content: "Here you go.", exerciseProposals: [proposal, ProposalFixture.proposal(id: "p2")])
            let chatStore = ChatStore(defaults: defaults)
            chatStore.append(message)

            struct Refused: Error {}
            var applied = 0
            #expect(throws: Refused.self) {
                try chatStore.addExerciseProposal("p1", in: message.id) { _ in throw Refused() }
            }
            #expect(chatStore.exerciseProposal("p1", in: message.id)?.status == .pending)

            chatStore.addExerciseProposal("p1", in: message.id) { _ in applied += 1 }
            chatStore.addExerciseProposal("p1", in: message.id) { _ in applied += 1 }
            chatStore.dismissExerciseProposal("p1", in: message.id)
            #expect(applied == 1)
            #expect(chatStore.exerciseProposal("p1", in: message.id)?.status == .added)

            chatStore.dismissExerciseProposal("p2", in: message.id)
            chatStore.addExerciseProposal("p2", in: message.id) { _ in applied += 1 }
            #expect(applied == 1)
            #expect(chatStore.exerciseProposal("p2", in: message.id)?.status == .dismissed)

            // Outcomes survive a relaunch, and the model hears about them on the next turn.
            let reloaded = ChatStore(defaults: defaults)
            let saved = try #require(reloaded.messages.first)
            #expect(saved.exerciseProposals?.map(\.status) == [.added, .dismissed])
            #expect(saved.contextContent.contains("[Coach proposed adding \"Leg Press\" (catalog_id Leg_Press) to the workout diary on 2026-10-17: added by the user]"))
            #expect(saved.contextContent.contains("dismissed by the user"))
        }
    }

    @Test func messagesSavedBeforeProposalsStillDecode() throws {
        let legacy = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"assistant","content":"Hi","timestamp":0}]"#
        let decoded = try JSONDecoder().decode([ChatMessage].self, from: Data(legacy.utf8))
        #expect(decoded.first?.exerciseProposals == nil)
        #expect(decoded.first?.contextContent == "Hi")
    }
}

@MainActor
private enum ProposalFixture {
    static let workoutKey = "test.coach.proposals.workouts"

    static let library: [ExerciseLibraryItem] = [
        ExerciseLibraryItem(id: "Leg_Press", name: "Leg Press", category: "strength", rawEquipment: "machine", primaryMuscles: ["quadriceps"]),
        ExerciseLibraryItem(id: "Running_Treadmill", name: "Running, Treadmill", category: "cardio", rawEquipment: "machine", primaryMuscles: ["quadriceps"]),
        ExerciseLibraryItem(id: "user_exercise_hammer", name: "Hammer Strength Chest Press", category: "strength", rawEquipment: "machine", primaryMuscles: ["chest"]),
    ]

    static func tools(_ collector: CoachExerciseProposalCollector, library: [ExerciseLibraryItem]? = nil) -> CoachTools {
        CoachTools(
            weights: [], bodyFats: [], foods: [],
            workoutPlans: [StrengthWorkoutDayPlan(dateKey: dateKey(days: 0), exercises: [StrengthPlannedExercise(item: Self.library[0])])],
            workoutAccessEnabled: true,
            exerciseLibrary: library ?? Self.library,
            proposals: collector
        )
    }

    static func proposal(id: String) -> CoachExerciseProposal {
        CoachExerciseProposal(
            id: id, kind: .addToDay, name: "Leg Press", itemID: "Leg_Press",
            dateKey: "2026-10-17", sets: 3, entryID: UUID()
        )
    }

    /// The diary's key for a day relative to today.
    static func dateKey(days: Int) -> String {
        StrengthWorkoutStore.dateKey(for: day(days))
    }

    /// The Gregorian ISO date Coach sends for a day relative to today.
    static func isoDate(days: Int) -> String {
        CoachExerciseProposal.dateKey(for: day(days))
    }

    private static func day(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    }

    /// An empty workout store in its own defaults suite. Its library is the bundled catalog,
    /// which includes Leg_Press and Running_Treadmill, but not the fixture's custom exercise.
    static func withStore(_ body: (StrengthWorkoutStore, UserDefaults) throws -> Void) throws {
        let suite = "CoachExerciseProposalTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(StrengthWorkoutStore(defaults: defaults, storageKey: workoutKey), defaults)
    }

    static func json(_ value: String) throws -> [String: Any] {
        let data = try #require(value.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
