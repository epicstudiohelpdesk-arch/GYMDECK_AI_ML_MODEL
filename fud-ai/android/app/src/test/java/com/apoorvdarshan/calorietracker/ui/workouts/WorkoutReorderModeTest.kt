package com.apoorvdarshan.calorietracker.ui.workouts

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WorkoutReorderModeTest {
    @Test fun reorderModeStaysOnItsDayWhileTwoOrMoreExercisesRemain() {
        assertEquals("2026-09-08", retainedReorderDateKey("2026-09-08", "2026-09-08", 2))
        assertNull(retainedReorderDateKey(null, "2026-09-08", 3))
    }

    @Test fun changingDaysOrDroppingBelowTwoExercisesEndsReorderMode() {
        // The cleared key is what the diary stores, so returning to the day does not resume it.
        assertNull(retainedReorderDateKey("2026-09-08", "2026-09-09", 3))
        assertNull(retainedReorderDateKey("2026-09-08", "2026-09-08", 1))
        assertNull(retainedReorderDateKey("2026-09-08", "2026-09-08", 0))
    }
}
