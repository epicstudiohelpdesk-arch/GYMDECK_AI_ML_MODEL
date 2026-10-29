package com.apoorvdarshan.calorietracker.models

import java.util.Locale
import kotlin.math.roundToInt

/**
 * The three one-tap water amounts in the Home + menu. Stored in milliliters as
 * comma-separated text ("250,500,750"), the same format iOS uses.
 */
object WaterQuickAddPresets {
    const val STORAGE_KEY = "waterQuickAddPresetsMl"
    val Defaults = listOf(250, 500, 750)
    val ValidRange = 1..5_000

    /** Missing or malformed values fall back to the defaults; valid ones come back smallest first. */
    fun decode(raw: String?): List<Int> {
        val values = raw.orEmpty()
            .split(',')
            .mapNotNull { it.trim().toIntOrNull() }
        if (values.size != Defaults.size || values.any { it !in ValidRange }) return Defaults
        return values.sorted()
    }

    fun encode(presets: List<Int>): String = presets.sorted().joinToString(",")

    /** "250 · 500 · 750 ml" for the settings row. */
    fun summary(presets: List<Int>, unit: WaterUnit): String =
        presets.joinToString(" · ") { unit.displayValue(it) } + " ${unit.symbol}"

    /** Plain digits for a text field: no grouping separators, at most one decimal for fl oz. */
    fun editingText(milliliters: Int, unit: WaterUnit): String {
        if (unit == WaterUnit.MILLILITERS) return milliliters.toString()
        val ounces = (unit.displayAmount(milliliters) * 10).roundToInt() / 10.0
        return if (ounces % 1.0 == 0.0) ounces.toInt().toString() else String.format(Locale.US, "%.1f", ounces)
    }

    /** Keeps digits (and one decimal for fl oz), like the custom water amount field. */
    fun filteredInput(value: String, unit: WaterUnit): String {
        val filtered = value.filter { it.isDigit() || (unit == WaterUnit.FLUID_OUNCES && (it == '.' || it == ',')) }
        val normalized = filtered.replace(',', '.')
        val pieces = normalized.split('.', limit = 3)
        return if (pieces.size > 1) "${pieces[0]}.${pieces[1].take(1)}".take(6) else normalized.take(5)
    }

    /** Milliliters for an edited amount, or null when it is empty or outside [ValidRange]. */
    fun millilitersFromEditingText(text: String, unit: WaterUnit): Int? {
        val value = text.replace(',', '.').toDoubleOrNull()?.takeIf { it > 0 } ?: return null
        return unit.toMilliliters(value).takeIf { it in ValidRange }
    }
}
