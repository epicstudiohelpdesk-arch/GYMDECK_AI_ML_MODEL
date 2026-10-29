package com.apoorvdarshan.calorietracker

import com.apoorvdarshan.calorietracker.services.health.HealthCapabilities
import com.apoorvdarshan.calorietracker.ui.progress.TimeRange
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

class HealthReadSyncTest {
    private fun caps(weight: Boolean = true, bodyFat: Boolean = true, history: Boolean = false) =
        HealthCapabilities(
            weightRead = weight,
            weightWrite = true,
            bodyFatRead = bodyFat,
            bodyFatWrite = true,
            nutritionRead = false,
            nutritionWrite = false,
            energyRead = false,
            activeEnergyWrite = false,
            stepsRead = false,
            historyRead = history
        )

    @Test
    fun grantingHistoryAccessLaterReRunsTheWeightBackfill() {
        // Token seeded before history access: Health Connect hid weigh-ins older than
        // 30 days before the first grant, and the token only reports new changes.
        val withoutHistory = healthReadTokenTypes(caps(history = false))
        val withHistory = healthReadTokenTypes(caps(history = true))
        val seeded = healthReadSeededTypes(withoutHistory)

        // Deletions were remembered since this token's backfill, so a full re-import is safe.
        assertEquals(HealthReadSync.FULL_BACKFILL, healthReadSync(hasToken = true, seeded, withHistory))
        assertEquals(HealthReadSync.CHANGES, healthReadSync(hasToken = true, healthReadSeededTypes(withHistory), withHistory))
        // Revoking history later must not force another full import.
        assertEquals(HealthReadSync.CHANGES, healthReadSync(hasToken = true, healthReadSeededTypes(withHistory), withoutHistory))
        assertEquals(HealthReadSync.FULL_BACKFILL, healthReadSync(hasToken = false, emptySet(), withHistory))
    }

    @Test
    fun historyGrantedOverATokenFromBeforeDeletionsWereRememberedOnlyImportsOlderRecords() {
        // Seeded by an earlier build: weigh-ins deleted back then have no remembered id, and
        // a full re-import of the window that backfill saw would bring them back.
        val earlierBuild = setOf("weight", "bodyfat")
        val withHistory = healthReadTokenTypes(caps(history = true))

        assertEquals(HealthReadSync.OLDER_HISTORY_ONLY, healthReadSync(hasToken = true, earlierBuild, withHistory))
        assertEquals(HealthReadSync.CHANGES, healthReadSync(hasToken = true, healthReadTypesWithHistory(earlierBuild), withHistory))
        // A metric that became readable still needs its whole history.
        assertEquals(HealthReadSync.FULL_BACKFILL, healthReadSync(hasToken = true, setOf("weight"), withHistory))

        // Only records nothing could read before history access: older than 30 days before install.
        val installed = Instant.parse("2026-03-01T10:00:00Z")
        assertEquals(Instant.parse("2026-01-30T10:00:00Z"), healthRecordsHiddenWithoutHistoryBefore(installed))
    }

    @Test
    fun olderHistoryImportReachesTheReadingsHiddenBetweenInstallAndFirstGrant() {
        // Installed in January, connected in March: that backfill read from 30 days before
        // March, so the readings it imported (and the history still holds) begin in February.
        // Everything older is imported, including December to February, not just what
        // predates 30 days before install.
        val installed = Instant.parse("2026-01-10T10:00:00Z")
        val held = listOf(Instant.parse("2026-03-01T07:00:00Z"), Instant.parse("2026-02-08T07:00:00Z"))

        assertEquals(Instant.parse("2026-02-08T07:00:00Z"), healthHistoryImportCutoff(held, installed))
        // Nothing held from another app: the window began no earlier than 30 days before install.
        assertEquals(Instant.parse("2025-12-11T10:00:00Z"), healthHistoryImportCutoff(emptyList(), installed))
        assertNull(healthHistoryImportCutoff(emptyList(), firstInstall = null))
    }

    @Test
    fun historyMarkerOnlyCountsWithAWeightOrBodyFatRead() {
        assertEquals(emptySet<String>(), healthReadTokenTypes(caps(weight = false, bodyFat = false, history = true)))
        assertEquals(setOf("weight"), healthReadTokenTypes(caps(bodyFat = false)))
    }

    @Test
    fun backfillWindowCoversTheAllTimeProgressRange() {
        assertTrue(HEALTH_BODY_BACKFILL_DAYS >= TimeRange.ALL_TIME.days)
    }
}
