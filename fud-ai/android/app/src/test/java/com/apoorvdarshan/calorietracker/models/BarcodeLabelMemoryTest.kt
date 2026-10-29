package com.apoorvdarshan.calorietracker.models

import com.apoorvdarshan.calorietracker.services.OpenFoodFactsService.LookupFailure
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/** Remembered nutrition labels for barcodes Open Food Facts cannot use (#485). */
class BarcodeLabelMemoryTest {
    @Test
    fun normalizedBarcodeMatchesUpcAndEanFormsOfTheSameCode() {
        assertEquals("12345678905", BarcodeLabelMemory.normalizedBarcode(" 0012345678905 "))
        assertEquals("12345678905", BarcodeLabelMemory.normalizedBarcode("012345678905"))
        assertEquals("0", BarcodeLabelMemory.normalizedBarcode("000"))
        assertEquals("abc-123", BarcodeLabelMemory.normalizedBarcode("ABC-123"))
        assertNull(BarcodeLabelMemory.normalizedBarcode("   "))
        assertNull(BarcodeLabelMemory.normalizedBarcode(null))
    }

    @Test
    fun latestLabelLogWinsAcrossNormalizedCodes() {
        val older = labelEntry("Granola v1", "012345678905", 1_000)
        val newer = labelEntry("Granola v2", "0012345678905", 2_000)

        val match = BarcodeLabelMemory.latestLabelEntry("12345678905", listOf(newer, older))

        assertEquals("Granola v2", match?.name)
    }

    @Test
    fun ignoresOpenFoodFactsLogsOtherCodesAndEntriesWithoutMetadata() {
        val label = labelEntry("Label", "4006381333931", 1_000)
        val openFoodFacts = labelEntry("Open Food Facts", "4006381333931", 3_000).copy(source = FoodSource.BARCODE)
        val otherCode = labelEntry("Other", "5000112637922", 4_000)
        val noMetadata = labelEntry("Photo", "4006381333931", 5_000).copy(productMetadata = null)
        val entries = listOf(label, openFoodFacts, otherCode, noMetadata)

        assertEquals("Label", BarcodeLabelMemory.latestLabelEntry("4006381333931", entries)?.name)
        assertNull(BarcodeLabelMemory.latestLabelEntry("9999999999999", entries))
        assertNull(BarcodeLabelMemory.latestLabelEntry("  ", entries))
    }

    @Test
    fun onlyNotFoundAndMissingNutritionFallBackToASavedLabel() {
        assertTrue(BarcodeLabelMemory.allowsFallback(LookupFailure.PRODUCT_NOT_FOUND))
        assertTrue(BarcodeLabelMemory.allowsFallback(LookupFailure.MISSING_NUTRITION))
        LookupFailure.values()
            .filter { it != LookupFailure.PRODUCT_NOT_FOUND && it != LookupFailure.MISSING_NUTRITION }
            .forEach { assertFalse(it.name, BarcodeLabelMemory.allowsFallback(it)) }
    }

    @Test
    fun labelMetadataLinksTheBarcodeAndKeepsExistingDetails() {
        val created = BarcodeLabelMemory.labelMetadata(null, "4006381333931")
        assertEquals(FoodProductMetadata(barcode = "4006381333931"), created)
        assertTrue(created.hasDisplayDetails)

        val merged = BarcodeLabelMemory.labelMetadata(
            created.copy(barcode = "old", allergens = listOf("Milk")),
            "5000112637922"
        )
        assertEquals("5000112637922", merged.barcode)
        assertEquals(listOf("Milk"), merged.allergens)
    }

    @Test
    fun pendingLabelBarcodeIsConsumedOnceAndClearedOnCancel() {
        val handoff = LabelScanBarcodeHandoff()
        handoff.arm(" 4006381333931 ")
        assertEquals("4006381333931", handoff.take())
        assertNull(handoff.take())

        handoff.arm("4006381333931")
        handoff.clear()
        assertNull(handoff.take())

        handoff.arm("   ")
        assertNull(handoff.barcode)

        handoff.arm("111")
        handoff.arm("222")
        assertEquals("222", handoff.take())
    }

    private fun labelEntry(name: String, barcode: String, epochSecond: Long) = FoodEntry(
        name = name,
        calories = 200,
        protein = 20.0,
        carbs = 15.0,
        fat = 7.0,
        timestamp = Instant.ofEpochSecond(epochSecond),
        source = FoodSource.NUTRITION_LABEL,
        productMetadata = BarcodeLabelMemory.labelMetadata(null, barcode)
    )
}
