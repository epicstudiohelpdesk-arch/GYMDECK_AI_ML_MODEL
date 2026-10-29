package com.apoorvdarshan.calorietracker.models

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WaterQuickAddPresetsTest {
    @Test
    fun invalidStorageFallsBackToDefaults() {
        listOf(null, "", "garbage", "250,500", "250,500,750,1000", "0,500,750", "250,500,5001", "250,abc,750")
            .forEach { raw ->
                assertEquals("raw=$raw", listOf(250, 500, 750), WaterQuickAddPresets.decode(raw))
            }
    }

    @Test
    fun customPresetsRoundTripSmallestFirst() {
        val encoded = WaterQuickAddPresets.encode(listOf(750, 200, 500))
        assertEquals("200,500,750", encoded)
        assertEquals(listOf(200, 500, 750), WaterQuickAddPresets.decode(encoded))
        assertEquals(listOf(200, 200, 330), WaterQuickAddPresets.decode(" 330 , 200,200 "))
    }

    @Test
    fun editingTextUsesPlainDigitsInTheUsersUnit() {
        assertEquals("1000", WaterQuickAddPresets.editingText(1_000, WaterUnit.MILLILITERS))
        assertEquals("8", WaterQuickAddPresets.editingText(237, WaterUnit.FLUID_OUNCES))
        assertEquals("8.5", WaterQuickAddPresets.editingText(250, WaterUnit.FLUID_OUNCES))
    }

    @Test
    fun editedAmountsConvertToMillilitersWithinTheAllowedRange() {
        assertEquals(200, WaterQuickAddPresets.millilitersFromEditingText("200", WaterUnit.MILLILITERS))
        assertEquals(237, WaterQuickAddPresets.millilitersFromEditingText("8", WaterUnit.FLUID_OUNCES))
        assertEquals(251, WaterQuickAddPresets.millilitersFromEditingText("8,5", WaterUnit.FLUID_OUNCES))
        assertNull(WaterQuickAddPresets.millilitersFromEditingText("", WaterUnit.MILLILITERS))
        assertNull(WaterQuickAddPresets.millilitersFromEditingText("0", WaterUnit.MILLILITERS))
        assertNull(WaterQuickAddPresets.millilitersFromEditingText("5001", WaterUnit.MILLILITERS))
        assertNull(WaterQuickAddPresets.millilitersFromEditingText("170", WaterUnit.FLUID_OUNCES))
    }

    @Test
    fun inputFilterKeepsDigitsAndOneDecimalForFluidOunces() {
        assertEquals("250", WaterQuickAddPresets.filteredInput("2a5.0", WaterUnit.MILLILITERS))
        assertEquals("8.5", WaterQuickAddPresets.filteredInput("8,57", WaterUnit.FLUID_OUNCES))
    }
}
