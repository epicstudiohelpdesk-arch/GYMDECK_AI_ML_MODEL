package com.apoorvdarshan.calorietracker.models

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class UserProfileGoalFormulaTest {
    @Test
    fun knownBodyFatAlwaysUsesKatchEvenWithLegacyFalsePreference() {
        val base = UserProfile(weightKg = 80.0, heightCm = 180.0, bodyFatPercentage = 0.20)

        assertTrue(base.copy(useBodyFatInBMR = null).usesBodyFatForBMR)
        assertTrue(base.copy(useBodyFatInBMR = true).usesBodyFatForBMR)
        assertTrue(base.copy(useBodyFatInBMR = false).usesBodyFatForBMR)
        assertEquals(
            370.0 + 21.6 * 0.8 * 80.0,
            base.copy(useBodyFatInBMR = false).bmr,
            0.001
        )
    }

    @Test
    fun proteinActivityRatesAreFullBodyweightEquivalents() {
        val withBodyFat = UserProfile(
            weightKg = 100.0,
            bodyFatPercentage = 0.30,
            activityLevel = ActivityLevel.MODERATE,
            goal = WeightGoal.LOSE
        )
        val withoutBodyFat = withBodyFat.copy(bodyFatPercentage = null)

        assertEquals(180, withBodyFat.proteinGoal)
        assertEquals(withoutBodyFat.proteinGoal, withBodyFat.proteinGoal)
    }

    @Test
    fun weeklyCalorieAdjustmentUses7700KcalPerKilogram() {
        assertEquals(-550, UserProfile(goal = WeightGoal.LOSE, weeklyChangeKg = 0.5).calorieAdjustment)
        assertEquals(550, UserProfile(goal = WeightGoal.GAIN, weeklyChangeKg = 0.5).calorieAdjustment)
    }

    // Katch-McArdle (body fat known) keeps BMR independent of age, so the TDEE is fixed:
    // (370 + 21.6 × 0.8 × 80) × 1.2 = 2102.88.
    private val maintenanceProfile = UserProfile(
        weightKg = 80.0,
        bodyFatPercentage = 0.20,
        activityLevel = ActivityLevel.SEDENTARY
    )

    @Test
    fun maintenanceIsTruncatedFormulaTdee() {
        val breakdown = maintenanceProfile.maintenanceBreakdown

        assertEquals(2_102, breakdown.maintenanceCalories)
        assertEquals(2_102, breakdown.targetCalories)
        assertEquals(0, breakdown.dailyDifference)
        assertEquals(MaintenanceBreakdown.Balance.MAINTENANCE, breakdown.balance)
    }

    @Test
    fun formulaGoalTargetsShowWeeklyRateSurplusOrDeficit() {
        val gain = maintenanceProfile.copy(goal = WeightGoal.GAIN, weeklyChangeKg = 0.25)
        val lose = maintenanceProfile.copy(goal = WeightGoal.LOSE, weeklyChangeKg = 0.5)

        assertEquals(gain.calorieAdjustment, gain.maintenanceBreakdown.dailyDifference)
        assertEquals(275, gain.maintenanceBreakdown.dailyDifference)
        assertEquals(MaintenanceBreakdown.Balance.SURPLUS, gain.maintenanceBreakdown.balance)
        assertEquals(-550, lose.maintenanceBreakdown.dailyDifference)
        assertEquals(MaintenanceBreakdown.Balance.DEFICIT, lose.maintenanceBreakdown.balance)
    }

    @Test
    fun customCalorieTargetIsComparedAsFollowed() {
        val breakdown = maintenanceProfile.copy(customCalories = 2_600).maintenanceBreakdown

        assertEquals(2_102, breakdown.maintenanceCalories)
        assertEquals(2_600, breakdown.targetCalories)
        assertEquals(498, breakdown.dailyDifference)
        assertEquals(MaintenanceBreakdown.Balance.SURPLUS, breakdown.balance)
    }

    @Test
    fun smallDifferencesReadAsMaintenance() {
        val tolerance = MaintenanceBreakdown.MAINTENANCE_TOLERANCE

        assertEquals(MaintenanceBreakdown.Balance.MAINTENANCE, MaintenanceBreakdown(2_000, 2_000 - tolerance + 1).balance)
        assertEquals(MaintenanceBreakdown.Balance.MAINTENANCE, MaintenanceBreakdown(2_000, 2_000 + tolerance - 1).balance)
        assertEquals(MaintenanceBreakdown.Balance.DEFICIT, MaintenanceBreakdown(2_000, 2_000 - tolerance).balance)
        assertEquals(MaintenanceBreakdown.Balance.SURPLUS, MaintenanceBreakdown(2_000, 2_000 + tolerance).balance)
    }
}
