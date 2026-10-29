package com.apoorvdarshan.calorietracker.ui.components

import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.res.stringResource
import com.apoorvdarshan.calorietracker.models.EnergyUnit

/**
 * The user's energy display unit (kcal / kJ), provided once at the Compose root in
 * MainActivity so every screen, sheet, the voice overlay and the shared-meal import sheet
 * show calories the same way. Values stay kcal.
 */
val LocalEnergyUnit = compositionLocalOf { EnergyUnit.Default }

/** "1,200 kcal" / "5,021 kJ" for a stored kcal amount. */
@Composable
fun energyText(kcal: Int): String {
    val unit = LocalEnergyUnit.current
    return stringResource(unit.valueFormatRes, unit.displayValue(kcal))
}

/** An amount already in the display unit (e.g. a difference of display values) with its unit. */
@Composable
fun energyTextDisplayed(value: Int): String =
    stringResource(LocalEnergyUnit.current.valueFormatRes, value)

/** The unit label shown next to calorie numbers and inputs ("kcal" / "kJ"). */
@Composable
fun energyUnitLabel(): String = stringResource(LocalEnergyUnit.current.symbolRes)
