package com.apoorvdarshan.calorietracker.services.voice

import com.apoorvdarshan.calorietracker.models.MealType
import com.apoorvdarshan.calorietracker.ui.theme.AppThemeColor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.time.LocalDate
import java.time.LocalTime

class VoiceArgumentsTest {
    private val today = LocalDate.parse("2026-10-16")

    @Test
    fun datesAcceptIsoTodayAndYesterday() {
        assertEquals(today, VoiceArguments.parseDate("today", today))
        assertEquals(today.minusDays(1), VoiceArguments.parseDate(" Yesterday ", today))
        assertEquals(LocalDate.parse("2026-02-28"), VoiceArguments.parseDate("2026-02-28", today))
        assertNull(VoiceArguments.parseDate("tomorrow", today))
        assertNull(VoiceArguments.parseDate("2026-02-30", today))
        assertNull(VoiceArguments.parseDate("16/10/2026", today))
    }

    @Test
    fun timesAre24Hour() {
        assertEquals(LocalTime.of(7, 5), VoiceArguments.parseTime("07:05"))
        assertEquals(LocalTime.of(19, 30), VoiceArguments.parseTime("19:30"))
        assertEquals(LocalTime.of(9, 0), VoiceArguments.parseTime("9:00"))
        assertNull(VoiceArguments.parseTime("24:00"))
        assertNull(VoiceArguments.parseTime("7pm"))
        assertNull(VoiceArguments.parseTime("12:60"))
        assertEquals("07:05", VoiceArguments.formatTime(LocalTime.of(7, 5)))
    }

    @Test
    fun waterUnitsConvertToMilliliters() {
        assertEquals(500, VoiceArguments.waterMilliliters(500.0, "ml"))
        assertEquals(1_500, VoiceArguments.waterMilliliters(1.5, "l"))
        assertEquals(237, VoiceArguments.waterMilliliters(8.0, "oz"))
        assertEquals(480, VoiceArguments.waterMilliliters(2.0, "cup"))
        assertEquals(250, VoiceArguments.waterMilliliters(1.0, "glass"))
        assertNull(VoiceArguments.waterMilliliters(1.0, "bucket"))
        assertNull(VoiceArguments.waterMilliliters(0.0, "ml"))
        assertNull(VoiceArguments.waterMilliliters(-2.0, "cup"))
    }

    @Test
    fun weightsConvertToKilograms() {
        assertEquals(80.0, VoiceArguments.weightKilograms(80.0, "kg")!!, 0.0)
        assertEquals(68.04, VoiceArguments.weightKilograms(150.0, "lb")!!, 0.01)
        assertEquals(68.04, VoiceArguments.weightKilograms(150.0, "lbs")!!, 0.01)
        assertNull(VoiceArguments.weightKilograms(150.0, "stone"))
        assertNull(VoiceArguments.weightKilograms(Double.NaN, "kg"))
    }

    @Test
    fun mealsBooleansAndServingGrams() {
        assertEquals(MealType.BREAKFAST, VoiceArguments.parseMeal("Breakfast"))
        assertEquals(MealType.SNACK, VoiceArguments.parseMeal("snack"))
        assertNull(VoiceArguments.parseMeal("brunch"))
        assertEquals("other", VoiceArguments.mealWireValue(MealType.OTHER))
        assertEquals(true, VoiceArguments.parseBoolean("Yes"))
        assertEquals(false, VoiceArguments.parseBoolean("off"))
        assertNull(VoiceArguments.parseBoolean("maybe"))
        assertEquals(250.0, VoiceArguments.gramsIn("1 bowl (250 g)")!!, 0.0)
        assertEquals(12.5, VoiceArguments.gramsIn("12,5g")!!, 0.0)
        assertNull(VoiceArguments.gramsIn("2 slices"))
    }

    @Test
    fun settingKeysMatchTheCatalogEnum() {
        val catalogKeys = RepoFiles.catalog.first { it.name == "update_setting" }
            .parameters["properties"].toString()
        VoiceSettingKey.entries.forEach { key ->
            assertTrue("${key.wireValue} is in the catalog", catalogKeys.contains("\"${key.wireValue}\""))
            assertEquals(key, VoiceSettingKey.fromWire(key.wireValue))
        }
        assertNull(VoiceSettingKey.fromWire("font_size"))
    }

    @Test
    fun settingValuesAreValidated() {
        val voices = LiveProvider.GEMINI.voices
        assertEquals(SettingValue.ThemeColor(AppThemeColor.ROSE_GOLD), VoiceSettingValues.parse(VoiceSettingKey.THEME_COLOR, "Rose Gold", voices))
        assertEquals(SettingValue.ThemeColor(AppThemeColor.FUD_PINK), VoiceSettingValues.parse(VoiceSettingKey.THEME_COLOR, "fudPink", voices))
        assertEquals(SettingValue.ThemeColor(AppThemeColor.MOCHA_BROWN), VoiceSettingValues.parse(VoiceSettingKey.THEME_COLOR, "mocha_brown", voices))
        assertEquals(SettingValue.Appearance("system"), VoiceSettingValues.parse(VoiceSettingKey.APPEARANCE, "automatic", voices))
        assertEquals(SettingValue.Appearance("dark"), VoiceSettingValues.parse(VoiceSettingKey.APPEARANCE, "Dark", voices))
        assertEquals(SettingValue.Units(metric = false), VoiceSettingValues.parse(VoiceSettingKey.UNITS, "imperial", voices))
        assertEquals(SettingValue.Amount(2_200), VoiceSettingValues.parse(VoiceSettingKey.CALORIE_GOAL, "2200 kcal", voices))
        assertEquals(SettingValue.Amount(2_250), VoiceSettingValues.parse(VoiceSettingKey.CALORIE_GOAL, "2,250", voices))
        assertEquals(SettingValue.Amount(140), VoiceSettingValues.parse(VoiceSettingKey.PROTEIN_GOAL_G, "140", voices))
        assertEquals(SettingValue.Amount(2_500), VoiceSettingValues.parse(VoiceSettingKey.WATER_GOAL_ML, "2500", voices))
        assertEquals(SettingValue.Voice("Puck"), VoiceSettingValues.parse(VoiceSettingKey.ASSISTANT_VOICE, "puck", voices))
        assertEquals(SettingValue.Toggle(false), VoiceSettingValues.parse(VoiceSettingKey.ASSISTANT_CONFIRM_SAVES, "false", voices))

        rejects(VoiceSettingKey.THEME_COLOR, "plaid")
        rejects(VoiceSettingKey.APPEARANCE, "sepia")
        rejects(VoiceSettingKey.UNITS, "nautical")
        rejects(VoiceSettingKey.CALORIE_GOAL, "500")
        rejects(VoiceSettingKey.CALORIE_GOAL, "-1,000")
        rejects(VoiceSettingKey.CALORIE_GOAL, "-1.000")
        rejects(VoiceSettingKey.CALORIE_GOAL, "lots")
        rejects(VoiceSettingKey.FAT_GOAL_G, "900")
        rejects(VoiceSettingKey.WATER_GOAL_ML, "20000")
        rejects(VoiceSettingKey.ASSISTANT_VOICE, "marin")
        rejects(VoiceSettingKey.ASSISTANT_AUTO_CAPTURE, "sometimes")
    }

    private fun rejects(key: VoiceSettingKey, value: String) {
        try {
            VoiceSettingValues.parse(key, value, LiveProvider.GEMINI.voices)
            fail("$value should be rejected for ${key.wireValue}")
        } catch (failure: ToolFailure) {
            assertEquals(ToolError.INVALID_ARGUMENTS, failure.error)
        }
    }

    @Test
    fun screensAndSettingsSectionsMatchTheCatalog() {
        val openScreen = RepoFiles.catalog.first { it.name == "open_screen" }.parameters.toString()
        VoiceScreen.entries.forEach { assertTrue(openScreen.contains("\"${it.wireValue}\"")) }
        VoiceSettingsSection.entries.forEach { assertTrue(openScreen.contains("\"${it.wireValue}\"")) }
        assertEquals(VoiceSettingsSection.VOICE_ASSISTANT, VoiceSettingsSection.fromWire("voice_assistant"))
        assertNull(VoiceScreen.fromWire("kitchen"))
    }

    @Test
    fun confirmationPolicyFollowsTheContract() {
        assertFalse(ConfirmationPolicy.needsConfirmation(ToolConfirm.NEVER, confirmSaves = true, userConfirmed = false))
        assertTrue(ConfirmationPolicy.needsConfirmation(ToolConfirm.ALWAYS, confirmSaves = false, userConfirmed = false))
        assertFalse(ConfirmationPolicy.needsConfirmation(ToolConfirm.ALWAYS, confirmSaves = false, userConfirmed = true))
        assertTrue(ConfirmationPolicy.needsConfirmation(ToolConfirm.SETTING, confirmSaves = true, userConfirmed = false))
        assertFalse(ConfirmationPolicy.needsConfirmation(ToolConfirm.SETTING, confirmSaves = true, userConfirmed = true))
        assertFalse(ConfirmationPolicy.needsConfirmation(ToolConfirm.SETTING, confirmSaves = false, userConfirmed = false))
    }

    @Test
    fun undoRegistryExpiresAfterItsWindow() {
        var now = 0L
        val registry = UndoRegistry({ now })
        val entry = registry.register(VoiceChange.LogWater(250)) {}
        now = UndoRegistry.WINDOW_MILLIS - 1
        assertEquals(entry, registry.take(entry.id))
        val late = registry.register(VoiceChange.LogWater(250)) {}
        now += UndoRegistry.WINDOW_MILLIS
        assertEquals(listOf(late.id), registry.expire())
        assertNull(registry.take(late.id))
    }

    @Test
    fun signaturesIgnoreUserConfirmedAndKeyOrder() {
        val a = ToolArgs(kotlinx.serialization.json.buildJsonObject {
            put("unit", kotlinx.serialization.json.JsonPrimitive("ml"))
            put("amount", kotlinx.serialization.json.JsonPrimitive(500))
        })
        val b = ToolArgs(kotlinx.serialization.json.buildJsonObject {
            put("amount", kotlinx.serialization.json.JsonPrimitive(500))
            put("user_confirmed", kotlinx.serialization.json.JsonPrimitive(true))
            put("unit", kotlinx.serialization.json.JsonPrimitive("ml"))
        })
        assertEquals(a.signature("log_water"), b.signature("log_water"))
        assertFalse(a.userConfirmed)
        assertTrue(b.userConfirmed)
    }
}
