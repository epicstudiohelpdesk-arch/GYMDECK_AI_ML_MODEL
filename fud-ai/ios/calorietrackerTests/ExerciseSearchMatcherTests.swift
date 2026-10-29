import Foundation
import Testing
@testable import calorietracker

@Suite struct ExerciseSearchMatcherTests {
    private let tricepsPushdown = ExerciseLibraryItem(
        id: "Triceps_Pushdown",
        name: "Triceps Pushdown",
        rawLevel: "Beginner",
        force: "Push",
        mechanic: "Isolation",
        category: "Strength",
        rawEquipment: "Cable",
        primaryMuscles: ["Triceps"],
        instructions: ["Attach a bar to a high pulley."]
    )

    @Test func contiguousQueryMatches() {
        #expect(ExerciseSearchMatcher.matches(tricepsPushdown, query: "triceps pushdown"))
    }

    @Test func tokenizedNonContiguousQueryMatches() {
        #expect(ExerciseSearchMatcher.matches(tricepsPushdown, query: "triceps cable pushdown"))
    }

    @Test func aliasQueryMatches() {
        #expect(ExerciseSearchMatcher.relevance(of: tricepsPushdown, query: "cable pushdown") == 0)
    }

    @Test func missingTokenFails() {
        #expect(!ExerciseSearchMatcher.matches(tricepsPushdown, query: "triceps rope"))
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(ExerciseSearchMatcher.relevance(of: tricepsPushdown, query: "   ") == 0)
    }

    @Test func wordPrefixMatchesPluralMuscleNames() {
        #expect(ExerciseSearchMatcher.matches(tricepsPushdown, query: "tricep"))
    }

    @Test func instructionsAreNotSearched() {
        #expect(!ExerciseSearchMatcher.matches(tricepsPushdown, query: "pulley"))
    }

    @Test func tokensOnlyMatchAtWordStarts() {
        #expect(!ExerciseSearchMatcher.matches(tricepsPushdown, query: "down"))
    }

    @Test func hyphenatedAndJoinedSpellingsMatchExactly() {
        let pushUp = ExerciseLibraryItem(id: "Push_Up", name: "Push-Up", category: "Strength")
        #expect(ExerciseSearchMatcher.relevance(of: pushUp, query: "pushup") == 0)
        #expect(ExerciseSearchMatcher.relevance(of: pushUp, query: "push up") == 0)
    }

    @Test func relevanceTiersOrderExactPrefixPhraseAndWords() {
        let exact = ExerciseLibraryItem(id: "a", name: "Chest Press")
        let prefix = ExerciseLibraryItem(id: "b", name: "Chest Press Machine")
        let phrase = ExerciseLibraryItem(id: "c", name: "Cable Chest Press")
        let words = ExerciseLibraryItem(id: "d", name: "Press Against Chest Wall")

        #expect(ExerciseSearchMatcher.relevance(of: exact, query: "Chest press") == 0)
        #expect(ExerciseSearchMatcher.relevance(of: prefix, query: "Chest press") == 1)
        #expect(ExerciseSearchMatcher.relevance(of: phrase, query: "Chest press") == 2)
        #expect(ExerciseSearchMatcher.relevance(of: words, query: "Chest press") == 3)
    }

    /// #497: muscle, equipment, and category values do not stand in for missing name words.
    @Test func freeTextQueriesNeedEveryWordInTheName() {
        let neckPress = ExerciseLibraryItem(id: "Neck_Press", name: "Neck Press", rawEquipment: "barbell", primaryMuscles: ["chest"])

        #expect(ExerciseSearchMatcher.relevance(of: neckPress, query: "Chest press") == nil)
        #expect(ExerciseSearchMatcher.relevance(of: neckPress, query: "barbell press") == nil)
        #expect(ExerciseSearchMatcher.relevance(of: tricepsPushdown, query: "cable triceps") == nil)
    }

    @Test func queryNamingAMuscleEquipmentOrCategoryRanksAfterNameMatches() {
        let neckPress = ExerciseLibraryItem(id: "a", name: "Neck Press", primaryMuscles: ["chest"])
        let superman = ExerciseLibraryItem(id: "b", name: "Superman", primaryMuscles: ["lower back"])
        let chestPush = ExerciseLibraryItem(id: "c", name: "Chest Push", primaryMuscles: ["chest"])

        #expect(ExerciseSearchMatcher.relevance(of: neckPress, query: "chest") == 4)
        #expect(ExerciseSearchMatcher.relevance(of: tricepsPushdown, query: "cable") == 4)
        #expect(ExerciseSearchMatcher.relevance(of: tricepsPushdown, query: "strength") == 4)
        #expect(ExerciseSearchMatcher.relevance(of: superman, query: "lower back") == 4)
        #expect(ExerciseSearchMatcher.relevance(of: chestPush, query: "chest") == 1)
    }

    /// Shorthand that used to match only through instructions text ("tighten your abs").
    @Test func gymShorthandFindsTheMuscleGroup() {
        let abRoller = ExerciseLibraryItem(id: "a", name: "Ab Roller", primaryMuscles: ["abdominals"])
        let crunches = ExerciseLibraryItem(id: "b", name: "Crunches", primaryMuscles: ["abdominals"])
        let butterfly = ExerciseLibraryItem(id: "c", name: "Butterfly", primaryMuscles: ["chest"])
        let arnoldPress = ExerciseLibraryItem(id: "d", name: "Arnold Dumbbell Press", primaryMuscles: ["shoulders"])
        let rearDeltRow = ExerciseLibraryItem(id: "e", name: "Barbell Rear Delt Row", primaryMuscles: ["shoulders"])

        #expect(ExerciseSearchMatcher.relevance(of: abRoller, query: "abs") == 3)
        #expect(ExerciseSearchMatcher.relevance(of: crunches, query: "abs") == 4)
        #expect(ExerciseSearchMatcher.relevance(of: butterfly, query: "pec") == 4)
        #expect(ExerciseSearchMatcher.relevance(of: arnoldPress, query: "delts") == 4)
        #expect(ExerciseSearchMatcher.relevance(of: rearDeltRow, query: "delts") == 3)
        #expect(ExerciseSearchMatcher.relevance(of: butterfly, query: "abs") == nil)
    }

    @Test func pluralQueriesMatchSingularNameWords() {
        #expect(ExerciseSearchMatcher.relevance(of: ExerciseLibraryItem(id: "a", name: "Barbell Curl"), query: "curls") == 3)
        #expect(ExerciseSearchMatcher.relevance(of: ExerciseLibraryItem(id: "b", name: "Bench Press"), query: "presses") == 3)
        #expect(ExerciseSearchMatcher.relevance(of: ExerciseLibraryItem(id: "c", name: "Dumbbell Tricep Extension"), query: "triceps extension") == 3)
        #expect(ExerciseSearchMatcher.relevance(of: ExerciseLibraryItem(id: "d", name: "Abductor"), query: "abs") == nil)
    }

    @Test func nonASCIIQueriesMatchInsideUnspacedNames() {
        let item = ExerciseLibraryItem(id: "user_exercise_ja", name: "ベンチプレス")
        #expect(ExerciseSearchMatcher.matches(item, query: "プレス"))
    }

    /// Reporter's example (#497): "Chest press" returned unrelated presses whose
    /// instructions merely mention the chest, in alphabetical order. Only exercises
    /// with both words in the name should be listed.
    @Test func chestPressListsOnlyExercisesNamedChestPress() {
        let items = [
            ExerciseLibraryItem(
                id: "Alternating_Cable_Shoulder_Press",
                name: "Alternating Cable Shoulder Press",
                rawEquipment: "cable",
                primaryMuscles: ["shoulders"],
                secondaryMuscles: ["triceps"],
                instructions: ["Keeping your head and chest up, extend through the elbow to press one side directly over head."]
            ),
            ExerciseLibraryItem(
                id: "Barbell_Bench_Press_-_Medium_Grip",
                name: "Barbell Bench Press - Medium Grip",
                rawEquipment: "barbell",
                primaryMuscles: ["chest"],
                secondaryMuscles: ["shoulders", "triceps"]
            ),
            ExerciseLibraryItem(
                id: "Neck_Press",
                name: "Neck Press",
                rawEquipment: "barbell",
                primaryMuscles: ["chest"]
            ),
            ExerciseLibraryItem(
                id: "Leverage_Chest_Press",
                name: "Leverage Chest Press",
                rawEquipment: "machine",
                primaryMuscles: ["chest"]
            ),
            ExerciseLibraryItem(
                id: "Cable_Chest_Press",
                name: "Cable Chest Press",
                rawEquipment: "cable",
                primaryMuscles: ["chest"]
            ),
        ]
        let service = ExerciseLibraryService(exercises: items)

        let results = service.filtered(
            levels: [],
            rawEquipment: [],
            primaryMuscles: [],
            secondaryMuscles: [],
            forces: [],
            mechanics: [],
            categories: [],
            sort: .name,
            searchText: "Chest press"
        )

        #expect(results.map(\.name) == [
            "Cable Chest Press",
            "Leverage Chest Press",
        ])
    }

    @Test func emptyQueryKeepsChosenSortOrder() {
        let service = ExerciseLibraryService(exercises: [
            ExerciseLibraryItem(id: "b", name: "Bench Press"),
            ExerciseLibraryItem(id: "a", name: "Air Bike"),
        ])

        let results = service.filtered(
            levels: [],
            rawEquipment: [],
            primaryMuscles: [],
            secondaryMuscles: [],
            forces: [],
            mechanics: [],
            categories: [],
            sort: .name,
            searchText: ""
        )

        #expect(results.map(\.name) == ["Air Bike", "Bench Press"])
    }

    @Test func userExerciseNamesAreSearchable() {
        var draft = UserExerciseDraft()
        draft.name = "Landmine Chest Press"
        let item = draft.libraryItem(id: UserExercise.newID(), imagePaths: [])

        #expect(ExerciseSearchMatcher.relevance(of: item, query: "chest press") == 2)
        #expect(ExerciseSearchMatcher.relevance(of: item, query: "landmine") == 1)
    }

    @Test func bundledCatalogChestPressListsOnlyChestPresses() throws {
        let results = try bundledResults(for: "Chest press")

        #expect(results.count >= 6)
        #expect(results.allSatisfy { item in
            let name = item.name.lowercased()
            return name.contains("chest") && name.contains("press")
        })
        #expect(results.first?.name == "Cable Chest Press")
    }

    @Test func bundledCatalogGymShorthandFindsTheMuscleGroup() throws {
        let abs = try bundledResults(for: "abs").map(\.name)
        #expect(abs.first == "Ab Crunch Machine")
        #expect(abs.contains("Ab Roller"))
        #expect(abs.contains("Crunches"))

        let pec = try bundledResults(for: "pec").map(\.name)
        #expect(pec.contains("Barbell Bench Press - Medium Grip"))
        #expect(pec.contains("Butterfly"))

        let delts = try bundledResults(for: "delts").map(\.name)
        #expect(delts.first == "Barbell Rear Delt Row")
        #expect(delts.contains("Arnold Dumbbell Press"))
    }

    private func bundledResults(for searchText: String) throws -> [ExerciseLibraryItem] {
        let service = ExerciseLibraryService.shared
        try #require(!service.exercises.isEmpty)

        return service.filtered(
            levels: [],
            rawEquipment: [],
            primaryMuscles: [],
            secondaryMuscles: [],
            forces: [],
            mechanics: [],
            categories: [],
            sort: .name,
            searchText: searchText
        )
    }
}
