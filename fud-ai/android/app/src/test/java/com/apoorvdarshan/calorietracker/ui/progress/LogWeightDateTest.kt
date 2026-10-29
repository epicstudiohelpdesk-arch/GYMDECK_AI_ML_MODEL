package com.apoorvdarshan.calorietracker.ui.progress

import com.apoorvdarshan.calorietracker.data.crossesWeightGoal
import com.apoorvdarshan.calorietracker.models.WeightEntry
import com.apoorvdarshan.calorietracker.models.WeightGoal
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZonedDateTime

class LogWeightDateTest {
    private val zone = ZoneId.of("Europe/Prague")
    private val now = ZonedDateTime.of(2026, 10, 17, 9, 41, 27, 0, zone).toInstant()

    @Test
    fun olderWeighInIsLoggedOnItsOwnDay() {
        val day = LocalDate.of(2025, 3, 2)

        val logged = weighInTime(day, now, zone).atZone(zone)

        assertEquals(day, logged.toLocalDate())
        assertEquals(9, logged.hour)
        assertEquals(41, logged.minute)
    }

    @Test
    fun todaysWeighInKeepsTheCurrentInstant() {
        assertEquals(now, weighInTime(LocalDate.of(2026, 10, 17), now, zone))
    }

    @Test
    fun backdatedWeighInNeverCountsAsReachingTheGoal() {
        val latest = WeightEntry(date = Instant.parse("2026-10-01T08:00:00Z"), weightKg = 80.0)
        val older = WeightEntry(date = Instant.parse("2026-03-01T08:00:00Z"), weightKg = 74.0)
        val newer = WeightEntry(date = Instant.parse("2026-10-02T08:00:00Z"), weightKg = 74.0)

        assertFalse(crossesWeightGoal(older, latest, 75.0, WeightGoal.LOSE))
        assertTrue(crossesWeightGoal(newer, latest, 75.0, WeightGoal.LOSE))
        assertFalse(crossesWeightGoal(older.copy(weightKg = 90.0), latest, 85.0, WeightGoal.GAIN))
    }
}
