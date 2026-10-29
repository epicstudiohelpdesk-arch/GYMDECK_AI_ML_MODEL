package com.apoorvdarshan.calorietracker.models

import org.junit.Assert.assertEquals
import org.junit.Test

class FoodEntryThumbnailTest {
    @Test
    fun progressiveMealPutsFinalPhotoFirstAndPreservesGalleryOrder() {
        val entry = foodEntry(
            imageFilename = "first.jpg",
            additionalImageFilenames = listOf("second.jpg", "final.jpg"),
            progressiveMeal = true
        )

        assertEquals(
            listOf("final.jpg", "first.jpg", "second.jpg"),
            entry.thumbnailImageFilenames
        )
        assertEquals(
            listOf("first.jpg", "second.jpg", "final.jpg"),
            entry.allImageFilenames
        )
    }

    @Test
    fun regularMealKeepsFirstPhotoFirst() {
        val entry = foodEntry(
            imageFilename = "first.jpg",
            additionalImageFilenames = listOf("second.jpg")
        )

        assertEquals(listOf("first.jpg", "second.jpg"), entry.thumbnailImageFilenames)
    }

    @Test
    fun progressiveMealWithoutParentPhotosFallsBackToIngredientPhoto() {
        val entry = foodEntry(progressiveMeal = true).copy(
            ingredients = listOf(ingredient().copy(imageFilename = "ingredient.jpg"))
        )

        assertEquals(listOf("ingredient.jpg"), entry.thumbnailImageFilenames)
    }

    @Test
    fun entryWithoutPhotosHasNoThumbnailCandidates() {
        assertEquals(emptyList<String>(), foodEntry().thumbnailImageFilenames)
    }

    private fun foodEntry(
        imageFilename: String? = null,
        additionalImageFilenames: List<String> = emptyList(),
        progressiveMeal: Boolean = false
    ) = FoodEntry(
        name = "Lunch",
        calories = 450,
        protein = 24.5,
        carbs = 52.5,
        fat = 15.0,
        imageFilename = imageFilename,
        additionalImageFilenames = additionalImageFilenames,
        progressiveMeal = progressiveMeal,
        source = FoodSource.SNAP_FOOD
    )

    private fun ingredient() = MealIngredient(
        name = "Tofu",
        grams = 100.0,
        calories = 120,
        protein = 14.5,
        carbs = 3.0,
        fat = 5.5
    )
}
