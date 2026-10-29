package com.apoorvdarshan.calorietracker.models

import android.content.res.Resources
import androidx.annotation.StringRes
import com.apoorvdarshan.calorietracker.R
import java.text.NumberFormat
import java.text.ParsePosition
import java.util.Locale
import kotlin.math.roundToInt

/**
 * Energy display unit. Governs every user-visible calorie amount and every calorie
 * input. Stored values (food entries, goals, workout burns, Health Connect records,
 * AI requests and replies, exports) stay canonical kilocalories; only display and
 * typed input convert, so switching never rewrites data. Mirrors iOS `EnergyUnit`.
 */
enum class EnergyUnit(val storageValue: String) {
    KCAL("kcal"),
    KJ("kj");

    /** Short unit label shown next to numbers ("kcal" / "kJ"). */
    @get:StringRes
    val symbolRes: Int get() = if (this == KJ) R.string.unit_kj else R.string.unit_kcal

    /** "%1$,d kcal" / "%1$,d kJ" — takes a display value. */
    @get:StringRes
    val valueFormatRes: Int get() = if (this == KJ) R.string.kj_value_format else R.string.kcal_value_format

    /** The kJ twin of a kcal string resource, so each sentence keeps its own grammar. */
    @StringRes
    fun pick(@StringRes kcal: Int, @StringRes kj: Int): Int = if (this == KJ) kj else kcal

    /** Unrounded display amount, for charts and averages. */
    fun displayAmount(kcal: Double): Double = if (this == KJ) kcal * KILOJOULES_PER_KILOCALORIE else kcal

    /** Whole display units for a stored kcal amount (kJ rounds to whole numbers). */
    fun displayValue(kcal: Int): Int = displayAmount(kcal.toDouble()).roundToInt()

    /** Unrounded kcal for an amount typed in this unit. */
    fun kcalAmount(displayed: Double): Double = if (this == KJ) displayed / KILOJOULES_PER_KILOCALORIE else displayed

    /** Whole stored kcal for an amount typed in this unit. */
    fun toKcal(displayed: Double): Int = kcalAmount(displayed).roundToInt()

    /**
     * Parses an amount typed in this unit ("5021", "5,021", "5021.5") into whole
     * stored kcal. Null for empty, non-numeric or negative input.
     */
    fun parseToKcal(text: String, locale: Locale = Locale.getDefault()): Int? {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return null
        val position = ParsePosition(0)
        val parsed = NumberFormat.getNumberInstance(locale).parse(trimmed, position)
            ?.takeIf { position.index == trimmed.length }
            ?.toDouble()
        val value = parsed ?: trimmed.replace(',', '.').toDoubleOrNull() ?: return null
        if (!value.isFinite() || value < 0) return null
        return toKcal(value)
    }

    /** Grouped display number without a unit, e.g. "5,021". */
    fun number(kcal: Int, locale: Locale = Locale.getDefault()): String =
        NumberFormat.getIntegerInstance(locale).format(displayValue(kcal))

    /** Display amount with its unit, e.g. "1,200 kcal" or "5,021 kJ". */
    fun format(resources: Resources, kcal: Int): String = formatDisplayed(resources, displayValue(kcal))

    /** An amount already in this unit (e.g. a difference of display values) with its unit. */
    fun formatDisplayed(resources: Resources, value: Int): String = resources.getString(valueFormatRes, value)

    /** Calorie goal wheel: 800–6,000 kcal in 50 kcal steps, or the same span in 100 kJ steps. */
    val goalPickerRange: IntRange get() = if (this == KJ) 3_400..25_100 else 800..6_000
    val goalPickerStep: Int get() = if (this == KJ) 100 else 50

    /** Where the goal wheel opens: the display value snapped down to a step, clamped. */
    fun goalPickerStart(currentKcal: Int): Int {
        val snapped = (displayValue(currentKcal) / goalPickerStep) * goalPickerStep
        return snapped.coerceIn(goalPickerRange)
    }

    /**
     * Stored kcal goal for a wheel pick. A kcal goal almost never lands on a 100 kJ
     * step, so saving an untouched kJ wheel keeps the exact goal instead of nudging it.
     */
    fun goalKcal(picked: Int, currentKcal: Int): Int =
        if (this == KJ && picked == goalPickerStart(currentKcal)) currentKcal else toKcal(picked.toDouble())

    /**
     * Prompt line asking an AI model to answer a kJ user in kJ. Every energy number in
     * prompts, tool arguments and replies the app parses stays kcal; null for kcal users,
     * whose prompts don't change.
     */
    fun aiReplyInstruction(toolArguments: Boolean = false): String? {
        if (this != KJ) return null
        val line = "Energy unit: this user reads energy in kilojoules (kJ). Every energy number given to you is kcal; " +
            "whenever you state an energy amount to the user, convert it to kJ (1 kcal = 4.184 kJ, whole numbers)."
        return if (toolArguments) {
            "$line When the user gives an amount in kJ, convert it to kcal for any tool argument."
        } else line
    }

    companion object {
        /** Thermochemical calorie: 1 kcal = 4.184 kJ. */
        const val KILOJOULES_PER_KILOCALORIE = 4.184
        val Default = KCAL
        fun fromStorage(value: String?): EnergyUnit = entries.firstOrNull { it.storageValue == value } ?: Default
    }
}
