import Foundation
import Testing
@testable import calorietracker

@MainActor
struct WorkoutLibraryFilterTests {
    @Test func fullBodyUsesIndividualCatalogBodyParts() {
        let groups = StrengthWorkoutSplitGroup.selectionGroups(
            for: .fullBody,
            availablePrimaryMuscles: ["Chest", "Biceps"],
            availableSecondaryMuscles: ["Triceps", "Chest"]
        )

        #expect(groups.map(\.title) == ["Biceps", "Chest", "Triceps"])
        #expect(groups.allSatisfy { $0.muscles == [$0.title] })
    }

    @Test func configuredSplitUsesItsTrainingGroups() {
        let groups = StrengthWorkoutSplitGroup.selectionGroups(
            for: .pushPullLegs,
            availablePrimaryMuscles: ["Chest", "Lats", "Quadriceps", "Abdominals"],
            availableSecondaryMuscles: ["Shoulders", "Biceps", "Hamstrings"]
        )

        #expect(groups.map(\.title) == ["Push", "Pull", "Legs", "Core"])
        #expect(groups.first(where: { $0.title == "Push" })?.muscles == ["Chest", "Shoulders"])
        #expect(groups.first(where: { $0.title == "Pull" })?.muscles == ["Biceps", "Lats"])
    }

    @Test func legacyFilterStateDecodesWithoutSplitFields() throws {
        let legacyJSON = #"{"searchText":"bench","levels":["Intermediate"],"rawEquipment":["Barbell"],"primaryMuscles":[],"secondaryMuscles":[],"forces":[],"mechanics":[],"categories":[],"sort":"Name"}"#
        let state = try JSONDecoder().decode(ExerciseFilterState.self, from: Data(legacyJSON.utf8))

        #expect(state.searchText == "bench")
        #expect(state.levels == ["Intermediate"])
        #expect(state.rawEquipment == ["Barbell"])
        #expect(state.splitIdentifier == nil)
        #expect(state.splitGroups.isEmpty)
    }

    @Test func filterStateRoundTripsSplitContext() throws {
        let expected = ExerciseFilterState(
            searchText: "press",
            splitIdentifier: StrengthWorkoutSplit.pushPullLegs.rawValue,
            splitGroups: ["Push"],
            levels: ["Intermediate"],
            sort: .level
        )

        let data = try JSONEncoder().encode(expected)
        let restored = try JSONDecoder().decode(ExerciseFilterState.self, from: data)

        #expect(restored == expected)
    }

    @Test func legacyFilterStateDecodesWithAllSources() throws {
        let legacyJSON = #"{"searchText":"bench","sort":"Name"}"#
        let state = try JSONDecoder().decode(ExerciseFilterState.self, from: Data(legacyJSON.utf8))

        #expect(state.onlyUserExercises == false)
    }

    @Test func filterStateRoundTripsMineSource() throws {
        let expected = ExerciseFilterState(searchText: "press", onlyUserExercises: true)

        let data = try JSONEncoder().encode(expected)
        let restored = try JSONDecoder().decode(ExerciseFilterState.self, from: data)

        #expect(restored.onlyUserExercises)
        #expect(restored == expected)
    }

    @Test func mineSourceFilterKeepsOnlyUserCreatedExercises() {
        let userItem = ExerciseLibraryItem(id: UserExercise.newID(), name: "Landmine Press")
        let catalogItem = ExerciseLibraryItem(id: "Leverage_Chest_Press", name: "Leverage Chest Press")
        let request = ExerciseLibraryFilterRequest(
            levels: [],
            rawEquipment: [],
            primaryMuscles: [],
            secondaryMuscles: [],
            forces: [],
            mechanics: [],
            categories: [],
            sort: .name,
            searchText: "press",
            splitMuscles: [],
            onlyUserExercises: true
        )

        let results = ExerciseLibraryFilterEngine.filter(exercises: [catalogItem, userItem], request: request)

        #expect(results.map(\.id) == [userItem.id])
    }

    @Test func pickerSourcesSelectDatasetSavedAndUserExercises() {
        let userID = UserExercise.newID()
        let savedIDs: Set<String> = ["Barbell_Squat"]

        #expect(WorkoutLogPickerSource.mine.includes(itemID: userID, savedIDs: savedIDs))
        #expect(!WorkoutLogPickerSource.mine.includes(itemID: "Barbell_Squat", savedIDs: savedIDs))
        #expect(WorkoutLogPickerSource.saved.includes(itemID: "Barbell_Squat", savedIDs: savedIDs))
        #expect(!WorkoutLogPickerSource.saved.includes(itemID: userID, savedIDs: savedIDs))
        #expect(WorkoutLogPickerSource.dataset.includes(itemID: userID, savedIDs: savedIDs))
        // The stored picker source keeps its raw value, so older installs restore it unchanged.
        #expect(WorkoutLogPickerSource(rawValue: "Mine") == .mine)
        #expect(WorkoutLogPickerSource(rawValue: "Saved") == .saved)
    }
}
