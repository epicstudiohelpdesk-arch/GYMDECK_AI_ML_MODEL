package com.apoorvdarshan.calorietracker.models

import com.apoorvdarshan.calorietracker.services.OpenFoodFactsService
import java.util.Locale

/**
 * Remembers the nutrition labels a user scanned for barcodes that Open Food
 * Facts could not use (#485). The link lives in the logged entry itself
 * (`source == NUTRITION_LABEL` plus `productMetadata.barcode`), so deleting those
 * logs is all it takes to forget a label. Mirrors iOS BarcodeLabelMemory.
 */
object BarcodeLabelMemory {
    /**
     * Comparison key for a scanned code. Numeric codes drop leading zeros, so a
     * UPC-A code and the same product read as EAN-13 match (GTIN rules).
     */
    fun normalizedBarcode(raw: String?): String? {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty()) return null
        if (trimmed.any { it !in '0'..'9' }) return trimmed.lowercase(Locale.US)
        return trimmed.trimStart('0').ifEmpty { "0" }
    }

    /**
     * Open Food Facts wins whenever it has nutrition. A saved label is only a
     * fallback for a product it does not know or has no nutrition for.
     */
    fun allowsFallback(failure: OpenFoodFactsService.LookupFailure): Boolean =
        failure == OpenFoodFactsService.LookupFailure.PRODUCT_NOT_FOUND ||
            failure == OpenFoodFactsService.LookupFailure.MISSING_NUTRITION

    /** The most recent nutrition-label log linked to [barcode], if any. */
    fun latestLabelEntry(barcode: String, entries: List<FoodEntry>): FoodEntry? {
        val key = normalizedBarcode(barcode) ?: return null
        return entries
            .filter { entry ->
                entry.source == FoodSource.NUTRITION_LABEL &&
                    normalizedBarcode(entry.productMetadata?.barcode) == key
            }
            .maxByOrNull { it.timestamp }
    }

    /** Links a label scan to the barcode it was taken for, keeping any product details already present. */
    fun labelMetadata(existing: FoodProductMetadata?, barcode: String): FoodProductMetadata =
        existing?.copy(barcode = barcode) ?: FoodProductMetadata(barcode = barcode)
}

/**
 * Carries the barcode from the "Scan label" prompt into the label photo analysis.
 * Taking it consumes it, and every other way out clears it, so a stale code can
 * never attach to an unrelated log.
 */
class LabelScanBarcodeHandoff {
    var barcode: String? = null
        private set

    fun arm(barcode: String?) {
        this.barcode = barcode?.trim()?.takeIf { it.isNotEmpty() }
    }

    fun take(): String? = barcode.also { barcode = null }

    fun clear() {
        barcode = null
    }
}
