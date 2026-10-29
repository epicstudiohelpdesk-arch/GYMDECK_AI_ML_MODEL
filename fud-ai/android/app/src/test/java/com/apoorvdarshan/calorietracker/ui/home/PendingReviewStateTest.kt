package com.apoorvdarshan.calorietracker.ui.home

import com.apoorvdarshan.calorietracker.models.FoodEntry
import com.apoorvdarshan.calorietracker.models.FoodSource
import com.apoorvdarshan.calorietracker.models.MealIngredient
import com.apoorvdarshan.calorietracker.models.PendingFoodAnalysisDraft
import com.apoorvdarshan.calorietracker.models.RecipeServings
import com.apoorvdarshan.calorietracker.models.ServingUnitOption
import com.apoorvdarshan.calorietracker.services.ai.FoodAnalysis
import kotlinx.serialization.json.Json
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** What the pending review shows after a saved barcode label or a Saved Meals re-log (#485, #458). */
class PendingReviewStateTest {
    // Same settings PreferencesStore uses for the pending draft.
    private val json = Json { ignoreUnknownKeys = true }
    private val label = FoodAnalysis(name = "Protein bar", calories = 200, protein = 20.0, carbs = 15.0, fat = 7.0, servingSizeGrams = 60.0)

    private fun roundTrip(draft: PendingFoodAnalysisDraft): PendingFoodAnalysisDraft =
        json.decodeFromString(PendingFoodAnalysisDraft.serializer(), json.encodeToString(PendingFoodAnalysisDraft.serializer(), draft))

    @Test
    fun restoredSavedLabelReviewKeepsItsNotice() {
        val restored = roundTrip(
            PendingFoodAnalysisDraft(analysis = label, source = FoodSource.NUTRITION_LABEL, usesSavedBarcodeLabel = true)
        )
        val state = HomeUiState(pendingAnalysis = restored.analysis, savedLabelAnalysis = restored.savedLabelAnalysis)

        assertSame(restored.analysis, restored.savedLabelAnalysis)
        assertTrue(state.pendingUsesSavedBarcodeLabel)
    }

    @Test
    fun otherRestoredReviewsAndOlderDraftsShowNoSavedLabelNotice() {
        val photo = roundTrip(PendingFoodAnalysisDraft(analysis = label, source = FoodSource.NUTRITION_LABEL))
        assertNull(photo.savedLabelAnalysis)
        assertFalse(HomeUiState(pendingAnalysis = photo.analysis, savedLabelAnalysis = photo.savedLabelAnalysis).pendingUsesSavedBarcodeLabel)

        // A draft saved before the flag existed decodes without it.
        val legacyJson = json.encodeToString(PendingFoodAnalysisDraft.serializer(), PendingFoodAnalysisDraft(analysis = label))
            .replace(",\"usesSavedBarcodeLabel\":false", "")
        assertFalse(json.decodeFromString(PendingFoodAnalysisDraft.serializer(), legacyJson).usesSavedBarcodeLabel)
    }

    @Test
    fun reLoggingASplitServingHidesServingsInRecipe() {
        val split = RecipeServings.split(emptyList(), totalGrams = 2000.0, servings = 5)
        val ingredients = listOf(
            MealIngredient("Beans", 250.0, 300, 20.0, 35.0, 2.0),
            MealIngredient("Beef", 150.0, 200, 10.0, 5.0, 18.0)
        )
        val portion = FoodEntry(
            name = "Chili", calories = 500, protein = 30.0, carbs = 40.0, fat = 20.0,
            source = FoodSource.MANUAL, servingSizeGrams = split.servingGrams,
            servingUnitOptions = split.options, selectedServingUnit = "serving", selectedServingQuantity = 1.0,
            ingredients = ingredients
        )
        val wholePot = portion.copy(
            servingSizeGrams = 2000.0, servingUnitOptions = emptyList(), selectedServingUnit = "g", selectedServingQuantity = 2000.0
        )

        assertTrue(HomeUiState(pendingReviewSource = portion).pendingReviewIsLoggedPortion)
        assertFalse(HomeUiState(pendingReviewSource = wholePot).pendingReviewIsLoggedPortion)
        // A fresh analysis can carry its own "serving" unit and still be split.
        val fresh = label.copy(servingUnitOptions = listOf(ServingUnitOption(unit = "serving", gramsPerUnit = 500.0, quantity = 4.0)))
        assertFalse(HomeUiState(pendingAnalysis = fresh).pendingReviewIsLoggedPortion)
        assertTrue(HomeUiState(pendingAnalysis = fresh, savedLabelAnalysis = fresh).pendingReviewIsLoggedPortion)
    }
}
