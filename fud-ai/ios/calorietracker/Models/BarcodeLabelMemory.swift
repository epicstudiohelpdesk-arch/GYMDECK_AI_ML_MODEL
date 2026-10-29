import Foundation

/// Remembers the nutrition labels a user scanned for barcodes that Open Food
/// Facts could not use (#485). The link lives in the logged entry itself
/// (`source == .nutritionLabel` plus `productMetadata.barcode`), so deleting
/// those logs is all it takes to forget a label.
enum BarcodeLabelMemory {
    /// Comparison key for a scanned code. Numeric codes drop leading zeros, so
    /// a UPC-A code and the same product read as EAN-13 match (GTIN rules).
    static func normalizedBarcode(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let asciiDigits: ClosedRange<Unicode.Scalar> = "0"..."9"
        guard trimmed.unicodeScalars.allSatisfy({ asciiDigits.contains($0) }) else {
            return trimmed.lowercased()
        }
        let withoutLeadingZeros = trimmed.drop(while: { $0 == "0" })
        return withoutLeadingZeros.isEmpty ? "0" : String(withoutLeadingZeros)
    }

    /// Open Food Facts wins whenever it has nutrition. A saved label is only a
    /// fallback for a product it does not know or has no nutrition for.
    static func allowsFallback(for error: Error) -> Bool {
        guard let lookupError = error as? OpenFoodFactsService.LookupError else { return false }
        switch lookupError {
        case .productNotFound, .missingNutrition:
            return true
        default:
            return false
        }
    }

    /// The most recent nutrition-label log linked to `barcode`, if any.
    static func latestLabelEntry(for barcode: String, in entries: [FoodEntry]) -> FoodEntry? {
        guard let key = normalizedBarcode(barcode) else { return nil }
        return entries
            .filter { entry in
                entry.source == .nutritionLabel
                    && normalizedBarcode(entry.productMetadata?.barcode) == key
            }
            .max { $0.timestamp < $1.timestamp }
    }

    /// Links a label scan to the barcode it was taken for, keeping any product
    /// details the analysis already had.
    static func labelMetadata(_ existing: FoodProductMetadata?, barcode: String) -> FoodProductMetadata {
        var metadata = existing ?? FoodProductMetadata(
            barcode: barcode,
            packageQuantity: nil,
            ingredientsText: nil,
            allergens: [],
            traces: [],
            nutriScore: nil,
            novaGroup: nil,
            ecoScore: nil,
            labels: [],
            categories: [],
            imageURL: nil
        )
        metadata.barcode = barcode
        return metadata
    }
}

/// Carries the barcode from the "Scan Label" prompt into the label photo
/// analysis. Taking it consumes it, and every other way out clears it, so a
/// stale code can never attach to an unrelated log.
struct LabelScanBarcodeHandoff: Equatable {
    private(set) var barcode: String?
    /// The capture sheet is closing only so the camera can take another photo.
    private var keepsThroughNextSheetDismissal = false

    mutating func arm(_ barcode: String?) {
        let trimmed = barcode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.barcode = trimmed.isEmpty ? nil : trimmed
        keepsThroughNextSheetDismissal = false
    }

    mutating func take() -> String? {
        defer { clear() }
        return barcode
    }

    mutating func clear() {
        barcode = nil
        keepsThroughNextSheetDismissal = false
    }

    /// "Add photo" closes the capture sheet to open the camera; the label scan
    /// goes on, so the next sheet dismissal keeps the barcode.
    mutating func keepForAnotherPhoto() {
        keepsThroughNextSheetDismissal = true
    }

    /// The capture sheet closed. Unless it only stepped aside for the camera,
    /// that is a way out of the label scan (last photo removed, swiped down).
    mutating func captureSheetDismissed() {
        if keepsThroughNextSheetDismissal {
            keepsThroughNextSheetDismissal = false
        } else {
            clear()
        }
    }
}
