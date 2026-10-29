import Foundation
import Testing
@testable import calorietracker

/// "This recipe makes N servings" in the review and edit sheets (#458).
struct RecipeServingsTests {

    @Test func splitDividesTheWholeRecipeIntoOneSelectedServing() {
        let split = RecipeServings.split(options: [], totalGrams: 2000, servings: 5)

        #expect(split.servings == 5)
        #expect(split.options.count == 1)
        #expect(split.options.first?.unit == "serving")
        #expect(split.options.first?.gramsPerUnit == 400)
        #expect(split.selectedUnitID == "serving")
        #expect(split.servingSizeGrams == 400)
        #expect(split.quantityText == "1")
    }

    @Test func splitReplacesAnExistingServingUnitAndKeepsTheOthersAfterIt() {
        let options = [
            ServingUnitOption(unit: "cup", gramsPerUnit: 240),
            ServingUnitOption(unit: "Serving", gramsPerUnit: 250, quantity: 8)
        ]

        let split = RecipeServings.split(options: options, totalGrams: 2000, servings: 4)

        #expect(split.options.map(\.normalizedUnit) == ["serving", "cup"])
        #expect(split.options[0].gramsPerUnit == 500)
        #expect(split.options[1] == ServingUnitOption(unit: "cup", gramsPerUnit: 240))
    }

    @Test func splitClampsServingsToOneThroughFifty() {
        #expect(RecipeServings.split(options: [], totalGrams: 1000, servings: 0).servings == 1)
        #expect(RecipeServings.split(options: [], totalGrams: 1000, servings: 0).servingSizeGrams == 1000)
        #expect(RecipeServings.split(options: [], totalGrams: 1000, servings: 80).servings == 50)
        #expect(RecipeServings.split(options: [], totalGrams: 1000, servings: 80).servingSizeGrams == 20)
    }

    @Test func controlNeedsTwoIngredientsAndAKnownTotalWeight() {
        #expect(RecipeServings.isAvailable(ingredientCount: 2, totalGrams: 900, servingSizeIsKnown: true))
        #expect(!RecipeServings.isAvailable(ingredientCount: 1, totalGrams: 900, servingSizeIsKnown: true))
        #expect(!RecipeServings.isAvailable(ingredientCount: 3, totalGrams: 0, servingSizeIsKnown: true))
        #expect(!RecipeServings.isAvailable(ingredientCount: 3, totalGrams: .nan, servingSizeIsKnown: true))
        // A Health-restored log with unknown mass keeps its internal serving sentinel.
        #expect(!RecipeServings.isAvailable(ingredientCount: 3, totalGrams: 1, servingSizeIsKnown: false))
    }

    @Test func oneServingScalesNutritionAndIngredientsToOneNth() {
        let ingredients = [
            MealIngredient(name: "Rice", grams: 1200, calories: 1560, protein: 32, carbs: 340, fat: 4),
            MealIngredient(name: "Chicken", grams: 800, calories: 1320, protein: 248, carbs: 0, fat: 29)
        ]
        let total = ingredients.ingredientTotals
        let split = RecipeServings.split(options: [], totalGrams: total.grams, servings: 5)
        // The sheets scale everything by selected grams / whole-recipe grams.
        let scale = split.servingSizeGrams / total.grams
        let serving = ingredients.map { $0.scaled(by: scale) }

        #expect(abs(scale - 0.2) < 0.000_001)
        #expect(abs(serving[0].grams - 240) < 0.000_001)
        #expect(abs(serving[1].grams - 160) < 0.000_001)
        #expect(serving.ingredientTotals.calories == 576)
        #expect(abs(serving.ingredientTotals.protein - 56) < 0.000_001)
    }

    @Test func savedMealKeepsTheServingUnitSoTwoServingsCanBeLoggedLater() throws {
        let split = RecipeServings.split(options: [], totalGrams: 2000, servings: 5)
        let logged = FoodEntry(
            name: "Chili",
            calories: 500,
            protein: 30,
            carbs: 40,
            fat: 20,
            source: .manual,
            servingSizeGrams: split.servingSizeGrams,
            servingUnitOptions: split.options,
            selectedServingUnit: "serving",
            selectedServingQuantity: 1,
            ingredients: [
                MealIngredient(name: "Beans", grams: 250, calories: 300, protein: 20, carbs: 35, fat: 2),
                MealIngredient(name: "Beef", grams: 150, calories: 200, protein: 10, carbs: 5, fat: 18)
            ]
        )

        let decoded = try JSONDecoder().decode(FoodEntry.self, from: JSONEncoder().encode(logged))
        let reopened = ServingUnitOption.normalizedOptions(
            decoded.reviewServingUnitOptions,
            totalGrams: decoded.reviewServingReference
        )
        let unitID = ServingUnitOption.initialUnitID(preferredUnit: decoded.reviewSelectedServingUnit, options: reopened)
        let servingOption = ServingUnitOption.option(matching: unitID, in: reopened)

        #expect(decoded.hasKnownServingSize)
        #expect(unitID == "serving")
        #expect(servingOption.gramsPerUnit == 400)
        #expect(2 * servingOption.gramsPerUnit / decoded.reviewServingReference == 2)
    }

    @Test func aLoggedServingOfASplitRecipeIsNeverOfferedTheSplitAgain() throws {
        let split = RecipeServings.split(options: [], totalGrams: 2000, servings: 5)
        let logged = FoodEntry(
            name: "Chili",
            calories: 500,
            protein: 30,
            carbs: 40,
            fat: 20,
            source: .manual,
            servingSizeGrams: split.servingSizeGrams,
            servingUnitOptions: split.options,
            selectedServingUnit: "serving",
            selectedServingQuantity: 1,
            ingredients: [
                MealIngredient(name: "Beans", grams: 250, calories: 300, protein: 20, carbs: 35, fat: 2),
                MealIngredient(name: "Beef", grams: 150, calories: 200, protein: 10, carbs: 5, fat: 18)
            ]
        )
        let decoded = try JSONDecoder().decode(FoodEntry.self, from: JSONEncoder().encode(logged))

        // The 400 g portion still has a breakdown and a known mass, but it is not the recipe:
        // "2 servings" would log 200 g instead of half the 2,000 g pot.
        #expect(RecipeServings.isAvailable(
            ingredientCount: decoded.ingredients.count,
            totalGrams: decoded.reviewServingReference,
            servingSizeIsKnown: decoded.hasKnownServingSize
        ))
        #expect(RecipeServings.isLoggedPortion(options: decoded.servingUnitOptions))
        #expect(RecipeServings.isLoggedPortion(options: decoded.reviewAnalysis.servingUnitOptions))
        #expect(RecipeServings.isLoggedPortion(options: [ServingUnitOption(unit: "Serving", gramsPerUnit: 250)]))

        // A whole meal logged in grams or other units can still be split.
        #expect(!RecipeServings.isLoggedPortion(options: []))
        #expect(!RecipeServings.isLoggedPortion(options: [ServingUnitOption(unit: "cup", gramsPerUnit: 240)]))
    }

    private let chili = [
        MealIngredient(name: "Beans", grams: 1000, calories: 1100, protein: 70, carbs: 200, fat: 5),
        MealIngredient(name: "Beef", grams: 800, calories: 2000, protein: 200, carbs: 0, fat: 130),
        MealIngredient(name: "Tomato", grams: 200, calories: 40, protein: 2, carbs: 8, fat: 0)
    ]

    /// What the sheets show and hand back after the user edits the second ingredient.
    private func editedPortion(scale: Double, beefGrams: Double) -> [MealIngredient] {
        var shown = chili.map { $0.scaled(by: scale) }
        shown[1] = shown[1].scaled(by: beefGrams / shown[1].grams)
        return shown
    }

    @Test func ingredientEditAfterASplitKeepsTheServingsInsteadOfSplittingTheServingAgain() throws {
        let split = RecipeServings.split(options: [], totalGrams: chili.ingredientTotals.grams, servings: 5)
        let scale = split.servingSizeGrams / chili.ingredientTotals.grams
        // One serving shows 160 g of beef; the user corrects it to 180 g.
        let edited = editedPortion(scale: scale, beefGrams: 180)

        let kept = try #require(RecipeServings.keepingSplit(
            displayedIngredients: edited,
            scale: scale,
            servings: split.servings,
            options: split.options,
            selectedUnitID: split.selectedUnitID
        ))

        let whole = kept.ingredients.ingredientTotals
        #expect(kept.split.servings == 5)
        #expect(abs(whole.grams - 2100) < 0.000_001)
        #expect(abs(kept.ingredients[1].grams - 900) < 0.000_001)
        #expect(kept.split.selectedUnitID == "serving")
        #expect(kept.split.quantityText == "1")
        let serving = try #require(kept.split.options.first { $0.unit == "serving" })
        #expect(abs(serving.gramsPerUnit - 420) < 0.000_001)
        // The logged portion is still exactly the edited serving, not a fifth of it.
        #expect(abs(kept.split.servingSizeGrams - 420) < 0.000_001)
        let loggedPortion = kept.ingredients.map { $0.scaled(by: kept.split.servingSizeGrams / whole.grams) }
        #expect(abs(loggedPortion[1].grams - 180) < 0.000_001)
        #expect(loggedPortion.ingredientTotals.calories == edited.ingredientTotals.calories)

        // Pressing the stepper again re-divides the whole recipe, never the serving.
        let again = RecipeServings.split(options: kept.split.options, totalGrams: whole.grams, servings: kept.split.servings)
        #expect(abs(again.servingSizeGrams - 420) < 0.000_001)
    }

    @Test func ingredientEditKeepsTheSelectedUnitAndShowsTheEditedPortion() throws {
        let split = RecipeServings.split(options: [], totalGrams: chili.ingredientTotals.grams, servings: 4)

        // Two servings selected: 1000 g of the 2000 g pot.
        let twoServings = editedPortion(scale: 0.5, beefGrams: 500)
        let keptServings = try #require(RecipeServings.keepingSplit(
            displayedIngredients: twoServings, scale: 0.5, servings: 4, options: split.options, selectedUnitID: "serving"
        ))
        #expect(keptServings.split.selectedUnitID == "serving")
        #expect(keptServings.split.quantityText == "2")
        #expect(abs(keptServings.split.servingSizeGrams - twoServings.ingredientTotals.grams) < 0.000_001)
        #expect(abs((keptServings.split.options.first?.gramsPerUnit ?? 0) - 550) < 0.000_001)

        // Grams selected: 300 g of the pot.
        let grams = editedPortion(scale: 0.15, beefGrams: 130)
        let keptGrams = try #require(RecipeServings.keepingSplit(
            displayedIngredients: grams, scale: 0.15, servings: 4, options: split.options, selectedUnitID: "g"
        ))
        #expect(keptGrams.split.selectedUnitID == "g")
        #expect(keptGrams.split.quantityText == "310")
        #expect(abs(keptGrams.split.servingSizeGrams - 310) < 0.000_001)
        #expect(keptGrams.split.options.first?.unit == "serving")
    }

    @Test func ingredientEditWithoutAnActiveSplitMakesTheEditedListTheWholeMeal() {
        let edited = editedPortion(scale: 0.2, beefGrams: 180)

        #expect(RecipeServings.keepingSplit(
            displayedIngredients: edited, scale: 0.2, servings: 1, options: [], selectedUnitID: "g"
        ) == nil)
        #expect(RecipeServings.keepingSplit(
            displayedIngredients: edited, scale: 0, servings: 5, options: [], selectedUnitID: "serving"
        ) == nil)
        #expect(RecipeServings.keepingSplit(
            displayedIngredients: edited, scale: .nan, servings: 5, options: [], selectedUnitID: "serving"
        ) == nil)
        // Removing ingredients down to one leaves nothing to split.
        #expect(RecipeServings.keepingSplit(
            displayedIngredients: Array(edited.prefix(1)), scale: 0.2, servings: 5, options: [], selectedUnitID: "serving"
        ) == nil)
    }
}
