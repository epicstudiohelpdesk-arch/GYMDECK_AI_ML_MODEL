package com.apoorvdarshan.calorietracker.models

import com.apoorvdarshan.calorietracker.services.ai.FoodAnalysis
import kotlinx.serialization.Serializable
import java.time.Instant

@Serializable
data class PendingFoodAnalysisDraft(
    val analysis: FoodAnalysis,
    val imageFilename: String? = null,
    val additionalImageFilenames: List<String> = emptyList(),
    val source: FoodSource? = null,
    @Serializable(with = InstantSerializer::class)
    val createdAt: Instant = Instant.now(),
    /** The analysis is the user's saved nutrition label for a barcode Open Food Facts could not use (#485). */
    val usesSavedBarcodeLabel: Boolean = false
) {
    /** The analysis a restored review shows the saved-label notice for, if any. */
    val savedLabelAnalysis: FoodAnalysis?
        get() = analysis.takeIf { usesSavedBarcodeLabel }
}
