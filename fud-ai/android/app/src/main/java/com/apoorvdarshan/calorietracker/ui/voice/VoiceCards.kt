package com.apoorvdarshan.calorietracker.ui.voice

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.Restaurant
import androidx.compose.material.icons.filled.TaskAlt
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.apoorvdarshan.calorietracker.R
import com.apoorvdarshan.calorietracker.models.MealType
import com.apoorvdarshan.calorietracker.models.WaterUnit
import com.apoorvdarshan.calorietracker.models.formatFastingDuration
import com.apoorvdarshan.calorietracker.services.voice.DraftItem
import com.apoorvdarshan.calorietracker.services.voice.LiveProvider
import com.apoorvdarshan.calorietracker.services.voice.VoiceCard
import com.apoorvdarshan.calorietracker.services.voice.VoiceChange
import com.apoorvdarshan.calorietracker.services.voice.VoiceSettingKey
import com.apoorvdarshan.calorietracker.ui.components.LocalEnergyUnit
import com.apoorvdarshan.calorietracker.ui.theme.AppColors
import com.apoorvdarshan.calorietracker.ui.theme.AppThemeColor
import kotlinx.coroutines.delay
import kotlin.math.roundToInt

private val CardShape = RoundedCornerShape(22.dp)
private val CardBackground = Color(0xFF16171C).copy(alpha = 0.94f)
private val CardText = Color.White
private val CardMuted = Color.White.copy(alpha = 0.62f)
private val Destructive = Color(0xFFFF453A)

/** Tap handling without a ripple, for custom controls drawn over the camera and scrim. */
internal fun Modifier.clickableNoRipple(onClick: () -> Unit): Modifier =
    clickable(interactionSource = null, indication = null, onClick = onClick)

/** Callbacks a card can trigger. */
internal class CardActions(
    val confirm: (String) -> Unit,
    val cancel: (String) -> Unit,
    val undo: (String) -> Unit,
    val log: (String) -> Unit,
    val dismiss: (String) -> Unit
)

/** Unit context for describing changes. */
internal data class CardUnits(val water: WaterUnit, val metric: Boolean)

@Composable
internal fun VoiceCardView(card: VoiceCard, actions: CardActions, units: CardUnits, compact: Boolean = false) {
    when (card) {
        is VoiceCard.Draft -> DraftCardView(card, actions, compact)
        is VoiceCard.Confirmation -> ConfirmationCardView(card, actions, units)
        is VoiceCard.Undo -> UndoCardView(card, actions, units)
    }
}

@Composable
private fun CardFrame(testTag: String, content: @Composable () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(CardShape)
            .background(CardBackground)
            .border(1.dp, Color.White.copy(alpha = 0.10f), CardShape)
            .testTag(testTag)
            .padding(horizontal = 16.dp, vertical = 12.dp)
    ) { content() }
}

@Composable
private fun CardButton(text: String, filled: Boolean, color: Color = AppColors.Calorie, enabled: Boolean = true, onClick: () -> Unit) {
    val shape = RoundedCornerShape(14.dp)
    Text(
        text,
        color = when {
            !enabled -> CardMuted
            filled -> Color.White
            else -> color
        },
        fontWeight = FontWeight.SemiBold,
        fontSize = 15.sp,
        modifier = Modifier
            .clip(shape)
            .background(if (filled && enabled) color else Color.White.copy(alpha = 0.08f))
            .then(if (enabled) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 16.dp, vertical = 9.dp)
    )
}

@Composable
private fun DraftCardView(card: VoiceCard.Draft, actions: CardActions, compact: Boolean) {
    CardFrame("voiceAssistantDraftCard") {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                if (card.isWorkout) Icons.Filled.FitnessCenter else Icons.Filled.Restaurant,
                contentDescription = null,
                tint = AppColors.Calorie,
                modifier = Modifier.size(18.dp)
            )
            Spacer(Modifier.width(8.dp))
            Text(
                stringResource(if (card.isWorkout) R.string.voice_card_workout_draft else R.string.voice_card_draft),
                color = CardMuted,
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold
            )
            Spacer(Modifier.weight(1f))
            Icon(
                Icons.Filled.Close,
                contentDescription = stringResource(R.string.voice_card_dismiss),
                tint = CardMuted,
                modifier = Modifier
                    .size(20.dp)
                    .clickable { actions.dismiss(card.id) }
            )
        }
        Spacer(Modifier.height(4.dp))
        Text(
            card.title,
            color = CardText,
            fontSize = 17.sp,
            fontWeight = FontWeight.Bold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
        if (!compact) {
            card.items.take(MAX_DRAFT_ROWS).forEach { DraftRow(it) }
            if (card.items.size > MAX_DRAFT_ROWS) {
                Text("+${card.items.size - MAX_DRAFT_ROWS}", color = CardMuted, fontSize = 13.sp)
            }
        }
        card.totals?.let { totals ->
            Spacer(Modifier.height(6.dp))
            Text(
                stringResource(
                    LocalEnergyUnit.current.pick(R.string.voice_card_totals, R.string.voice_card_totals_kj),
                    LocalEnergyUnit.current.displayValue(totals.calories),
                    grams(totals.proteinG),
                    grams(totals.carbsG),
                    grams(totals.fatG)
                ),
                color = CardText,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold
            )
        }
        Spacer(Modifier.height(10.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            if (card.logged) {
                Icon(Icons.Filled.TaskAlt, contentDescription = null, tint = AppColors.Calorie, modifier = Modifier.size(18.dp))
                Text(stringResource(R.string.voice_card_logged), color = AppColors.Calorie, fontWeight = FontWeight.SemiBold)
            } else {
                CardButton(stringResource(R.string.voice_card_log), filled = true) { actions.log(card.id) }
            }
        }
    }
}

@Composable
private fun DraftRow(item: DraftItem) {
    Row(Modifier.fillMaxWidth().padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(item.name, color = CardText, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            val detail = item.detail ?: item.serving
            if (!detail.isNullOrBlank()) {
                Text(detail, color = CardMuted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        item.calories?.let {
            Text(
                stringResource(LocalEnergyUnit.current.pick(R.string.voice_kcal, R.string.voice_kj), LocalEnergyUnit.current.displayValue(it)),
                color = CardMuted,
                fontSize = 13.sp
            )
        }
    }
}

@Composable
private fun ConfirmationCardView(card: VoiceCard.Confirmation, actions: CardActions, units: CardUnits) {
    CardFrame("voiceAssistantConfirmationCard") {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                if (card.destructive) Icons.Filled.WarningAmber else Icons.Filled.Check,
                contentDescription = null,
                tint = if (card.destructive) Destructive else AppColors.Calorie,
                modifier = Modifier.size(18.dp)
            )
            Spacer(Modifier.width(8.dp))
            Text(
                stringResource(if (card.destructive) R.string.voice_card_delete_title else R.string.voice_card_confirm_title),
                color = CardMuted,
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold
            )
        }
        Spacer(Modifier.height(4.dp))
        Text(changeText(card.change, units), color = CardText, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(10.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            CardButton(stringResource(R.string.action_cancel), filled = false, color = CardText) { actions.cancel(card.id) }
            if (card.destructive) {
                CardButton(stringResource(R.string.action_delete), filled = true, color = Destructive) { actions.confirm(card.id) }
            } else {
                CardButton(stringResource(R.string.voice_card_confirm), filled = true) { actions.confirm(card.id) }
            }
        }
    }
}

@Composable
private fun UndoCardView(card: VoiceCard.Undo, actions: CardActions, units: CardUnits) {
    var remaining by remember(card.id) { mutableFloatStateOf(1f) }
    LaunchedEffect(card.id) {
        while (remaining > 0f) {
            val left = card.expiresAtMillis - System.currentTimeMillis()
            remaining = (left.toFloat() / card.windowMillis).coerceIn(0f, 1f)
            delay(100)
        }
    }
    CardFrame("voiceAssistantUndoCard") {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.TaskAlt, contentDescription = null, tint = AppColors.Calorie, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.voice_card_saved), color = CardMuted, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                Text(
                    changeText(card.change, units),
                    color = CardText,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
            }
            Spacer(Modifier.width(8.dp))
            CardButton(stringResource(R.string.voice_card_undo), filled = false) { actions.undo(card.id) }
        }
        Spacer(Modifier.height(8.dp))
        LinearProgressIndicator(
            progress = { remaining },
            modifier = Modifier.fillMaxWidth().height(3.dp).clip(RoundedCornerShape(2.dp)),
            color = AppColors.Calorie,
            trackColor = Color.White.copy(alpha = 0.10f),
            strokeCap = StrokeCap.Round,
            drawStopIndicator = {}
        )
    }
}

/** "Name · 205 kcal" in the energy unit in use; the tool's value stays kcal. */
@Composable
private fun foodChangeText(name: String, kcal: Int): String = stringResource(
    LocalEnergyUnit.current.pick(R.string.voice_change_food, R.string.voice_change_food_kj),
    name,
    LocalEnergyUnit.current.displayValue(kcal)
)

/** A change, in the user's language and units. */
@Composable
internal fun changeText(change: VoiceChange, units: CardUnits): String = when (change) {
    is VoiceChange.LogFood -> stringResource(
        LocalEnergyUnit.current.pick(R.string.voice_change_log_food, R.string.voice_change_log_food_kj),
        change.name,
        LocalEnergyUnit.current.displayValue(change.calories),
        mealName(change.meal)
    )
    is VoiceChange.UpdateFood -> foodChangeText(change.name, change.calories)
    is VoiceChange.DeleteFood -> foodChangeText(change.name, change.calories)
    is VoiceChange.LogWater -> stringResource(R.string.voice_change_water, units.water.format(change.milliliters))
    is VoiceChange.StartFast -> stringResource(R.string.voice_change_start_fast, change.goalHours)
    is VoiceChange.EndFast -> stringResource(R.string.voice_change_end_fast, formatFastingDuration(change.elapsedMinutes * 60))
    is VoiceChange.LogWeight -> stringResource(
        R.string.voice_change_weight,
        if (change.metric) String.format(LocalConfiguration.current.locales[0], "%.1f kg", change.kilograms)
        else String.format(LocalConfiguration.current.locales[0], "%.1f lb", change.kilograms / 0.45359237)
    )
    is VoiceChange.LogBodyFat -> stringResource(R.string.voice_change_body_fat, String.format(LocalConfiguration.current.locales[0], "%.1f%%", change.percent))
    is VoiceChange.LogWorkout -> pluralStringResource(R.plurals.voice_change_workout, change.exerciseCount, change.exerciseCount)
    is VoiceChange.LogCardio -> stringResource(R.string.voice_change_cardio, change.activity, change.minutes)
    is VoiceChange.UpdateSetting -> stringResource(R.string.voice_change_setting, settingLabel(change.key), settingValue(change.key, change.value))
}

@Composable
private fun mealName(meal: MealType): String = stringResource(meal.displayNameRes)

@Composable
internal fun settingLabel(key: VoiceSettingKey): String = stringResource(
    when (key) {
        VoiceSettingKey.THEME_COLOR -> R.string.settings_theme_color
        VoiceSettingKey.APPEARANCE -> R.string.settings_appearance
        VoiceSettingKey.UNITS -> R.string.voice_setting_units
        VoiceSettingKey.CALORIE_GOAL -> R.string.settings_calories
        VoiceSettingKey.PROTEIN_GOAL_G -> R.string.macro_protein
        VoiceSettingKey.CARBS_GOAL_G -> R.string.macro_carbs
        VoiceSettingKey.FAT_GOAL_G -> R.string.macro_fat
        VoiceSettingKey.WATER_GOAL_ML -> R.string.settings_water_goal
        VoiceSettingKey.ASSISTANT_VOICE -> R.string.voice_settings_voice
        VoiceSettingKey.ASSISTANT_AUTO_CAPTURE -> R.string.voice_settings_auto_capture
        VoiceSettingKey.ASSISTANT_CONFIRM_SAVES -> R.string.voice_settings_confirm_saves
    }
)

@Composable
private fun settingValue(key: VoiceSettingKey, value: String): String = when (key) {
    VoiceSettingKey.THEME_COLOR -> stringResource(AppThemeColor.fromKey(value).displayNameRes)
    VoiceSettingKey.APPEARANCE -> stringResource(
        when (value) {
            "light" -> R.string.settings_appearance_light
            "dark" -> R.string.settings_appearance_dark
            else -> R.string.settings_appearance_system
        }
    )
    VoiceSettingKey.UNITS -> stringResource(if (value == "metric") R.string.voice_units_metric else R.string.voice_units_imperial)
    VoiceSettingKey.CALORIE_GOAL -> stringResource(
        LocalEnergyUnit.current.pick(R.string.voice_kcal, R.string.voice_kj),
        LocalEnergyUnit.current.displayValue(value.toIntOrNull() ?: 0)
    )
    VoiceSettingKey.PROTEIN_GOAL_G, VoiceSettingKey.CARBS_GOAL_G, VoiceSettingKey.FAT_GOAL_G -> "$value g"
    VoiceSettingKey.WATER_GOAL_ML -> "$value ml"
    VoiceSettingKey.ASSISTANT_VOICE -> LiveProvider.voiceDisplayName(value)
    VoiceSettingKey.ASSISTANT_AUTO_CAPTURE, VoiceSettingKey.ASSISTANT_CONFIRM_SAVES ->
        stringResource(if (value == "true") R.string.voice_on else R.string.voice_off)
}

private fun grams(value: Double): Int = value.roundToInt()

private const val MAX_DRAFT_ROWS = 4
