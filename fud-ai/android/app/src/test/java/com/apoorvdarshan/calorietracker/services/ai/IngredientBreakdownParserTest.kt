package com.apoorvdarshan.calorietracker.services.ai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class IngredientBreakdownParserTest {
    @Test
    fun repairsIngredientWithoutGramsFromRemainingMealWeight() {
        val ingredients = FoodJsonParser.parseIngredients(
            """
            {"ingredients":[
              {"name":"Greek yogurt","grams":200,"calories":150,"protein":20,"carbs":8,"fat":2},
              {"name":"Berries","grams":100,"calories":50,"protein":1,"carbs":12,"fat":0},
              {"name":"Honey","grams":0,"calories":10,"protein":0,"carbs":3,"fat":0}
            ]}
            """.trimIndent(),
            mealCalories = 300,
            mealGrams = 350.0
        )

        assertEquals(listOf("Greek yogurt", "Berries", "Honey"), ingredients.map { it.name })
        assertEquals(200.0, ingredients.first().grams, 0.0)
        assertEquals(50.0, ingredients.last().grams, 0.0)
    }

    @Test
    fun screenshotOfSeveralDishesKeepsEveryDishAndTheMealTotal() {
        // #343: a meal-list screenshot shows calories per dish but no weight for some dishes.
        val analysis = mealAnalysis(
            calories = 700,
            protein = 40.0,
            carbs = 80.0,
            fat = 24.0,
            servingSizeGrams = 600.0,
            ingredientsJson = """
                {"name":"Dish 1","grams":150,"calories":156,"protein":10,"carbs":20,"fat":4},
                {"name":"Dish 2","grams":null,"calories":544,"protein":30,"carbs":60,"fat":20}
            """
        )

        assertEquals(listOf("Dish 1", "Dish 2"), analysis.ingredients.map { it.name })
        assertEquals(450.0, analysis.ingredients.last().grams, 0.0)
        assertEquals(700, analysis.calories)
        assertEquals(40.0, analysis.protein, 0.001)
    }

    @Test
    fun missingWeightsThatCannotFitInTheMealWeightDropTheBreakdown() {
        // 10 g left for a 500 kcal dish, and no weight left at all: a repair would make the
        // ingredients outweigh the 400 g meal, so the header totals stay instead.
        for (saladGrams in listOf(390, 420)) {
            val analysis = mealAnalysis(
                calories = 600,
                protein = 30.0,
                carbs = 60.0,
                fat = 25.0,
                servingSizeGrams = 400.0,
                ingredientsJson = """
                    {"name":"Salad","grams":$saladGrams,"calories":100,"protein":5,"carbs":10,"fat":5},
                    {"name":"Pasta","calories":500,"protein":25,"carbs":50,"fat":20}
                """
            )

            assertTrue("salad $saladGrams g", analysis.ingredients.isEmpty())
            assertEquals(600, analysis.calories)
            assertEquals(30.0, analysis.protein, 0.0)
        }
    }

    @Test
    fun numericStringsAreReadAsNumbers() {
        val analysis = mealAnalysis(
            calories = 700,
            protein = 40.0,
            carbs = 80.0,
            fat = 24.0,
            servingSizeGrams = 600.0,
            ingredientsJson = """
                {"name":"Dish 1","grams":"150","calories":"156","protein":"10","carbs":20,"fat":4},
                {"name":"Dish 2","grams":450,"calories":544,"protein":30,"carbs":60,"fat":20}
            """
        )

        assertEquals(listOf("Dish 1", "Dish 2"), analysis.ingredients.map { it.name })
        assertEquals(150.0, analysis.ingredients.first().grams, 0.0)
        assertEquals(156, analysis.ingredients.first().calories)
        assertEquals(700, analysis.calories)
    }

    @Test
    fun malformedIngredientDropsTheWholeBreakdownAndKeepsMealTotals() {
        val malformedItems = listOf(
            """{"name":"Rice","grams":150,"calories":200,"protein":4,"carbs":44}""",
            """{"name":"","grams":150,"calories":200,"protein":4,"carbs":44,"fat":1}""",
            """{"name":"Rice","grams":150,"calories":-5,"protein":4,"carbs":44,"fat":1}""",
            """{"name":"Water","grams":0,"calories":0,"protein":0,"carbs":0,"fat":0}""",
            """{"name":"Rice","grams":-150,"calories":200,"protein":4,"carbs":44,"fat":1}""",
            """{"name":"Rice","grams":150,"calories":true,"protein":4,"carbs":44,"fat":1}""",
            """{"name":"Rice","grams":150,"calories":"about 200","protein":4,"carbs":44,"fat":1}""",
            // Finite but far beyond any food; would saturate roundToInt and the totals.
            """{"name":"Rice","grams":150,"calories":"1e100","protein":4,"carbs":44,"fat":1}""",
            """{"name":"Rice","grams":1e300,"calories":200,"protein":4,"carbs":44,"fat":1}""",
            "\"Rice\""
        )
        for (malformed in malformedItems) {
            val analysis = mealAnalysis(
                calories = 500,
                protein = 30.0,
                carbs = 60.0,
                fat = 12.0,
                servingSizeGrams = 400.0,
                ingredientsJson = """
                    {"name":"Chicken","grams":150,"calories":250,"protein":26,"carbs":0,"fat":11},
                    $malformed
                """
            )

            assertTrue(malformed, analysis.ingredients.isEmpty())
            assertEquals(500, analysis.calories)
            assertEquals(30.0, analysis.protein, 0.0)
            assertEquals(60.0, analysis.carbs, 0.0)
            assertEquals(12.0, analysis.fat, 0.0)
        }
    }

    @Test
    fun missingIngredientWeightWithoutMealWeightDropsTheBreakdown() {
        val ingredients = FoodJsonParser.parseIngredients(
            """
            {"ingredients":[
              {"name":"Dish 1","grams":150,"calories":156,"protein":10,"carbs":20,"fat":4},
              {"name":"Dish 2","calories":544,"protein":30,"carbs":60,"fat":20}
            ]}
            """.trimIndent(),
            mealCalories = 700,
            mealGrams = null
        )

        assertTrue(ingredients.isEmpty())
    }

    @Test
    fun moreThanTwentyIngredientsDropsTheBreakdownInsteadOfTruncating() {
        val items = (1..21).joinToString(",") {
            """{"name":"Item $it","grams":10,"calories":20,"protein":1,"carbs":2,"fat":1}"""
        }
        val analysis = mealAnalysis(
            calories = 420,
            protein = 21.0,
            carbs = 42.0,
            fat = 21.0,
            servingSizeGrams = 210.0,
            ingredientsJson = items
        )

        assertTrue(analysis.ingredients.isEmpty())
        assertEquals(420, analysis.calories)
    }

    @Test
    fun breakdownCoveringLessThanHalfTheMealCaloriesIsDropped() {
        val analysis = mealAnalysis(
            calories = 700,
            protein = 40.0,
            carbs = 80.0,
            fat = 24.0,
            servingSizeGrams = 600.0,
            ingredientsJson = """
                {"name":"Dish 1","grams":150,"calories":156,"protein":10,"carbs":20,"fat":4}
            """
        )

        assertTrue(analysis.ingredients.isEmpty())
        assertEquals(700, analysis.calories)
        assertEquals(40.0, analysis.protein, 0.0)
    }

    @Test
    fun breakdownAddingUpToFarMoreThanTheMealCaloriesIsDropped() {
        // A meal-list screenshot's total row echoed as a dish would double the logged calories.
        val analysis = mealAnalysis(
            calories = 700,
            protein = 40.0,
            carbs = 80.0,
            fat = 24.0,
            servingSizeGrams = 600.0,
            ingredientsJson = """
                {"name":"Dish 1","grams":150,"calories":156,"protein":10,"carbs":20,"fat":4},
                {"name":"Dish 2","grams":450,"calories":544,"protein":30,"carbs":60,"fat":20},
                {"name":"Total","grams":600,"calories":700,"protein":40,"carbs":80,"fat":24}
            """
        )

        assertTrue(analysis.ingredients.isEmpty())
        assertEquals(700, analysis.calories)
        assertEquals(40.0, analysis.protein, 0.0)
    }

    @Test
    fun promptsStateTheIngredientCapSoLongMenusAreGroupedInsteadOfDropped() {
        for (progressiveMeal in listOf(false, true)) {
            val prompt = multiPhotoAnalysisPrompt(progressiveMeal = progressiveMeal)
            assertTrue(prompt.contains("Return at most 20 ingredients"))
            assertTrue(prompt.contains("Never add a total or subtotal row as an ingredient."))
        }
    }

    /** Mirrors parseFoodResponse: meal macros come from the header unless a breakdown replaces them. */
    private fun mealAnalysis(
        calories: Int,
        protein: Double,
        carbs: Double,
        fat: Double,
        servingSizeGrams: Double,
        ingredientsJson: String
    ): FoodAnalysis = FoodAnalysis(
        name = "Meal",
        calories = calories,
        protein = protein,
        carbs = carbs,
        fat = fat,
        servingSizeGrams = servingSizeGrams,
        ingredients = FoodJsonParser.parseIngredients(
            """{"ingredients":[$ingredientsJson]}""",
            mealCalories = calories,
            mealGrams = servingSizeGrams
        )
    ).withIngredientMacroTotals()
}
