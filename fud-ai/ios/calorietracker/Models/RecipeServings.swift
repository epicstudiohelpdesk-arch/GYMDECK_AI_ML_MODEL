import Foundation

/// The serving state a review or edit sheet adopts after the user says how many
/// servings a multi-ingredient recipe makes (#458).
struct RecipeServingSplit: Equatable {
    var servings: Int
    var options: [ServingUnitOption]
    var selectedUnitID: String
    var servingSizeGrams: Double
    var quantityText: String
}

/// A recipe split carried through an ingredient edit: the rebuilt whole recipe
/// and its servings (#458).
struct RecipeServingsEdit: Equatable {
    var ingredients: [MealIngredient]
    var split: RecipeServingSplit
}

/// "This recipe makes N servings": divides the whole meal into N equal portions
/// through a regular "serving" unit, so the sheet logs one serving and Saved
/// Meals keep the unit for logging 1 or 2 servings later.
enum RecipeServings {
    static let range = 1...50
    static let unit = "serving"

    static func clamped(_ servings: Int) -> Int {
        min(max(servings, range.lowerBound), range.upperBound)
    }

    /// The control needs a real ingredient breakdown and a known total mass.
    /// A Health-restored log with unknown mass uses the internal
    /// `ServingUnitOption.loggedServing` sentinel (a serving count, not grams),
    /// so it never qualifies and the two "serving" meanings never mix.
    static func isAvailable(ingredientCount: Int, totalGrams: Double, servingSizeIsKnown: Bool) -> Bool {
        servingSizeIsKnown && ingredientCount >= 2 && totalGrams.isFinite && totalGrams > 0
    }

    /// A logged entry that already has a "serving" unit holds a portion, not
    /// the whole recipe. The recipe's servings count is not saved with it, so
    /// splitting it again would divide that portion instead of the recipe. The
    /// edit sheet and a re-log of a logged entry hide the control for it.
    static func isLoggedPortion(options: [ServingUnitOption]) -> Bool {
        options.contains { $0.normalizedUnit == unit }
    }

    /// Replaces any existing "serving" unit with `totalGrams / servings` and
    /// selects one serving. The new unit goes first so it survives the
    /// four-option cap when the logged entry is reopened.
    static func split(options: [ServingUnitOption], totalGrams: Double, servings: Int) -> RecipeServingSplit {
        let count = clamped(servings)
        let gramsPerServing = totalGrams / Double(count)
        let serving = ServingUnitOption(unit: unit, gramsPerUnit: gramsPerServing)
        let otherOptions = options.filter { $0.normalizedUnit != serving.normalizedUnit }
        return RecipeServingSplit(
            servings: count,
            options: [serving] + otherOptions,
            selectedUnitID: serving.id,
            servingSizeGrams: gramsPerServing,
            quantityText: "1"
        )
    }

    /// Ingredient edits happen in the portion the sheet shows, which is `scale`
    /// of the whole recipe. While a split is active, this scales the edited list
    /// back up to a new whole recipe and divides it into the same `servings`
    /// again. The selected unit stays, with its quantity reworked so the sheet
    /// still shows exactly the edited portion. Returns nil when no split is
    /// active or the meal no longer qualifies; the edited list then becomes the
    /// whole meal, as before.
    static func keepingSplit(
        displayedIngredients: [MealIngredient],
        scale: Double,
        servings: Int,
        options: [ServingUnitOption],
        selectedUnitID: String
    ) -> RecipeServingsEdit? {
        guard servings > range.lowerBound, scale.isFinite, scale > 0 else { return nil }
        let portionGrams = displayedIngredients.ingredientTotals.grams
        let wholeRecipe = displayedIngredients.map { $0.scaled(by: 1 / scale) }
        let totalGrams = wholeRecipe.ingredientTotals.grams
        guard portionGrams > 0,
              isAvailable(ingredientCount: wholeRecipe.count, totalGrams: totalGrams, servingSizeIsKnown: true)
        else { return nil }
        var resplit = split(options: options, totalGrams: totalGrams, servings: servings)
        let selected = ServingUnitOption.option(matching: selectedUnitID, in: resplit.options)
        resplit.selectedUnitID = selected.id
        resplit.servingSizeGrams = portionGrams
        resplit.quantityText = ServingUnitOption.initialQuantityText(
            totalGrams: portionGrams,
            selectedUnitID: selected.id,
            selectedQuantity: nil,
            options: resplit.options
        )
        return RecipeServingsEdit(ingredients: wholeRecipe, split: resplit)
    }
}
