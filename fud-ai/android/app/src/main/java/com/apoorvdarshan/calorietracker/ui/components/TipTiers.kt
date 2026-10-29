package com.apoorvdarshan.calorietracker.ui.components

import androidx.annotation.DrawableRes
import androidx.annotation.StringRes
import com.apoorvdarshan.calorietracker.R

/** The four consumable tip products (iOS tip jar parity), with PixelLab pixel-art icons. */
internal data class TipTier(val productId: String, @DrawableRes val icon: Int, @StringRes val nameRes: Int)

internal val TIP_TIERS = listOf(
    TipTier("tip_snack", R.drawable.tip_snack, R.string.tip_snack),
    TipTier("tip_proteinshake", R.drawable.tip_proteinshake, R.string.tip_proteinshake),
    TipTier("tip_lunch", R.drawable.tip_lunch, R.string.tip_lunch),
    TipTier("tip_feast", R.drawable.tip_feast, R.string.tip_feast)
)
