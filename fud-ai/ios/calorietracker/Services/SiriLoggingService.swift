import Foundation

@MainActor
enum SiriLoggingService {
    enum FoodInputError: LocalizedError {
        case activeFast

        var errorDescription: String? {
            switch self {
            case .activeFast:
                String(localized: "End or cancel your active fast before logging food.")
            }
        }
    }

    enum WeightInputError: LocalizedError {
        case missingNumber
        case invalidRange

        var errorDescription: String? {
            switch self {
            case .missingNumber:
                String(
                    localized: "Please say a weight, such as 75 kilograms or 165 pounds.",
                    comment: "Siri reply when the spoken weight has no number."
                )
            case .invalidRange:
                String(localized: "That does not look like a valid weight.", comment: "Siri reply when the spoken weight is outside the allowed range.")
            }
        }
    }

    struct NutritionSummary {
        let calories: Int
        let protein: Double
        let calorieGoal: Int
    }

    struct LoggedWeight {
        let entry: WeightEntry
        let displayValue: Double
        let unitName: String
    }

    static func analyzeAndLogFood(description: String) async throws -> FoodEntry {
        let analysis = try await GeminiService.analyzeTextInput(description: description)
        let entry = foodEntry(from: analysis)

        let foodStore = FoodStore(observesExternalChanges: false)
        guard foodStore.addEntry(entry) else { throw FoodInputError.activeFast }

        HealthKitManager().writeNutrition(for: entry)
        publishAfterFoodChange(foodStore: foodStore)
        FoodStore.postExternalChangeNotification()

        return entry
    }

    static func todayNutritionSummary() -> NutritionSummary {
        let store = FoodStore(observesExternalChanges: false)
        let goal = UserProfile.load()?.effectiveCalories ?? 0
        return NutritionSummary(
            calories: store.todayCalories,
            protein: store.todayProtein,
            calorieGoal: goal
        )
    }

    static func logWeight(description: String) throws -> LoggedWeight {
        let parsed = try parseWeight(description)
        return logWeight(kg: parsed.kg, displayValue: parsed.displayValue, unitName: parsed.unitName)
    }

    private static func logWeight(kg: Double, displayValue: Double, unitName: String) -> LoggedWeight {
        let entry = WeightEntry(date: .now, weightKg: kg)
        let weightStore = WeightStore(observesExternalChanges: false)
        weightStore.addEntry(entry)

        HealthKitManager().writeWeight(for: entry)
        rescheduleNotificationsIfNeeded(foodStore: FoodStore(observesExternalChanges: false), weightStore: weightStore)
        WeightStore.postExternalChangeNotification()

        return LoggedWeight(entry: entry, displayValue: displayValue, unitName: unitName)
    }

    /// A unit named in a spoken weight. `jin` is the Chinese 斤, half a kilogram.
    enum SpokenWeightUnit: Equatable {
        case kilograms
        case pounds
        case jin
    }

    /// Word beginnings that name a weight unit in the app's languages. A word matches
    /// when it starts with one, so plurals and case endings match too (libras, funtów,
    /// кілограмів, キログラム, 75 kil in Czech).
    private static let unitWordPrefixes: [(prefix: String, unit: SpokenWeightUnit)] = [
        // English, and Turkish "pound"
        ("lb", .pounds), ("pound", .pounds),
        // es/pt libra, cs libra/liber, tr libre, it libbra, fr/ro livre/livră
        ("libr", .pounds), ("liber", .pounds), ("libbr", .pounds), ("livr", .pounds),
        // de Pfund, nl pond, pl/az funt, ru/uk фунт
        ("pfund", .pounds), ("pond", .pounds), ("funt", .pounds), ("фунт", .pounds),
        // zh, ja, ko, ar, hi
        ("磅", .pounds), ("ポンド", .pounds), ("파운드", .pounds),
        ("رطل", .pounds), ("أرطال", .pounds), ("ارطال", .pounds), ("باوند", .pounds),
        ("पाउंड", .pounds), ("पौंड", .pounds), ("पाउण्ड", .pounds),

        // kg, and kilo/kilogram/kila/kil in the Latin-script languages; az kq
        ("kg", .kilograms), ("kil", .kilograms), ("kq", .kilograms),
        // it chilo/chili/chilogrammi
        ("chilo", .kilograms), ("chili", .kilograms),
        // ru/uk кг, кило/кил/кілограм
        ("кг", .kilograms), ("кил", .kilograms), ("кіл", .kilograms),
        // zh, ja, ko, ar, hi
        ("公斤", .kilograms), ("千克", .kilograms), ("キロ", .kilograms), ("킬로", .kilograms), ("키로", .kilograms),
        ("كيلو", .kilograms), ("كغ", .kilograms), ("كجم", .kilograms), ("كلغ", .kilograms),
        ("किलो", .kilograms), ("किग्रा", .kilograms), ("केजी", .kilograms),

        // zh 斤 (500 g), the everyday unit for body weight in China
        ("斤", .jin),
    ]

    private static func unit(named word: Substring) -> SpokenWeightUnit? {
        unitWordPrefixes.first(where: { word.hasPrefix($0.prefix) })?.unit
    }

    /// Turkish says "kilo" for body weight too, so before the number "kilom 80" (my
    /// weight is 80) or "kilomu" names no unit. There a kilo- word counts only as
    /// kilo, kilos, kilogram… or the Azerbaijani kiloqram….
    private static func isWeightNoun(_ word: Substring) -> Bool {
        word.hasPrefix("kilo")
            && word != "kilo" && word != "kilos"
            && !word.hasPrefix("kilogram") && !word.hasPrefix("kiloqram")
    }

    /// The unit of the weight at `number`: the first unit word after the number
    /// ("75 kg", "75キロ"), or else the nearest one before it ("my weight in
    /// kilograms is 75").
    private static func spokenUnit(in text: String, around number: Range<String.Index>) -> SpokenWeightUnit? {
        let after = text[number.upperBound...].split(whereSeparator: { !$0.isLetter })
        if let found = after.lazy.compactMap({ unit(named: $0) }).first {
            return found
        }
        let before = text[..<number.lowerBound].split(whereSeparator: { !$0.isLetter })
        return before.reversed().lazy.filter { !isWeightNoun($0) }.compactMap { unit(named: $0) }.first
    }

    /// Rewrites digits from any script (Arabic-Indic ٧٥, Devanagari ७५, full-width ７５)
    /// as ASCII digits, so the number regex finds them.
    private static func asciiDigits(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.properties.numericType == .decimal, let digit = scalar.properties.numericValue {
                scalars.append(contentsOf: String(Int(digit)).unicodeScalars)
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    static func parseWeight(
        _ description: String,
        defaultUnit: WeightUnit = .current
    ) throws -> (kg: Double, displayValue: Double, unitName: String) {
        let normalized = asciiDigits(description)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: ",", with: ".")
            // Arabic decimal separator
            .replacingOccurrences(of: "٫", with: ".")

        guard let numberRange = normalized.range(
            of: #"[-+]?[0-9]*\.?[0-9]+"#,
            options: .regularExpression
        ), let value = Double(normalized[numberRange]) else {
            throw WeightInputError.missingNumber
        }

        let unit = spokenUnit(in: normalized, around: numberRange)
            ?? (defaultUnit == .kg ? .kilograms : .pounds)

        let kg: Double
        let displayValue: Double
        switch unit {
        case .kilograms:
            kg = value
            displayValue = value
        case .pounds:
            kg = value / 2.20462
            displayValue = value
        case .jin:
            kg = value / 2
            displayValue = kg
        }

        guard kg > 0, kg < 500 else {
            throw WeightInputError.invalidRange
        }

        return (
            kg: kg,
            displayValue: displayValue,
            unitName: unit == .pounds ? "pounds" : "kilograms"
        )
    }

    private static func foodEntry(from analysis: GeminiService.FoodAnalysis) -> FoodEntry {
        FoodEntry(
            name: analysis.name,
            calories: analysis.calories,
            protein: analysis.protein,
            carbs: analysis.carbs,
            fat: analysis.fat,
            timestamp: .now,
            emoji: analysis.emoji,
            source: .textInput,
            mealType: .currentMeal,
            sugar: analysis.sugar,
            addedSugar: analysis.addedSugar,
            fiber: analysis.fiber,
            saturatedFat: analysis.saturatedFat,
            monounsaturatedFat: analysis.monounsaturatedFat,
            polyunsaturatedFat: analysis.polyunsaturatedFat,
            cholesterol: analysis.cholesterol,
            caffeine: analysis.caffeine,
            supplementalNutrients: analysis.supplementalNutrients,
            sodium: analysis.sodium,
            potassium: analysis.potassium,
            transFat: analysis.transFat,
            calcium: analysis.calcium,
            iron: analysis.iron,
            magnesium: analysis.magnesium,
            zinc: analysis.zinc,
            vitaminA: analysis.vitaminA,
            vitaminC: analysis.vitaminC,
            vitaminD: analysis.vitaminD,
            vitaminB12: analysis.vitaminB12,
            vitaminE: analysis.vitaminE,
            vitaminK: analysis.vitaminK,
            folate: analysis.folate,
            omega3: analysis.omega3,
            servingSizeGrams: analysis.servingSizeGrams,
            servingUnitOptions: analysis.servingUnitOptions,
            selectedServingUnit: analysis.selectedServingUnit,
            selectedServingQuantity: analysis.selectedServingQuantity
        )
    }

    private static func publishAfterFoodChange(foodStore: FoodStore) {
        guard let profile = UserProfile.load() else { return }
        WidgetSnapshotWriter.publish(foods: foodStore.entries, profile: profile)
        rescheduleNotificationsIfNeeded(foodStore: foodStore, weightStore: WeightStore(observesExternalChanges: false))
    }

    private static func rescheduleNotificationsIfNeeded(foodStore: FoodStore, weightStore: WeightStore) {
        guard UserDefaults.standard.bool(forKey: "notificationsEnabled"),
              let profile = UserProfile.load()
        else { return }

        NotificationManager().rescheduleDataDependentNotifications(
            foodStore: foodStore,
            weightStore: weightStore,
            bodyFatStore: BodyFatStore(),
            profile: profile
        )
    }
}
