package com.apoorvdarshan.calorietracker.models

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** "This recipe makes N servings" in the review and edit sheets (#458). */
class RecipeServingsTest {
    @Test
    fun splitDividesTheWholeRecipeIntoOneSelectedServing() {
        val split = RecipeServings.split(emptyList(), totalGrams = 2000.0, servings = 5)

        assertEquals(5, split.servings)
        assertEquals(listOf(ServingUnitOption(unit = "serving", gramsPerUnit = 400.0)), split.options)
        assertEquals("serving", split.selectedUnitId)
        assertEquals(400.0, split.servingGrams, 0.0)
        assertEquals("1", split.quantityText)
    }

    @Test
    fun splitReplacesAnExistingServingUnitAndKeepsTheOthersAfterIt() {
        val options = listOf(
            ServingUnitOption(unit = "cup", gramsPerUnit = 240.0),
            ServingUnitOption(unit = "Serving", gramsPerUnit = 250.0, quantity = 8.0)
        )

        val split = RecipeServings.split(options, totalGrams = 2000.0, servings = 4)

        assertEquals(listOf("serving", "cup"), split.options.map { it.normalizedUnit })
        assertEquals(500.0, split.options[0].gramsPerUnit, 0.0)
        assertEquals(ServingUnitOption(unit = "cup", gramsPerUnit = 240.0), split.options[1])
    }

    @Test
    fun splitClampsServingsToOneThroughFifty() {
        val tooFew = RecipeServings.split(emptyList(), totalGrams = 1000.0, servings = 0)
        val tooMany = RecipeServings.split(emptyList(), totalGrams = 1000.0, servings = 80)

        assertEquals(1, tooFew.servings)
        assertEquals(1000.0, tooFew.servingGrams, 0.0)
        assertEquals(50, tooMany.servings)
        assertEquals(20.0, tooMany.servingGrams, 0.0)
    }

    @Test
    fun controlNeedsTwoIngredientsAndAKnownTotalWeight() {
        assertTrue(RecipeServings.isAvailable(ingredientCount = 2, totalGrams = 900.0, servingSizeIsKnown = true))
        assertFalse(RecipeServings.isAvailable(ingredientCount = 1, totalGrams = 900.0, servingSizeIsKnown = true))
        assertFalse(RecipeServings.isAvailable(ingredientCount = 3, totalGrams = 0.0, servingSizeIsKnown = true))
        assertFalse(RecipeServings.isAvailable(ingredientCount = 3, totalGrams = Double.NaN, servingSizeIsKnown = true))
        // A Health-restored log with unknown mass keeps its internal serving sentinel.
        assertFalse(RecipeServings.isAvailable(ingredientCount = 3, totalGrams = 1.0, servingSizeIsKnown = false))
    }

    @Test
    fun oneServingScalesNutritionAndIngredientsToOneNth() {
        val ingredients = listOf(
            MealIngredient("Rice", 1200.0, 1560, 32.0, 340.0, 4.0),
            MealIngredient("Chicken", 800.0, 1320, 248.0, 0.0, 29.0)
        )
        val total = ingredients.totals()
        val split = RecipeServings.split(emptyList(), total.grams, servings = 5)
        // The sheets scale everything by selected grams / whole-recipe grams.
        val scale = split.servingGrams / total.grams
        val serving = ingredients.map { it.scaled(scale) }

        assertEquals(0.2, scale, 0.000_001)
        assertEquals(240.0, serving[0].grams, 0.000_001)
        assertEquals(160.0, serving[1].grams, 0.000_001)
        assertEquals(576, serving.totals().calories)
        assertEquals(56.0, serving.totals().protein, 0.000_001)
    }

    @Test
    fun savedMealKeepsTheServingUnitSoTwoServingsCanBeLoggedLater() {
        val split = RecipeServings.split(emptyList(), totalGrams = 2000.0, servings = 5)
        val logged = FoodEntry(
            name = "Chili",
            calories = 500,
            protein = 30.0,
            carbs = 40.0,
            fat = 20.0,
            source = FoodSource.MANUAL,
            servingSizeGrams = split.servingGrams,
            servingUnitOptions = split.options,
            selectedServingUnit = "serving",
            selectedServingQuantity = 1.0,
            ingredients = listOf(
                MealIngredient("Beans", 250.0, 300, 20.0, 35.0, 2.0),
                MealIngredient("Beef", 150.0, 200, 10.0, 5.0, 18.0)
            )
        )

        val json = Json { ignoreUnknownKeys = true }
        val decoded = json.decodeFromString(FoodEntry.serializer(), json.encodeToString(FoodEntry.serializer(), logged))
        val reopened = ServingUnitOption.normalizedOptions(decoded.reviewServingUnitOptions, decoded.reviewServingReference)
        val unitId = ServingUnitOption.initialUnitId(decoded.reviewSelectedServingUnit, reopened)
        val servingOption = ServingUnitOption.optionMatching(unitId, reopened)

        assertTrue(decoded.hasKnownServingSize)
        assertEquals("serving", unitId)
        assertEquals(400.0, servingOption.gramsPerUnit, 0.0)
        assertEquals(2.0, 2 * servingOption.gramsPerUnit / decoded.reviewServingReference, 0.0)
    }

    @Test
    fun aLoggedServingOfASplitRecipeIsNeverOfferedTheSplitAgain() {
        val split = RecipeServings.split(emptyList(), totalGrams = 2000.0, servings = 5)
        val logged = FoodEntry(
            name = "Chili",
            calories = 500,
            protein = 30.0,
            carbs = 40.0,
            fat = 20.0,
            source = FoodSource.MANUAL,
            servingSizeGrams = split.servingGrams,
            servingUnitOptions = split.options,
            selectedServingUnit = "serving",
            selectedServingQuantity = 1.0,
            ingredients = listOf(
                MealIngredient("Beans", 250.0, 300, 20.0, 35.0, 2.0),
                MealIngredient("Beef", 150.0, 200, 10.0, 5.0, 18.0)
            )
        )
        val json = Json { ignoreUnknownKeys = true }
        val decoded = json.decodeFromString(FoodEntry.serializer(), json.encodeToString(FoodEntry.serializer(), logged))

        // The 400 g portion still has a breakdown and a known mass, but it is not the recipe:
        // "2 servings" would log 200 g instead of half the 2,000 g pot.
        assertTrue(RecipeServings.isAvailable(decoded.ingredients.size, decoded.reviewServingReference, decoded.hasKnownServingSize))
        assertTrue(RecipeServings.isLoggedPortion(decoded.servingUnitOptions))
        assertTrue(RecipeServings.isLoggedPortion(listOf(ServingUnitOption(unit = "Serving", gramsPerUnit = 250.0))))

        // A whole meal logged in grams or other units can still be split.
        assertFalse(RecipeServings.isLoggedPortion(emptyList()))
        assertFalse(RecipeServings.isLoggedPortion(listOf(ServingUnitOption(unit = "cup", gramsPerUnit = 240.0))))
    }

    private val chili = listOf(
        MealIngredient("Beans", 1000.0, 1100, 70.0, 200.0, 5.0),
        MealIngredient("Beef", 800.0, 2000, 200.0, 0.0, 130.0),
        MealIngredient("Tomato", 200.0, 40, 2.0, 8.0, 0.0)
    )

    /** What the sheets show and hand back after the user edits the second ingredient. */
    private fun editedPortion(scale: Double, beefGrams: Double): List<MealIngredient> {
        val shown = chili.map { it.scaled(scale) }.toMutableList()
        shown[1] = shown[1].scaled(beefGrams / shown[1].grams)
        return shown
    }

    @Test
    fun ingredientEditAfterASplitKeepsTheServingsInsteadOfSplittingTheServingAgain() {
        val split = RecipeServings.split(emptyList(), chili.totals().grams, servings = 5)
        val scale = split.servingGrams / chili.totals().grams
        // One serving shows 160 g of beef; the user corrects it to 180 g.
        val edited = editedPortion(scale, beefGrams = 180.0)

        val kept = requireNotNull(
            RecipeServings.keepingSplit(edited, scale, split.servings, split.options, split.selectedUnitId)
        )

        val whole = kept.ingredients.totals()
        assertEquals(5, kept.split.servings)
        assertEquals(2100.0, whole.grams, 0.000_001)
        assertEquals(900.0, kept.ingredients[1].grams, 0.000_001)
        assertEquals("serving", kept.split.selectedUnitId)
        assertEquals("1", kept.split.quantityText)
        assertEquals(420.0, kept.split.options.single { it.unit == "serving" }.gramsPerUnit, 0.000_001)
        // The logged portion is still exactly the edited serving, not a fifth of it.
        assertEquals(420.0, kept.split.servingGrams, 0.000_001)
        val loggedPortion = kept.ingredients.map { it.scaled(kept.split.servingGrams / whole.grams) }
        assertEquals(180.0, loggedPortion[1].grams, 0.000_001)
        assertEquals(edited.totals().calories, loggedPortion.totals().calories)

        // Pressing the stepper again re-divides the whole recipe, never the serving.
        val again = RecipeServings.split(kept.split.options, whole.grams, kept.split.servings)
        assertEquals(420.0, again.servingGrams, 0.000_001)
    }

    @Test
    fun ingredientEditKeepsTheSelectedUnitAndShowsTheEditedPortion() {
        val split = RecipeServings.split(emptyList(), chili.totals().grams, servings = 4)

        // Two servings selected: 1000 g of the 2000 g pot.
        val twoServings = editedPortion(scale = 0.5, beefGrams = 500.0)
        val keptServings = RecipeServings.keepingSplit(twoServings, 0.5, 4, split.options, "serving")!!
        assertEquals("serving", keptServings.split.selectedUnitId)
        assertEquals("2", keptServings.split.quantityText)
        assertEquals(twoServings.totals().grams, keptServings.split.servingGrams, 0.000_001)
        assertEquals(550.0, keptServings.split.options.first().gramsPerUnit, 0.000_001)

        // Grams selected: 300 g of the pot.
        val grams = editedPortion(scale = 0.15, beefGrams = 130.0)
        val keptGrams = RecipeServings.keepingSplit(grams, 0.15, 4, split.options, "g")!!
        assertEquals("g", keptGrams.split.selectedUnitId)
        assertEquals("310", keptGrams.split.quantityText)
        assertEquals(310.0, keptGrams.split.servingGrams, 0.000_001)
        assertEquals("serving", keptGrams.split.options.first().unit)
    }

    @Test
    fun ingredientEditWithoutAnActiveSplitMakesTheEditedListTheWholeMeal() {
        val edited = editedPortion(scale = 0.2, beefGrams = 180.0)

        assertNull(RecipeServings.keepingSplit(edited, 0.2, servings = 1, options = emptyList(), selectedUnitId = "g"))
        assertNull(RecipeServings.keepingSplit(edited, 0.0, servings = 5, options = emptyList(), selectedUnitId = "serving"))
        assertNull(RecipeServings.keepingSplit(edited, Double.NaN, servings = 5, options = emptyList(), selectedUnitId = "serving"))
        // Removing ingredients down to one leaves nothing to split.
        assertNull(RecipeServings.keepingSplit(edited.take(1), 0.2, servings = 5, options = emptyList(), selectedUnitId = "serving"))
    }
}
