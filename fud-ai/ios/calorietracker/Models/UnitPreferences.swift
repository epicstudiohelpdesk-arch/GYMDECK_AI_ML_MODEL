import Foundation

// MARK: - Unit Preferences

/// Length display unit. Governs height + body-measurement display/input and the
/// AI prompt height lines. Stored values stay canonical metric (cm) everywhere.
enum HeightUnit: String {
    case cm
    case ftin

    nonisolated static let storageKey = "heightUnit"

    /// Current preference for non-view code (services, app-level calls).
    /// Views should bind `@AppStorage("heightUnit")` directly.
    nonisolated static var current: HeightUnit {
        HeightUnit(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .ftin
    }
}

/// Mass display unit. Governs weight/goal-weight display/input, the weight chart,
/// AI prompt weight/rate lines, and the Siri unit-less fallback. Stored values
/// stay canonical metric (kg) everywhere.
enum WeightUnit: String {
    case kg
    case lbs

    nonisolated static let storageKey = "weightUnit"

    /// Current preference for non-view code (services, app-level calls).
    /// Views should bind `@AppStorage("weightUnit")` directly.
    nonisolated static var current: WeightUnit {
        WeightUnit(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .lbs
    }
}

/// Energy display unit. Governs every user-visible calorie amount and every
/// calorie input. Stored values (food entries, goals, workout burns, Health
/// samples, AI requests and replies, exports) stay canonical kilocalories;
/// only display and typed input convert, so switching never rewrites data.
nonisolated enum EnergyUnit: String, CaseIterable, Identifiable, Sendable {
    case kcal
    case kj

    static let storageKey = "energyUnit"
    static let defaultUnit = EnergyUnit.kcal
    /// Thermochemical calorie: 1 kcal = 4.184 kJ.
    static let kilojoulesPerKilocalorie = 4.184

    /// Current preference for non-view code (notifications, widgets, voice).
    /// Views bind `@AppStorage(EnergyUnit.storageKey)` directly.
    static var current: EnergyUnit { current(in: .standard) }

    static func current(in defaults: UserDefaults) -> EnergyUnit {
        EnergyUnit(rawValue: defaults.string(forKey: storageKey) ?? "") ?? defaultUnit
    }

    var id: String { rawValue }

    /// Short unit label shown next to numbers ("kcal" / "kJ").
    var symbol: String {
        switch self {
        case .kcal: String(localized: "kcal")
        case .kj: String(localized: "kJ")
        }
    }

    /// Picker option title.
    var title: String {
        switch self {
        case .kcal: String(localized: "Kilocalories (kcal)")
        case .kj: String(localized: "Kilojoules (kJ)")
        }
    }

    /// Unrounded display amount, for charts and averages.
    func displayAmount(kcal: Double) -> Double {
        self == .kj ? kcal * Self.kilojoulesPerKilocalorie : kcal
    }

    /// Whole display units for a stored kcal amount (kJ rounds to whole numbers).
    func displayValue(kcal: Int) -> Int {
        Int(displayAmount(kcal: Double(kcal)).rounded())
    }

    /// Unrounded kcal for an amount typed in this unit.
    func kcalAmount(fromDisplayed value: Double) -> Double {
        self == .kj ? value / Self.kilojoulesPerKilocalorie : value
    }

    /// Whole stored kcal for an amount typed in this unit.
    func kcal(fromDisplayed value: Double) -> Int {
        Int(kcalAmount(fromDisplayed: value).rounded())
    }

    /// Parses an amount typed in this unit ("5021", "5,021", "5021.5") into
    /// whole stored kcal. Nil for empty, non-numeric or negative input.
    func kcal(fromInput text: String, locale: Locale = .current) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        let value = formatter.number(from: trimmed)?.doubleValue
            ?? Double(trimmed.replacingOccurrences(of: ",", with: "."))
        guard let value, value.isFinite, value >= 0 else { return nil }
        return kcal(fromDisplayed: value)
    }

    /// Grouped display number without a unit, e.g. "5,021".
    func number(kcal: Int, locale: Locale = .current) -> String {
        displayValue(kcal: kcal).formatted(.number.locale(locale))
    }

    /// Display amount with its unit, e.g. "1,200 kcal" or "5,021 kJ".
    func format(kcal: Int, locale: Locale = .current) -> String {
        format(displayed: displayValue(kcal: kcal), locale: locale)
    }

    /// An amount already in this unit (e.g. a difference of two display
    /// values) with its unit.
    func format(displayed value: Int, locale: Locale = .current) -> String {
        let number = value.formatted(.number.locale(locale))
        switch self {
        case .kcal: return String(localized: "\(number) kcal")
        case .kj: return String(localized: "\(number) kJ")
        }
    }

    /// Prompt line asking an AI model to answer a kJ user in kJ. Every energy
    /// number in prompts, tool arguments and replies the app parses stays kcal;
    /// nil for kcal users, whose prompts don't change.
    func aiReplyInstruction(toolArguments: Bool = false) -> String? {
        guard self == .kj else { return nil }
        var line = "Energy unit: this user reads energy in kilojoules (kJ). Every energy number given to you is kcal; whenever you state an energy amount to the user, convert it to kJ (1 kcal = 4.184 kJ, whole numbers)."
        if toolArguments {
            line += " When the user gives an amount in kJ, convert it to kcal for any tool argument."
        }
        return line
    }

    /// Calorie goal wheel: 800–6,000 kcal in 50 kcal steps, or the same span
    /// in 100 kJ steps.
    var goalPickerRange: ClosedRange<Int> { self == .kj ? 3_400...25_100 : 800...6_000 }
    var goalPickerStep: Int { self == .kj ? 100 : 50 }

    /// Where the goal wheel opens for a stored kcal goal: its display value
    /// snapped down to a step and clamped into the wheel's range.
    func goalPickerStart(currentKcal: Int) -> Int {
        let snapped = (displayValue(kcal: currentKcal) / goalPickerStep) * goalPickerStep
        return min(max(snapped, goalPickerRange.lowerBound), goalPickerRange.upperBound)
    }

    /// Stored kcal goal for a wheel pick. A kcal goal almost never lands on a
    /// 100 kJ step, so saving an untouched kJ wheel keeps the exact goal
    /// instead of nudging it by up to 24 kcal.
    func goalKcal(fromPicked value: Int, currentKcal: Int) -> Int {
        if self == .kj, value == goalPickerStart(currentKcal: currentKcal) {
            return currentKcal
        }
        return kcal(fromDisplayed: Double(value))
    }
}

enum UnitPreferenceMigration {
    /// One-time migration from the legacy single `useMetric` flag to the split
    /// height/weight unit preferences. Runs before any view reads the new keys,
    /// so existing users see zero change (metric -> cm + kg, imperial -> ftin + lbs).
    /// The legacy key is left in storage untouched.
    nonisolated static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: HeightUnit.storageKey) == nil else { return }
        let useMetric = defaults.bool(forKey: "useMetric")
        defaults.set((useMetric ? HeightUnit.cm : HeightUnit.ftin).rawValue, forKey: HeightUnit.storageKey)
        defaults.set((useMetric ? WeightUnit.kg : WeightUnit.lbs).rawValue, forKey: WeightUnit.storageKey)
    }
}
