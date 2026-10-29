package com.apoorvdarshan.calorietracker.services.voice

import com.apoorvdarshan.calorietracker.models.AutoBalanceMacro
import com.apoorvdarshan.calorietracker.models.UserProfile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class VoiceProfileUndoTest {
    @Test
    fun calorieUndoPreservesLaterProfileChanges() {
        val before = UserProfile(name = "Before", weightKg = 70.0)
        val applied = before.applyCaloriesEdit(2200).copy(caloriesLocked = true)
        val current = applied.copy(name = "After", weightKg = 72.0, allergenSensitivities = listOf("Peanuts"))
        assertEquals(before.copy(name = "After", weightKg = 72.0, allergenSensitivities = listOf("Peanuts")),
            restoreVoiceGoalEdit(current, before, applied))
    }

    @Test
    fun macroUndoRestoresRebalancedFieldsButPreservesUntouchedGoals() {
        val before = UserProfile(customCalories = 2000, customProtein = 100, customCarbs = 250, customFat = 66)
        val applied = before.applyMacroEdit(AutoBalanceMacro.PROTEIN, 120)!!
            .toggledMacroLock(AutoBalanceMacro.PROTEIN)
        val current = applied.copy(customCarbs = 260, name = "Later name")
        assertEquals(before.copy(customCarbs = 260, name = "Later name"), restoreVoiceGoalEdit(current, before, applied))
    }

    @Test
    fun undoRefusesToOverwriteANewerEditOfAChangedGoal() {
        val before = UserProfile()
        val applied = before.applyCaloriesEdit(2200).copy(caloriesLocked = true)
        assertThrows(IllegalStateException::class.java) {
            restoreVoiceGoalEdit(applied.copy(customCalories = 2300), before, applied)
        }
    }
}
