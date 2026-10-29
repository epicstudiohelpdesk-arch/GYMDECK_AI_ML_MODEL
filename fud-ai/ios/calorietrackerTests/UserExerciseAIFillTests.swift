import Foundation
import Testing
@testable import calorietracker

@MainActor
struct UserExerciseAIFillTests {
    private let options = UserExerciseAIFill.Options(
        categories: ["Strength", "Stretching", "Cardio"],
        equipment: ["Barbell", "Body Only", "Cable", "E-Z Curl Bar", "Machine"],
        primaryMuscles: ["Chest", "Lats", "Lower Back", "Triceps"],
        secondaryMuscles: ["Biceps", "Chest", "Shoulders", "Triceps"]
    )

    @Test func promptListsEveryAllowedValue() {
        let prompt = UserExerciseAIFill.prompt(options: options)

        #expect(prompt.contains(#"Allowed categories: ["Strength","Stretching","Cardio"]"#))
        #expect(prompt.contains(#"Allowed equipment: ["Barbell","Body Only","Cable","E-Z Curl Bar","Machine"]"#))
        #expect(prompt.contains(#"Allowed primary muscles: ["Chest","Lats","Lower Back","Triceps"]"#))
        #expect(prompt.contains(#"Allowed secondary muscles: ["Biceps","Chest","Shoulders","Triceps"]"#))
        #expect(prompt.contains(#""primary_muscles""#))
        #expect(prompt.contains(#""instructions""#))
    }

    @Test func promptUsesTheCatalogLists() {
        let catalog = ExerciseLibraryService(exercises: [
            ExerciseLibraryItem(id: "a", name: "Seated Row", category: "strength", rawEquipment: "cable",
                                primaryMuscles: ["middle back"], secondaryMuscles: ["biceps"]),
        ])
        let prompt = UserExerciseAIFill.prompt(options: UserExerciseAIFill.Options(
            categories: catalog.availableCategoryCounts.map(\.category),
            equipment: catalog.availableRawEquipment,
            primaryMuscles: catalog.availablePrimaryMuscles,
            secondaryMuscles: catalog.availableSecondaryMuscles
        ))

        #expect(prompt.contains(#"Allowed categories: ["Strength"]"#))
        #expect(prompt.contains(#"Allowed equipment: ["Cable"]"#))
        #expect(prompt.contains(#"Allowed primary muscles: ["Middle Back"]"#))
        #expect(prompt.contains(#"Allowed secondary muscles: ["Biceps"]"#))
    }

    @Test func parsesAValidReply() throws {
        let reply = #"""
        {"name":"Cable Chest Fly","category":"Strength","equipment":"Cable","primary_muscles":["Chest"],"secondary_muscles":["Shoulders","Triceps"],"instructions":["Stand between the pulleys.","Bring the handles together in front of your chest."]}
        """#

        let suggestion = try UserExerciseAIFill.parse(reply, options: options)

        #expect(suggestion == UserExerciseAIFill.Suggestion(
            name: "Cable Chest Fly",
            category: "Strength",
            equipment: "Cable",
            primaryMuscles: ["Chest"],
            secondaryMuscles: ["Shoulders", "Triceps"],
            instructions: ["Stand between the pulleys.", "Bring the handles together in front of your chest."]
        ))
    }

    @Test func keepsOnlyListedValuesInTheirCatalogSpelling() throws {
        let reply = #"""
        Here is the exercise:
        ```json
        {"name":"  Lat   Pulldown ","category":"Calisthenics","equipment":"smith machine","primary_muscles":["lats","Rear Delts","LATS","lower  back"],"secondary_muscles":["biceps","Lats","Forearms","chest"],"instructions":"1. Grip the bar wide.\n2) Pull it to your upper chest.\n\n- Return slowly."}
        ```
        """#

        let suggestion = try UserExerciseAIFill.parse(reply, options: options)

        #expect(suggestion.name == "Lat Pulldown")
        #expect(suggestion.category == nil)
        #expect(suggestion.equipment == nil)
        #expect(suggestion.primaryMuscles == ["Lats", "Lower Back"])
        // "Lats" is not a secondary option and "Forearms" is not listed at all.
        #expect(suggestion.secondaryMuscles == ["Biceps", "Chest"])
        #expect(suggestion.instructions == ["Grip the bar wide.", "Pull it to your upper chest.", "Return slowly."])
    }

    @Test func secondaryMusclesNeverRepeatPrimaryOnes() throws {
        let reply = #"{"name":"Close-Grip Bench Press","category":"strength","equipment":"barbell","primary_muscles":["Triceps"],"secondary_muscles":["Triceps","Chest"]}"#

        let suggestion = try UserExerciseAIFill.parse(reply, options: options)

        #expect(suggestion.category == "Strength")
        #expect(suggestion.equipment == "Barbell")
        #expect(suggestion.primaryMuscles == ["Triceps"])
        #expect(suggestion.secondaryMuscles == ["Chest"])
        #expect(suggestion.instructions.isEmpty)
    }

    @Test func capsListsAndLengths() throws {
        let steps = (1...12).map { "\"Step \($0)\"" }.joined(separator: ",")
        let longName = String(repeating: "a", count: 200)
        let reply = #"{"name":"\#(longName)","primary_muscles":["Chest","Lats","Lower Back","Triceps"],"instructions":[\#(steps)]}"#

        let suggestion = try UserExerciseAIFill.parse(reply, options: options)

        #expect(suggestion.name.count == UserExerciseAIFill.maxNameLength)
        #expect(suggestion.primaryMuscles == ["Chest", "Lats", "Lower Back"])
        #expect(suggestion.instructions.count == UserExerciseAIFill.maxInstructionSteps)
    }

    @Test(arguments: [
        "I can't tell what exercise this is.",
        "",
        #"{"name":null}"#,
        #"{"name":"   "}"#,
        #"{"category":"Strength","equipment":"Cable"}"#,
        #"{"name":42}"#,
        #"["Bench Press"]"#,
        #"{"name":"Bench Press","#,
    ])
    func rejectsUnusableReplies(_ reply: String) {
        #expect(throws: GeminiService.AnalysisError.self) {
            try UserExerciseAIFill.parse(reply, options: options)
        }
    }

    @Test func applyingASuggestionPrefillsTheDraftWithoutTouchingThePhoto() {
        let photo = Data([0xFF, 0xD8, 0xFF])
        var draft = UserExerciseDraft(
            name: "My exercise",
            instructions: "Old step",
            rawLevel: "Intermediate",
            category: "Cardio",
            rawEquipment: "Machine",
            primaryMuscles: ["Lats"],
            secondaryMuscles: ["Biceps"],
            photoData: photo
        )

        draft.apply(UserExerciseAIFill.Suggestion(
            name: "Chest Press",
            category: "Strength",
            equipment: nil,
            primaryMuscles: ["Chest"],
            secondaryMuscles: [],
            instructions: ["Sit tall.", "Press the handles forward."]
        ))

        #expect(draft.name == "Chest Press")
        #expect(draft.category == "Strength")
        #expect(draft.rawEquipment == "Machine")
        #expect(draft.primaryMuscles == ["Chest"])
        #expect(draft.secondaryMuscles == ["Biceps"])
        #expect(draft.instructions == "Sit tall.\nPress the handles forward.")
        #expect(draft.rawLevel == "Intermediate")
        #expect(draft.photoData == photo)
        #expect(draft.removePhoto == false)
    }

    @Test func emptySuggestionFieldsKeepTheCurrentValues() {
        var draft = UserExerciseDraft(
            name: "Old",
            instructions: "Keep me",
            primaryMuscles: ["Lats"],
            secondaryMuscles: ["Biceps"]
        )

        draft.apply(UserExerciseAIFill.Suggestion(name: "Pull-Up", category: nil, equipment: nil))

        #expect(draft.name == "Pull-Up")
        #expect(draft.category == "Strength")
        #expect(draft.primaryMuscles == ["Lats"])
        #expect(draft.secondaryMuscles == ["Biceps"])
        #expect(draft.instructions == "Keep me")
    }

    @Test func primaryMusclesWithoutUsableSecondaryMusclesKeepTheCurrentSecondaryMuscles() {
        var draft = UserExerciseDraft(
            name: "Old",
            primaryMuscles: ["Lats"],
            secondaryMuscles: ["Biceps", "Chest", "Shoulders"]
        )

        draft.apply(UserExerciseAIFill.Suggestion(
            name: "Chest Press",
            category: nil,
            equipment: nil,
            primaryMuscles: ["Chest"],
            secondaryMuscles: []
        ))

        #expect(draft.primaryMuscles == ["Chest"])
        // Chest is primary now, so it leaves the secondary list; the rest stay.
        #expect(draft.secondaryMuscles == ["Biceps", "Shoulders"])

        // Secondary muscles that only repeat a primary muscle are not usable either.
        draft.apply(UserExerciseAIFill.Suggestion(
            name: "Chest Press",
            category: nil,
            equipment: nil,
            primaryMuscles: ["Triceps"],
            secondaryMuscles: ["Triceps"]
        ))

        #expect(draft.primaryMuscles == ["Triceps"])
        #expect(draft.secondaryMuscles == ["Biceps", "Shoulders"])
    }

    @Test func suggestedSecondaryMusclesReplaceTheCurrentOnes() {
        var draft = UserExerciseDraft(
            name: "Old",
            primaryMuscles: ["Lats"],
            secondaryMuscles: ["Biceps"]
        )

        draft.apply(UserExerciseAIFill.Suggestion(
            name: "Chest Press",
            category: nil,
            equipment: nil,
            primaryMuscles: ["Chest"],
            secondaryMuscles: ["Shoulders", "Triceps"]
        ))

        #expect(draft.primaryMuscles == ["Chest"])
        #expect(draft.secondaryMuscles == ["Shoulders", "Triceps"])
    }
}
