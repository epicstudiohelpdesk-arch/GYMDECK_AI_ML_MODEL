package com.apoorvdarshan.calorietracker.ui.progress

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.DayOfWeek
import java.time.LocalDate

class StepsProgressAggregationTest {
    @Test
    fun summaryAveragesOnlyDaysWithStepsAndPicksTheBestDay() {
        val days = listOf(
            LocalDate.parse("2026-10-12") to 6_000,
            LocalDate.parse("2026-10-14") to 12_500,
            LocalDate.parse("2026-10-15") to 8_001
        )

        val summary = stepsSummary(days)

        assertEquals(26_501, summary.total)
        assertEquals(8_834, summary.average)
        assertEquals(LocalDate.parse("2026-10-14") to 12_500, summary.best)
    }

    @Test
    fun emptySummaryIsZero() {
        val summary = stepsSummary(emptyList())
        assertEquals(0, summary.total)
        assertEquals(0, summary.average)
        assertNull(summary.best)
    }

    @Test
    fun weeklyBarsAverageEachCalendarWeek() {
        val days = listOf(
            // Week of Mon 5 Oct 2026.
            LocalDate.parse("2026-10-05") to 4_000,
            LocalDate.parse("2026-10-11") to 6_000,
            // Week of Mon 12 Oct 2026.
            LocalDate.parse("2026-10-13") to 9_000
        )
        val start = LocalDate.parse("2026-10-05")
        val end = LocalDate.parse("2026-10-13")

        assertEquals(
            listOf(LocalDate.parse("2026-10-05") to 5_000, LocalDate.parse("2026-10-12") to 9_000),
            stepChartBars(days, start, end, weekly = true, firstDayOfWeek = DayOfWeek.MONDAY)
        )
        // Sunday-first locales bucket the Sunday with the following week.
        assertEquals(
            listOf(LocalDate.parse("2026-10-04") to 4_000, LocalDate.parse("2026-10-11") to 7_500),
            stepChartBars(days, start, end, weekly = true, firstDayOfWeek = DayOfWeek.SUNDAY)
        )
    }

    @Test
    fun dailyBarsKeepEveryDayOfTheWindowSoBarsLineUpWithTheirDates() {
        // Steps on Oct 1, 2 and 30 only: Oct 2 must sit next to Oct 1, not halfway along.
        val days = listOf(
            LocalDate.parse("2026-10-30") to 7_000,
            LocalDate.parse("2026-10-01") to 5_000,
            LocalDate.parse("2026-10-02") to 6_000
        )
        val start = LocalDate.parse("2026-10-01")
        val end = LocalDate.parse("2026-10-31")

        val bars = stepChartBars(days, start, end, weekly = false, firstDayOfWeek = DayOfWeek.MONDAY)

        assertEquals(31, bars.size)
        assertEquals((0L..30L).map { start.plusDays(it) }, bars.map { it.first })
        assertEquals(5_000, bars[0].second)
        assertEquals(6_000, bars[1].second)
        assertEquals(7_000, bars[29].second)
        assertEquals(0, bars[2].second)
        assertEquals(0, bars[30].second)
        // The averages still ignore the empty days.
        assertEquals(6_000, stepsSummary(days).average)
    }

    @Test
    fun weeklyBarsKeepEmptyWeeksBetweenWeeksWithSteps() {
        val days = listOf(
            LocalDate.parse("2026-01-06") to 8_000,
            LocalDate.parse("2026-02-03") to 4_000
        )

        val bars = stepChartBars(
            days,
            start = LocalDate.parse("2026-01-05"),
            end = LocalDate.parse("2026-02-08"),
            weekly = true,
            firstDayOfWeek = DayOfWeek.MONDAY
        )

        assertEquals(
            listOf("2026-01-05", "2026-01-12", "2026-01-19", "2026-01-26", "2026-02-02").map(LocalDate::parse),
            bars.map { it.first }
        )
        assertEquals(listOf(8_000, 0, 0, 0, 4_000), bars.map { it.second })
    }

    @Test
    fun onlyRangesLongerThanThreeMonthsUseWeeklyBars() {
        val today = LocalDate.parse("2026-10-17")
        val (threeMonthStart, threeMonthEnd) = TimeRange.THREE_MONTHS.dateRange(today)
        val (sixMonthStart, sixMonthEnd) = TimeRange.SIX_MONTHS.dateRange(today)

        assertFalse(showsWeeklyStepBars(threeMonthStart, threeMonthEnd))
        assertTrue(showsWeeklyStepBars(sixMonthStart, sixMonthEnd))
    }

    @Test
    fun historyNoteOnlyShowsForOldWindowsWithoutTheHistoryGrant() {
        val today = LocalDate.parse("2026-10-17")

        assertFalse(stepsHistoryMayBeMissing(today.minusDays(29), today, hasHistoryAccess = false))
        assertTrue(stepsHistoryMayBeMissing(today.minusDays(89), today, hasHistoryAccess = false))
        assertFalse(stepsHistoryMayBeMissing(today.minusDays(89), today, hasHistoryAccess = true))
    }
}
