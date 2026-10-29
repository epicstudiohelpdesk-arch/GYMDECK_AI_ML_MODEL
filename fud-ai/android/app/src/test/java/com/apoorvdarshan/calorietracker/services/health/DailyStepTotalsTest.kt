package com.apoorvdarshan.calorietracker.services.health

import java.time.LocalDate
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class DailyStepTotalsTest {
    @Test
    fun readsYearLongChunksAndKeepsOnlyDaysWithSteps() = runBlocking {
        val start = LocalDate.parse("2024-01-01")
        val lastDay = LocalDate.parse("2025-06-30")
        val chunks = mutableListOf<Pair<LocalDate, LocalDate>>()

        val totals = collectDailyStepTotals(start, lastDay, onFailure = { fail("unexpected $it") }) { from, to ->
            chunks += from to to
            listOf(from to 4_200L, from.plusDays(1) to 0L)
        }

        assertEquals(
            listOf(
                start to LocalDate.parse("2024-12-30"),
                LocalDate.parse("2024-12-31") to lastDay
            ),
            chunks
        )
        assertEquals(listOf(start to 4_200, LocalDate.parse("2024-12-31") to 4_200), totals)
    }

    @Test
    fun aFailedReadIsReportedAndReadsAsNoSteps() = runBlocking {
        var reported: Exception? = null
        val totals = collectDailyStepTotals(
            LocalDate.parse("2026-10-11"),
            LocalDate.parse("2026-10-17"),
            onFailure = { reported = it }
        ) { _, _ -> throw IllegalStateException("binder died") }

        assertTrue(totals.isEmpty())
        assertTrue(reported is IllegalStateException)
    }

    @Test
    fun cancellationIsRethrownInsteadOfReadingAsAnEmptyWindow() = runBlocking {
        var reported: Exception? = null
        try {
            collectDailyStepTotals(
                LocalDate.parse("2026-10-11"),
                LocalDate.parse("2026-10-17"),
                onFailure = { reported = it }
            ) { _, _ -> throw CancellationException("window changed") }
            fail("cancellation was swallowed")
        } catch (expected: CancellationException) {
            assertEquals("window changed", expected.message)
        }
        assertEquals(null, reported)
    }
}
