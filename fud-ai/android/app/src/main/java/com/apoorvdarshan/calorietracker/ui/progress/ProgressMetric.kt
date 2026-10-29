package com.apoorvdarshan.calorietracker.ui.progress

enum class ProgressMetric {
    WEIGHT,
    BODY_FAT,
    WORKOUTS,
    STEPS
}

/** Stable preference order; conditional metrics disappear without reordering the remaining tabs. */
internal fun availableProgressMetrics(
    bodyFatAvailable: Boolean,
    workoutHistoryAvailable: Boolean,
    stepsAvailable: Boolean = false
): List<ProgressMetric> = buildList {
    add(ProgressMetric.WEIGHT)
    if (bodyFatAvailable) add(ProgressMetric.BODY_FAT)
    if (workoutHistoryAvailable) add(ProgressMetric.WORKOUTS)
    if (stepsAvailable) add(ProgressMetric.STEPS)
}
