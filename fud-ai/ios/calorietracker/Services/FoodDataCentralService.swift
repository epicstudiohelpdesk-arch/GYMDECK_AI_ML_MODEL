import Foundation

/// The user's own USDA FoodData Central API key (#533). It lives in the
/// Keychain like the AI provider keys; without one the app never contacts FDC.
enum FoodDataCentralSettings {
    static let apiKeyKeychainKey = "usdaFoodDataCentralAPIKey"
    /// Free sign-up for the api.data.gov key FoodData Central uses.
    static let apiKeySignupURL = URL(string: "https://fdc.nal.usda.gov/api-key-signup")!

    static var apiKey: String? {
        usableKey(KeychainHelper.load(key: apiKeyKeychainKey))
    }

    static func setAPIKey(_ key: String?) {
        if let key = usableKey(key) {
            KeychainHelper.save(key: apiKeyKeychainKey, value: key)
        } else {
            KeychainHelper.delete(key: apiKeyKeychainKey)
        }
    }

    /// The trimmed key, or nil when it is blank, so whitespace never counts as a key.
    static func usableKey(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// Optional second barcode source (#533): USDA FoodData Central Branded Foods.
/// Only a food whose GTIN/UPC equals the scanned code is used, and the key is
/// sent only in the `X-Api-Key` header, never in the URL.
enum FoodDataCentralService {
    static let searchURL = URL(string: "https://api.nal.usda.gov/fdc/v1/foods/search")!
    /// `FoodProductMetadata.dataSource` for products found here.
    static let dataSourceID = "usdaFoodDataCentral"
    static let requestTimeout: TimeInterval = 15

    enum LookupError: LocalizedError, Equatable {
        /// FoodData Central refused the key (HTTP 401 or 403).
        case invalidAPIKey
        /// Rate limits, server errors, unreadable responses and network failures.
        case unavailable

        var errorDescription: String? {
            switch self {
            case .invalidAPIKey:
                String(
                    localized: "barcode.lookup.usda_key_rejected",
                    defaultValue: "USDA FoodData Central rejected your API key. Check it in Settings > Product Information, or scan the nutrition label instead.",
                    table: "BarcodeLookup",
                    comment: "Error shown when Open Food Facts has no usable product and USDA FoodData Central refuses the API key the user added."
                )
            case .unavailable:
                String(
                    localized: "barcode.lookup.network_error",
                    defaultValue: "Barcode lookup failed. Check your connection and try again.",
                    table: "BarcodeLookup",
                    comment: "Error shown when a barcode request fails because of a network problem."
                )
            }
        }
    }

    /// The Branded food whose GTIN/UPC equals `barcode`, mapped like an Open Food
    /// Facts product. Nil when FoodData Central has no exact match with nutrition,
    /// and when there is no key or no valid code, in which case nothing is sent.
    static func lookup(
        barcode: String,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> GeminiService.FoodAnalysis? {
        let code = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        let variants = gtinQueryVariants(for: code)
        guard let apiKey = FoodDataCentralSettings.usableKey(apiKey), !variants.isEmpty else { return nil }

        var request = URLRequest(url: searchURL, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            // Words are OR'ed, so one request covers every way FDC may store the code.
            "query": variants.joined(separator: " "),
            "dataType": ["Branded"],
            "requireAllWords": false,
            "pageSize": 25,
        ])

        let data: Data
        do {
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw LookupError.unavailable }
            switch http.statusCode {
            case 200..<300:
                data = body
            case 401, 403:
                throw LookupError.invalidAPIKey
            default:
                throw LookupError.unavailable
            }
        } catch let error as LookupError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw LookupError.unavailable
        }

        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let foods = root["foods"] as? [[String: Any]]
        else { throw LookupError.unavailable }

        return foods.lazy
            .filter { food in
                (food["dataType"] as? String).map { $0.caseInsensitiveCompare("Branded") == .orderedSame } ?? true
                    && matchesGTIN(food["gtinUpc"] as? String, scanned: code)
            }
            .compactMap { analysis(from: $0, barcode: code) }
            .first
    }

    /// The forms FDC may store a scanned code in: as scanned, without leading
    /// zeros, and zero-padded to GTIN-8, -12, -13 and -14. Empty for anything
    /// that is not a GTIN, so no request is made.
    static func gtinQueryVariants(for code: String) -> [String] {
        let asciiDigits: ClosedRange<UInt8> = 48...57
        guard !code.isEmpty, code.utf8.allSatisfy({ asciiDigits.contains($0) }) else { return [] }
        let stripped = String(code.drop(while: { $0 == "0" }))
        guard !stripped.isEmpty, stripped.count <= 14 else { return [] }

        var variants: [String] = []
        for candidate in [code, stripped] + [8, 12, 13, 14].compactMap({ padded(stripped, to: $0) })
        where candidate.count <= 14 && !variants.contains(candidate) {
            variants.append(candidate)
        }
        return variants
    }

    /// GTINs compare without leading zeros, so a UPC-A stored as GTIN-14 matches.
    static func matchesGTIN(_ stored: String?, scanned: String) -> Bool {
        guard let key = BarcodeLabelMemory.normalizedBarcode(scanned) else { return false }
        return BarcodeLabelMemory.normalizedBarcode(stored) == key
    }

    private static func padded(_ digits: String, to width: Int) -> String? {
        guard digits.count <= width else { return nil }
        return String(repeating: "0", count: width - digits.count) + digits
    }

    // MARK: - Mapping

    /// The amount a mapped result describes.
    private enum Amount {
        /// One label serving of a known weight; label and per-100 g values both convert to it.
        case serving(grams: Double)
        /// One label serving whose weight FDC does not give: label values only, kept as one
        /// logged serving like a Health-restored log, never as a made-up weight.
        case unknownServing
        /// 100 g: only the per-100 g Branded values, when there is no serving weight.
        case hundredGrams
    }

    private static func analysis(from food: [String: Any], barcode: String) -> GeminiService.FoodAnalysis? {
        let entries = food["foodNutrients"] as? [[String: Any]] ?? []
        let label = food["labelNutrients"] as? [String: Any] ?? [:]
        let amount: Amount
        let nutrients: Nutrients
        if let grams = servingGrams(of: food) {
            amount = .serving(grams: grams)
            nutrients = Nutrients(entries, label: label, scale: grams / 100)
        } else {
            // Label values are per serving and Branded values per 100 g; without the serving
            // weight neither converts to the other, so only one set is used.
            let perServing = Nutrients([], label: label, scale: 0)
            let per100g = Nutrients(entries, label: [:], scale: 1)
            if perServing.coreValueCount > 0, perServing.coreValueCount >= per100g.coreValueCount {
                amount = .unknownServing
                nutrients = perServing
            } else {
                amount = .hundredGrams
                nutrients = per100g
            }
        }

        let calories = nutrients.calories
        let protein = nutrients.grams([1003], label: "protein")
        let carbs = nutrients.grams([1005, 1050], label: "carbohydrates")
        let fat = nutrients.grams([1004], label: "fat")
        guard calories != nil || protein != nil || carbs != nil || fat != nil else { return nil }

        let servingSizeGrams: Double
        let servingUnitOptions: [ServingUnitOption]
        let selectedServingUnit: String
        let selectedServingQuantity: Double
        let servingSizeIsKnown: Bool
        switch amount {
        case .serving(let grams):
            servingSizeGrams = grams
            servingUnitOptions = [ServingUnitOption(unit: "serving", gramsPerUnit: grams, quantity: 1)]
            selectedServingUnit = "serving"
            selectedServingQuantity = 1
            servingSizeIsKnown = true
        case .unknownServing:
            // Like FoodEntry.reviewAnalysis for an unknown mass: the basis is a serving count.
            servingSizeGrams = 1
            servingUnitOptions = [.loggedServing(quantity: 1)]
            selectedServingUnit = "serving"
            selectedServingQuantity = 1
            servingSizeIsKnown = false
        case .hundredGrams:
            servingSizeGrams = 100
            servingUnitOptions = []
            selectedServingUnit = ServingUnitOption.grams.unit
            selectedServingQuantity = 100
            servingSizeIsKnown = true
        }
        let category = text(food["foodCategory"])
        let metadata = FoodProductMetadata(
            barcode: barcode,
            packageQuantity: nil,
            ingredientsText: IngredientLabelParser.markingAllergens(plain: text(food["ingredients"]), markup: nil),
            allergens: [],
            traces: [],
            nutriScore: nil,
            novaGroup: nil,
            ecoScore: nil,
            labels: [],
            categories: category.map { [$0] } ?? [],
            imageURL: nil,
            dataSource: dataSourceID
        )

        return GeminiService.FoodAnalysis(
            name: productName(from: food, barcode: barcode),
            calories: Int(round(calories ?? 0)),
            protein: protein ?? 0,
            carbs: carbs ?? 0,
            fat: fat ?? 0,
            servingSizeGrams: servingSizeGrams,
            emoji: "🏷️",
            sugar: rounded(nutrients.grams([2000, 1063], label: "sugars")),
            addedSugar: rounded(nutrients.grams([1235], label: "addedSugar")),
            fiber: rounded(nutrients.grams([1079], label: "fiber")),
            saturatedFat: rounded(nutrients.grams([1258], label: "saturatedFat")),
            monounsaturatedFat: rounded(nutrients.grams([1292])),
            polyunsaturatedFat: rounded(nutrients.grams([1293])),
            cholesterol: milligrams(nutrients.grams([1253], label: "cholesterol", labelUnit: 0.001)),
            caffeine: milligrams(nutrients.grams([1057])),
            sodium: milligrams(nutrients.grams([1093], label: "sodium", labelUnit: 0.001)),
            potassium: milligrams(nutrients.grams([1092], label: "potassium", labelUnit: 0.001)),
            transFat: rounded(nutrients.grams([1257], label: "transFat")),
            calcium: milligrams(nutrients.grams([1087], label: "calcium", labelUnit: 0.001)),
            iron: milligrams(nutrients.grams([1089], label: "iron", labelUnit: 0.001)),
            magnesium: milligrams(nutrients.grams([1090])),
            zinc: milligrams(nutrients.grams([1095])),
            vitaminA: micrograms(nutrients.grams([1106])),
            vitaminC: milligrams(nutrients.grams([1162])),
            vitaminD: micrograms(nutrients.grams([1114]) ?? nutrients.vitaminDFromIU),
            vitaminB12: micrograms(nutrients.grams([1178])),
            vitaminE: milligrams(nutrients.grams([1109])),
            vitaminK: micrograms(nutrients.grams([1185])),
            folate: micrograms(nutrients.grams([1190, 1177])),
            servingUnitOptions: servingUnitOptions,
            selectedServingUnit: selectedServingUnit,
            selectedServingQuantity: selectedServingQuantity,
            servingSizeIsKnown: servingSizeIsKnown,
            productMetadata: metadata
        )
    }

    /// Nutrient amounts for the mapped amount. Label values (already per serving) win;
    /// otherwise the per-100 g Branded values are multiplied by `scale`. Only the
    /// first entry for a nutrient counts, since FDC can list older panels after it.
    private struct Nutrients {
        private var amounts: [Int: (value: Double, unit: String)] = [:]
        private let label: [String: Any]
        private let scale: Double

        init(_ entries: [[String: Any]], label: [String: Any], scale: Double) {
            for entry in entries {
                guard let id = (entry["nutrientId"] as? NSNumber)?.intValue,
                      amounts[id] == nil,
                      let value = FoodDataCentralService.number(entry["value"]),
                      value >= 0
                else { continue }
                amounts[id] = (value, (entry["unitName"] as? String ?? "").uppercased())
            }
            self.label = label
            self.scale = scale
        }

        var calories: Double? {
            if let value = labelValue("calories") { return value }
            for id in [1008, 2047, 2048] {
                if let amount = amounts[id], amount.unit == "KCAL" { return amount.value * scale }
            }
            if let kilojoules = amounts[1062], kilojoules.unit == "KJ" {
                return kilojoules.value * 0.23900573614 * scale
            }
            return nil
        }

        /// How many of calories, protein, carbs and fat this set has.
        var coreValueCount: Int {
            [calories, grams([1003], label: "protein"), grams([1005, 1050], label: "carbohydrates"), grams([1004], label: "fat")]
                .compactMap { $0 }
                .count
        }

        /// Vitamin D given only in International Units (1 IU = 0.025 µg).
        var vitaminDFromIU: Double? {
            guard let amount = amounts[1110], amount.unit == "IU" else { return nil }
            return amount.value * 0.025e-6 * scale
        }

        /// Grams per serving. `labelUnit` converts the label's unit (mg for minerals) to grams.
        func grams(_ ids: [Int], label key: String? = nil, labelUnit: Double = 1) -> Double? {
            if let key, let value = labelValue(key) { return value * labelUnit }
            for id in ids {
                guard let amount = amounts[id] else { continue }
                let factor: Double
                switch amount.unit {
                case "G": factor = 1
                case "MG": factor = 0.001
                case "UG", "MCG": factor = 0.000_001
                default: continue
                }
                return amount.value * factor * scale
            }
            return nil
        }

        private func labelValue(_ key: String) -> Double? {
            FoodDataCentralService.number((label[key] as? [String: Any])?["value"]).flatMap { $0 >= 0 ? $0 : nil }
        }
    }

    /// The serving weight in grams (millilitres count as grams), or nil when FDC does not give
    /// one. Any positive weight is kept as given, even below 1 g.
    private static func servingGrams(of food: [String: Any]) -> Double? {
        weight(of: food).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    private static func weight(of food: [String: Any]) -> Double? {
        if let size = number(food["servingSize"]), size > 0,
           let unit = text(food["servingSizeUnit"])?.lowercased() {
            switch unit {
            case "g", "grm", "gram", "grams", "ml", "mlt": return size
            case "kg": return size * 1_000
            case "mg": return size / 1_000
            case "oz", "onz": return size * 28.3495
            case "fl oz", "foz": return size * 29.5735
            case "l", "ltr": return size * 1_000
            default: break
            }
        }
        // "1 pouch (26g)": the household text often carries the weight.
        return OpenFoodFactsService.grams(from: text(food["householdServingFullText"]))
    }

    private static func productName(from food: [String: Any], barcode: String) -> String {
        let description = text(food["description"]).map { displayCase($0) }
        let brand = (text(food["brandName"]) ?? text(food["brandOwner"])).map { displayCase($0) }
        if let description, let brand, description.range(of: brand, options: .caseInsensitive, locale: englishCasingLocale) == nil {
            return "\(brand) \(description)"
        }
        return description ?? brand ?? String(
            localized: "barcode.product.fallback_name",
            defaultValue: "Barcode \(barcode)",
            table: "BarcodeLookup",
            comment: "Fallback food name. The placeholder is the scanned barcode."
        )
    }

    /// Many Branded descriptions are all caps ("HONEY NUT CHEERIOS"); show them in title case.
    /// FDC names are English, so the casing ignores the device language: in Turkish or
    /// Azerbaijani, "I" would otherwise become a dotless "ı" ("Cheerıos").
    static func displayCase(_ value: String) -> String {
        value.contains(where: \.isLowercase) ? value : value.capitalized(with: englishCasingLocale)
    }

    private static let englishCasingLocale = Locale(identifier: "en_US_POSIX")

    private static func text(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else {
            return nil
        }
        return string
    }

    private static func number(_ value: Any?) -> Double? {
        let parsed: Double?
        switch value {
        case let number as NSNumber: parsed = number.doubleValue
        case let string as String: parsed = Double(string.trimmingCharacters(in: .whitespaces))
        default: parsed = nil
        }
        return parsed.flatMap { $0.isFinite ? $0 : nil }
    }

    private static func rounded(_ value: Double?) -> Double? {
        value.map { round($0 * 10) / 10 }
    }

    private static func milligrams(_ grams: Double?) -> Double? {
        grams.map { round($0 * 1000 * 10) / 10 }
    }

    private static func micrograms(_ grams: Double?) -> Double? {
        grams.map { round($0 * 1_000_000 * 10) / 10 }
    }
}
