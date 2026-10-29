package com.apoorvdarshan.calorietracker.services.voice

import com.apoorvdarshan.calorietracker.models.UserProfile

/** Restores only fields the goal edit changed, without overwriting later edits. */
internal fun restoreVoiceGoalEdit(current: UserProfile, before: UserProfile, applied: UserProfile): UserProfile {
    fun <T> restore(value: T, old: T, written: T): T {
        if (old == written) return value
        check(value == written) { "A goal changed after the voice edit; Undo cannot safely restore it." }
        return old
    }
    return current.copy(
        customCalories = restore(current.customCalories, before.customCalories, applied.customCalories),
        customProtein = restore(current.customProtein, before.customProtein, applied.customProtein),
        customCarbs = restore(current.customCarbs, before.customCarbs, applied.customCarbs),
        customFat = restore(current.customFat, before.customFat, applied.customFat),
        caloriesLocked = restore(current.caloriesLocked, before.caloriesLocked, applied.caloriesLocked),
        lockedMacros = restore(current.lockedMacros, before.lockedMacros, applied.lockedMacros)
    )
}
