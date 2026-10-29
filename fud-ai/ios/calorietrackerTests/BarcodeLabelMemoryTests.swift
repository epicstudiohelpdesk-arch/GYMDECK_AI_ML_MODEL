import Foundation
import Testing
@testable import calorietracker

/// Remembered nutrition labels for barcodes Open Food Facts cannot use (#485).
struct BarcodeLabelMemoryTests {

    @Test func normalizedBarcodeMatchesUPCAndEANFormsOfTheSameCode() {
        #expect(BarcodeLabelMemory.normalizedBarcode(" 0012345678905 ") == "12345678905")
        #expect(BarcodeLabelMemory.normalizedBarcode("012345678905") == "12345678905")
        #expect(BarcodeLabelMemory.normalizedBarcode("000") == "0")
        #expect(BarcodeLabelMemory.normalizedBarcode("ABC-123") == "abc-123")
        #expect(BarcodeLabelMemory.normalizedBarcode("   ") == nil)
        #expect(BarcodeLabelMemory.normalizedBarcode(nil) == nil)
    }

    @Test func latestLabelLogWinsAcrossNormalizedCodes() {
        let older = labelEntry("Granola v1", barcode: "012345678905", at: 1_000)
        let newer = labelEntry("Granola v2", barcode: "0012345678905", at: 2_000)

        let match = BarcodeLabelMemory.latestLabelEntry(for: "12345678905", in: [newer, older])

        #expect(match?.name == "Granola v2")
    }

    @Test func ignoresOpenFoodFactsLogsOtherCodesAndEntriesWithoutMetadata() {
        let label = labelEntry("Label", barcode: "4006381333931", at: 1_000)
        var openFoodFacts = labelEntry("Open Food Facts", barcode: "4006381333931", at: 3_000)
        openFoodFacts.source = .barcode
        let otherCode = labelEntry("Other", barcode: "5000112637922", at: 4_000)
        var noMetadata = labelEntry("Photo", barcode: "4006381333931", at: 5_000)
        noMetadata.productMetadata = nil

        let entries = [label, openFoodFacts, otherCode, noMetadata]

        #expect(BarcodeLabelMemory.latestLabelEntry(for: "4006381333931", in: entries)?.name == "Label")
        #expect(BarcodeLabelMemory.latestLabelEntry(for: "9999999999999", in: entries) == nil)
        #expect(BarcodeLabelMemory.latestLabelEntry(for: "  ", in: entries) == nil)
    }

    @Test func onlyNotFoundAndMissingNutritionFallBackToASavedLabel() {
        #expect(BarcodeLabelMemory.allowsFallback(for: OpenFoodFactsService.LookupError.productNotFound))
        #expect(BarcodeLabelMemory.allowsFallback(for: OpenFoodFactsService.LookupError.missingNutrition))
        #expect(!BarcodeLabelMemory.allowsFallback(for: OpenFoodFactsService.LookupError.offline))
        #expect(!BarcodeLabelMemory.allowsFallback(for: OpenFoodFactsService.LookupError.rateLimited))
        #expect(!BarcodeLabelMemory.allowsFallback(for: OpenFoodFactsService.LookupError.invalidBarcode))
        #expect(!BarcodeLabelMemory.allowsFallback(for: CancellationError()))
    }

    @Test func labelMetadataLinksTheBarcodeAndKeepsExistingDetails() {
        let created = BarcodeLabelMemory.labelMetadata(nil, barcode: "4006381333931")
        #expect(created.barcode == "4006381333931")
        #expect(created.allergens.isEmpty)
        #expect(created.hasDisplayDetails)

        var existing = created
        existing.barcode = "old"
        existing.allergens = ["Milk"]
        let merged = BarcodeLabelMemory.labelMetadata(existing, barcode: "5000112637922")
        #expect(merged.barcode == "5000112637922")
        #expect(merged.allergens == ["Milk"])
    }

    @Test func pendingLabelBarcodeIsConsumedOnceAndClearedOnCancel() {
        var handoff = LabelScanBarcodeHandoff()
        handoff.arm(" 4006381333931 ")
        #expect(handoff.take() == "4006381333931")
        #expect(handoff.take() == nil)

        handoff.arm("4006381333931")
        handoff.clear()
        #expect(handoff.take() == nil)

        handoff.arm("   ")
        #expect(handoff.barcode == nil)

        handoff.arm("111")
        handoff.arm("222")
        #expect(handoff.take() == "222")
    }

    @Test func closingTheCaptureSheetClearsTheBarcodeUnlessItOpensTheCamera() {
        var handoff = LabelScanBarcodeHandoff()
        handoff.arm("4006381333931")

        // "Add photo" steps aside for the camera, so the label scan goes on.
        handoff.keepForAnotherPhoto()
        handoff.captureSheetDismissed()
        #expect(handoff.barcode == "4006381333931")

        // Removing the last photo or swiping the sheet down is a way out.
        handoff.captureSheetDismissed()
        #expect(handoff.barcode == nil)

        // A pending camera step never outlives a cleared or re-armed scan.
        handoff.arm("4006381333931")
        handoff.keepForAnotherPhoto()
        handoff.clear()
        handoff.arm("5000112637922")
        handoff.captureSheetDismissed()
        #expect(handoff.barcode == nil)

        handoff.arm("4006381333931")
        handoff.keepForAnotherPhoto()
        #expect(handoff.take() == "4006381333931")
        handoff.arm("5000112637922")
        handoff.captureSheetDismissed()
        #expect(handoff.barcode == nil)
    }

    @Test func reviewAnalysisKeepsTheSavedLabelNutritionServingAndBarcode() {
        var entry = labelEntry("Protein bar", barcode: "4006381333931", at: 1_000)
        entry.fiber = 6
        entry.servingSizeGrams = 60
        entry.servingUnitOptions = [ServingUnitOption(unit: "bar", gramsPerUnit: 60)]
        entry.selectedServingUnit = "bar"
        entry.selectedServingQuantity = 1

        let analysis = entry.reviewAnalysis

        #expect(analysis.calories == entry.calories)
        #expect(analysis.protein == entry.protein)
        #expect(analysis.fiber == 6)
        #expect(analysis.servingSizeGrams == 60)
        #expect(analysis.servingUnitOptions == entry.servingUnitOptions)
        #expect(analysis.selectedServingUnit == "bar")
        #expect(analysis.servingSizeIsKnown)
        #expect(analysis.productMetadata?.barcode == "4006381333931")
    }

    private func labelEntry(_ name: String, barcode: String, at seconds: TimeInterval) -> FoodEntry {
        FoodEntry(
            name: name,
            calories: 200,
            protein: 20,
            carbs: 15,
            fat: 7,
            timestamp: Date(timeIntervalSince1970: seconds),
            source: .nutritionLabel,
            productMetadata: BarcodeLabelMemory.labelMetadata(nil, barcode: barcode)
        )
    }
}
