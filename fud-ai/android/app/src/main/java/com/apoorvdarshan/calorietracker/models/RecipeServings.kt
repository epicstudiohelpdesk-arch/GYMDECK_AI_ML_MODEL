package com.apoorvdarshan.calorietracker.models

/** The serving state a review or edit sheet adopts after "this recipe makes N servings" (#458). */
data class RecipeServingSplit(
    val servings: Int,
    val options: List<ServingUnitOption>,
    val selectedUnitId: String,
    val servingGrams: Double,
    val quantityText: String
)

/** A recipe split carried through an ingredient edit: the rebuilt whole recipe and its servings (#458). */
data class RecipeServingsEdit(
    val ingredients: List<MealIngredient>,
    val split: RecipeServingSplit
)

/**
 * "This recipe makes N servings": divides the whole meal into N equal portions
 * through a regular "serving" unit, so the sheet logs one serving and Saved
 * Meals keep the unit for logging 1 or 2 servings later. Mirrors iOS RecipeServings.
 */
object RecipeServings {
    const val MIN = 1
    const val MAX = 50
    const val UNIT = "serving"

    fun clamped(servings: Int): Int = servings.coerceIn(MIN, MAX)

    /**
     * The control needs a real ingredient breakdown and a known total mass. A
     * Health-restored log with unknown mass uses the internal
     * [ServingUnitOption.loggedServing] sentinel (a serving count, not grams),
     * so it never qualifies and the two "serving" meanings never mix.
     */
    fun isAvailable(ingredientCount: Int, totalGrams: Double, servingSizeIsKnown: Boolean): Boolean =
        servingSizeIsKnown && ingredientCount >= 2 && totalGrams.isFinite() && totalGrams > 0

    /**
     * A logged entry that already has a "serving" unit holds a portion, not the
     * whole recipe. The recipe's servings count is not saved with it, so splitting
     * it again would divide that portion instead of the recipe. The edit sheet and
     * a re-log of a logged entry hide the control for it.
     */
    fun isLoggedPortion(options: List<ServingUnitOption>): Boolean =
        options.any { it.normalizedUnit == UNIT }

    /**
     * Replaces any existing "serving" unit with `totalGrams / servings` and selects
     * one serving. The new unit goes first so it survives the four-option cap when
     * the logged entry is reopened.
     */
    fun split(options: List<ServingUnitOption>, totalGrams: Double, servings: Int): RecipeServingSplit {
        val count = clamped(servings)
        val gramsPerServing = totalGrams / count
        val serving = ServingUnitOption(unit = UNIT, gramsPerUnit = gramsPerServing)
        val otherOptions = options.filter { it.normalizedUnit != serving.normalizedUnit }
        return RecipeServingSplit(
            servings = count,
            options = listOf(serving) + otherOptions,
            selectedUnitId = serving.id,
            servingGrams = gramsPerServing,
            quantityText = "1"
        )
    }

    /**
     * Ingredient edits happen in the portion the sheet shows, which is [scale] of
     * the whole recipe. While a split is active, this scales the edited list back
     * up to a new whole recipe and divides it into the same [servings] again. The
     * selected unit stays, with its quantity reworked so the sheet still shows
     * exactly the edited portion. Returns null when no split is active or the meal
     * no longer qualifies; the edited list then becomes the whole meal, as before.
     */
    fun keepingSplit(
        displayedIngredients: List<MealIngredient>,
        scale: Double,
        servings: Int,
        options: List<ServingUnitOption>,
        selectedUnitId: String
    ): RecipeServingsEdit? {
        if (servings <= MIN || !scale.isFinite() || scale <= 0) return null
        val portionGrams = displayedIngredients.totals().grams
        val wholeRecipe = displayedIngredients.map { it.scaled(1 / scale) }
        val totalGrams = wholeRecipe.totals().grams
        if (portionGrams <= 0 || !isAvailable(wholeRecipe.size, totalGrams, servingSizeIsKnown = true)) return null
        val split = split(options, totalGrams, servings)
        val selected = ServingUnitOption.optionMatching(selectedUnitId, split.options)
        return RecipeServingsEdit(
            ingredients = wholeRecipe,
            split = split.copy(
                selectedUnitId = selected.id,
                servingGrams = portionGrams,
                quantityText = ServingUnitOption.initialQuantityText(
                    totalGrams = portionGrams,
                    selectedUnitId = selected.id,
                    selectedQuantity = null,
                    options = split.options
                )
            )
        )
    }
}
