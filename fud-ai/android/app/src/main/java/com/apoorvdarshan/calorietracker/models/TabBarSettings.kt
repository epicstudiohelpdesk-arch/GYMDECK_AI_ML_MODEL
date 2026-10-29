package com.apoorvdarshan.calorietracker.models

/**
 * Tabs the user can hide from the bottom bar. Home and Settings are always shown.
 * Values are the tab routes, stored comma-separated ("coach,workouts"), the same format iOS uses.
 */
object TabBarSettings {
    const val STORAGE_KEY = "hiddenTabs"
    val Hideable = listOf("progress", "coach", "workouts")

    /** Unknown values (including Home and Settings) are ignored, so a missing key shows every tab. */
    fun decode(raw: String?): Set<String> =
        raw.orEmpty().split(',').map { it.trim() }.filter { it in Hideable }.toSet()

    fun encode(hidden: Set<String>): String = Hideable.filter { it in hidden }.joinToString(",")

    /**
     * The stored value after showing or hiding one tab. Applied to what is stored right now,
     * so the other tabs keep their current state even if a screen still shows an older set.
     */
    fun withTabHidden(raw: String?, route: String, hidden: Boolean): String {
        val current = decode(raw)
        if (route !in Hideable) return encode(current)
        return encode(if (hidden) current + route else current - route)
    }
}
