package com.apoorvdarshan.calorietracker.models

import com.apoorvdarshan.calorietracker.R
import com.apoorvdarshan.calorietracker.services.ai.CoachContext
import com.apoorvdarshan.calorietracker.services.voice.RepoFiles
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.Instant
import java.util.Locale

/** kcal / kJ display preference (#520): storage stays kcal, display and input convert. */
class EnergyUnitTest {
    @Test
    fun preferenceDefaultsToKilocalories() {
        assertEquals(EnergyUnit.KCAL, EnergyUnit.Default)
        assertEquals(EnergyUnit.KCAL, EnergyUnit.fromStorage(null))
        assertEquals(EnergyUnit.KCAL, EnergyUnit.fromStorage("calories"))
        assertEquals(EnergyUnit.KJ, EnergyUnit.fromStorage("kj"))
        // Same raw values as iOS ("kcal" / "kj"), so a shared mental model and backups line up.
        assertEquals(listOf("kcal", "kj"), EnergyUnit.entries.map { it.storageValue })
    }

    @Test
    fun kilocaloriesDisplayUnchanged() {
        assertEquals(1_234, EnergyUnit.KCAL.displayValue(1_234))
        assertEquals(1_234, EnergyUnit.KCAL.toKcal(1_234.0))
        assertEquals(R.string.kcal_value_format, EnergyUnit.KCAL.valueFormatRes)
        assertEquals(R.string.unit_kcal, EnergyUnit.KCAL.symbolRes)
        assertEquals(R.string.progress_avg_format, EnergyUnit.KCAL.pick(R.string.progress_avg_format, R.string.progress_avg_format_kj))
    }

    @Test
    fun kilojoulesConvertAndRoundToWholeNumbers() {
        assertEquals(0, EnergyUnit.KJ.displayValue(0))
        assertEquals(4, EnergyUnit.KJ.displayValue(1))
        assertEquals(418, EnergyUnit.KJ.displayValue(100))
        assertEquals(8_368, EnergyUnit.KJ.displayValue(2_000))
        assertEquals(1_046.0, EnergyUnit.KJ.displayAmount(250.0), 0.0001)
        assertEquals("8,368", EnergyUnit.KJ.number(2_000, Locale.US))
        assertEquals("8.368", EnergyUnit.KJ.number(2_000, Locale.GERMANY))
        assertEquals(R.string.kj_value_format, EnergyUnit.KJ.valueFormatRes)
        assertEquals(R.string.unit_kj, EnergyUnit.KJ.symbolRes)
        assertEquals(R.string.progress_avg_format_kj, EnergyUnit.KJ.pick(R.string.progress_avg_format, R.string.progress_avg_format_kj))
    }

    @Test
    fun kilojouleInputIsStoredAsKilocalories() {
        assertEquals(2_000, EnergyUnit.KJ.toKcal(8_368.0))
        assertEquals(100, EnergyUnit.KJ.toKcal(418.0))
        assertEquals(1.0, EnergyUnit.KJ.kcalAmount(4.184), 0.0)
        // Showing a stored kcal amount in kJ and saving it untouched never changes it.
        for (kcal in 0..10_000) {
            assertEquals(kcal, EnergyUnit.KJ.toKcal(EnergyUnit.KJ.displayValue(kcal).toDouble()))
        }
    }

    @Test
    fun typedAmountsParseInTheUserLocale() {
        assertEquals(2_000, EnergyUnit.KJ.parseToKcal("8368", Locale.US))
        assertEquals(2_000, EnergyUnit.KJ.parseToKcal("8,368", Locale.US))
        assertEquals(2_000, EnergyUnit.KJ.parseToKcal(" 8368.4 ", Locale.US))
        assertEquals(2_000, EnergyUnit.KJ.parseToKcal("8.368", Locale.GERMANY))
        assertEquals(100, EnergyUnit.KJ.parseToKcal("418,4", Locale.GERMANY))
        assertEquals(1_200, EnergyUnit.KCAL.parseToKcal("1200", Locale.US))
        assertNull(EnergyUnit.KJ.parseToKcal("", Locale.US))
        assertNull(EnergyUnit.KJ.parseToKcal("abc", Locale.US))
        assertNull(EnergyUnit.KJ.parseToKcal("12abc", Locale.US))
        assertNull(EnergyUnit.KJ.parseToKcal("-50", Locale.US))
    }

    @Test
    fun goalWheelCoversTheSameSpanInEitherUnit() {
        assertEquals(800..6_000, EnergyUnit.KCAL.goalPickerRange)
        assertEquals(50, EnergyUnit.KCAL.goalPickerStep)
        // Kilocalories keep the existing snap-to-step behaviour.
        assertEquals(2_000, EnergyUnit.KCAL.goalKcal(2_000, currentKcal = 2_037))

        val kj = EnergyUnit.KJ
        assertTrue(kj.toKcal(kj.goalPickerRange.first.toDouble()) >= 800)
        assertTrue(kj.toKcal(kj.goalPickerRange.last.toDouble()) <= 6_000)
        assertEquals(0, kj.goalPickerRange.first % kj.goalPickerStep)
        assertEquals(8_300, kj.goalPickerStart(2_000))
        // Saving the untouched kJ wheel keeps the exact kcal goal...
        assertEquals(2_000, kj.goalKcal(8_300, currentKcal = 2_000))
        // ...and a new pick is converted back to kcal.
        assertEquals(2_008, kj.goalKcal(8_400, currentKcal = 2_000))
        assertEquals(kj.goalPickerRange.first, kj.goalPickerStart(100))
    }

    @Test
    fun aiPromptsOnlyChangeForKilojouleUsers() {
        assertNull(EnergyUnit.KCAL.aiReplyInstruction())
        assertNull(EnergyUnit.KCAL.aiReplyInstruction(toolArguments = true))
        val hint = requireNotNull(EnergyUnit.KJ.aiReplyInstruction())
        assertTrue(hint.contains("4.184"))
        assertFalse(hint.contains("tool argument"))
        assertTrue(EnergyUnit.KJ.aiReplyInstruction(toolArguments = true)!!.contains("tool argument"))

        fun coachLines(unit: EnergyUnit) = CoachContext.summaryLines(
            profile = UserProfile(customCalories = 2_000),
            weights = emptyList(),
            bodyFats = emptyList(),
            foods = emptyList(),
            heightMetric = true,
            weightMetric = true,
            energyUnit = unit
        )
        assertTrue(coachLines(EnergyUnit.KCAL).none { it.contains("kilojoules") })
        assertTrue(coachLines(EnergyUnit.KJ).any { it.contains("kilojoules (kJ)") })
        // The data the model sees stays kcal either way.
        assertTrue(coachLines(EnergyUnit.KJ).any { it.contains("Calorie goal: 2000 kcal/day") })
    }

    @Test
    fun widgetSnapshotCarriesTheUnitAndConverts() {
        val json = Json { ignoreUnknownKeys = true }
        val snapshot = WidgetSnapshot(
            date = Instant.EPOCH,
            dayStart = Instant.EPOCH,
            calories = 1_247, calorieGoal = 2_000,
            protein = 0.0, proteinGoal = 150,
            carbs = 0.0, carbsGoal = 220,
            fat = 0.0, fatGoal = 70
        )
        // Snapshots from builds before #520 have no unit and stay kcal.
        val serializer = WidgetSnapshot.serializer()
        val legacy = json.encodeToString(serializer, snapshot).replace(Regex(""","energyUnitRaw":"[a-z]+""""), "")
        assertFalse(legacy.contains("energyUnitRaw"))
        val decodedLegacy = json.decodeFromString(serializer, legacy)
        assertFalse(decodedLegacy.usesKilojoules)
        assertEquals(1_247, decodedLegacy.displayCalories)
        assertEquals(decodedLegacy.caloriesRemaining, decodedLegacy.displayCaloriesRemaining)

        val kj = json.decodeFromString(
            serializer,
            json.encodeToString(serializer, snapshot.copy(energyUnitRaw = EnergyUnit.KJ.storageValue))
        )
        assertTrue(kj.usesKilojoules)
        assertEquals(1_247, kj.calories)
        assertEquals(5_217, kj.displayCalories)
        assertEquals(8_368, kj.displayCalorieGoal)
        assertEquals(8_368 - 5_217, kj.displayCaloriesRemaining)
        assertEquals(EnergyUnit.KJ.storageValue, kj.emptyForToday().energyUnitRaw)
    }

    @Test
    fun kilojouleDailySummaryNamesTheUnitOfEveryAmountInEveryLanguage() {
        val names = listOf("notif_summary_deficit_kj", "notif_summary_surplus_kj", "notif_summary_balanced_kj")
        val files = RepoFiles.find("src/main/res").listFiles().orEmpty()
            .map { File(it, "strings.xml") }.filter { it.exists() }
        var checked = 0
        for (file in files) {
            val xml = file.readText()
            for (name in names) {
                val text = Regex("<string name=\"$name\">(.*?)</string>").find(xml)?.groupValues?.get(1)
                    ?: error("${file.parentFile.name} is missing $name")
                // Eaten, burned and the difference are all converted, so each one names kJ.
                val amounts = Regex("%\\d\\\$d").findAll(text).count()
                val labelled = Regex("%\\d\\\$d (kJ|кДж)").findAll(text).count()
                assertEquals("${file.parentFile.name}/$name: $text", amounts, labelled)
                checked++
            }
        }
        // English plus the 18 app languages.
        assertEquals(19 * names.size, checked)
    }
}
