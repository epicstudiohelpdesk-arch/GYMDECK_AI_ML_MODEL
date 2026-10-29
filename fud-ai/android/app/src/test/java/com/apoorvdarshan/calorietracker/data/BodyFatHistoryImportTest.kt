package com.apoorvdarshan.calorietracker.data

import com.apoorvdarshan.calorietracker.models.BodyFatEntry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.Instant
import java.util.UUID

class BodyFatHistoryImportTest {
    private val day = Instant.parse("2026-09-21T08:00:00Z")

    @Test
    fun deletedBodyFatReadingIsNotResurrectedByAHealthConnectReimport() {
        val scaleReading = BodyFatEntry(id = UUID.randomUUID(), date = day, bodyFatFraction = 0.24)
        val kept = BodyFatEntry(id = UUID.randomUUID(), date = day.plusSeconds(86_400), bodyFatFraction = 0.23)

        // The user deleted the scale reading; granting history access re-runs the backfill.
        val merged = mergeExternalBodyFats(
            current = listOf(kept),
            incoming = listOf(scaleReading, kept),
            deletedIds = setOf(scaleReading.id.toString())
        )

        assertNull(merged)
    }

    @Test
    fun olderReadingsMergeInDateOrderAndCorrectionsUpsert() {
        val recent = BodyFatEntry(date = day, bodyFatFraction = 0.22)
        val older = BodyFatEntry(date = day.minusSeconds(86_400L * 500), bodyFatFraction = 0.28)
        val corrected = recent.copy(bodyFatFraction = 0.215)

        assertEquals(listOf(older, recent), mergeExternalBodyFats(listOf(recent), listOf(older), emptySet()))
        assertEquals(listOf(corrected), mergeExternalBodyFats(listOf(recent), listOf(corrected), emptySet()))
        assertNull(mergeExternalBodyFats(listOf(recent), listOf(recent), emptySet()))
    }
}
