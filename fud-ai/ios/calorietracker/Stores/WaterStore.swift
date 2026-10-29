import Foundation

enum WaterSettings {
    static let enabledKey = "waterTrackingEnabled"
    static let dailyGoalKey = "waterDailyGoalMl"
    static let unitKey = "waterUnit"
    static let reminderEnabledKey = "waterReminderEnabled"
    static let reminderHourKey = "waterReminderHour"
    static let reminderMinuteKey = "waterReminderMinute"
    static let entriesKey = "waterEntries"

    static let defaultDailyGoalMl = 2_000
    static let dailyGoalOptions = [1_500, 2_000, 2_500, 3_000, 3_500, 4_000]
}

/// The three one-tap water amounts in the Home + menu. Stored in milliliters as
/// comma-separated text ("250,500,750"), the same format Android uses.
enum WaterQuickAddPresets {
    static let key = "waterQuickAddPresetsMl"
    static let defaults = [250, 500, 750]
    static let validRange = 1...5_000

    /// Missing or malformed values fall back to the defaults; valid ones come back smallest first.
    static func decode(_ raw: String?) -> [Int] {
        let values = (raw ?? "")
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard values.count == defaults.count, values.allSatisfy(validRange.contains) else { return defaults }
        return values.sorted()
    }

    static func encode(_ presets: [Int]) -> String {
        presets.sorted().map(String.init).joined(separator: ",")
    }

    /// "250 · 500 · 750 ml" for the settings row.
    static func summary(_ presets: [Int], unit: WaterUnit) -> String {
        presets.map { unit.displayValue(forMilliliters: $0) }.joined(separator: " · ") + " \(unit.symbol)"
    }

    /// Plain digits for a text field: no grouping separators, at most one decimal for fl oz.
    static func editingText(forMilliliters milliliters: Int, unit: WaterUnit) -> String {
        guard unit == .fluidOunces else { return String(milliliters) }
        let ounces = (unit.displayAmount(forMilliliters: milliliters) * 10).rounded() / 10
        return ounces == ounces.rounded() ? String(Int(ounces)) : String(format: "%.1f", ounces)
    }

    /// Keeps digits (and one decimal for fl oz), like the custom water amount field.
    static func filteredInput(_ value: String, unit: WaterUnit) -> String {
        let filtered = value.filter { $0.isNumber || (unit == .fluidOunces && ($0 == "." || $0 == ",")) }
        let normalized = filtered.replacingOccurrences(of: ",", with: ".")
        let pieces = normalized.split(separator: ".", omittingEmptySubsequences: false)
        return String((pieces.count > 1 ? "\(pieces[0]).\(pieces[1].prefix(1))" : normalized).prefix(6))
    }

    /// Milliliters for an edited amount, or nil when it is empty or outside `validRange`.
    static func milliliters(fromEditingText text: String, unit: WaterUnit) -> Int? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")), value > 0 else { return nil }
        let milliliters = unit.milliliters(fromDisplayedValue: value)
        return validRange.contains(milliliters) ? milliliters : nil
    }

    /// Milliliters for each edited field, or nil for an invalid one. Fields still showing
    /// their saved text keep the saved milliliters instead of round-tripping through fl oz.
    static func resolvedMilliliters(
        texts: [String],
        savedTexts: [String],
        savedMilliliters: [Int],
        unit: WaterUnit
    ) -> [Int?] {
        texts.indices.map { index in
            if savedTexts.indices.contains(index), savedMilliliters.indices.contains(index),
               texts[index] == savedTexts[index] {
                return savedMilliliters[index]
            }
            return milliliters(fromEditingText: texts[index], unit: unit)
        }
    }

    /// The amounts to save when the edit screen closes, or nil while any of the three
    /// fields is empty or out of range, so the saved presets stay as they were.
    static func editedPresets(
        texts: [String],
        savedTexts: [String],
        savedMilliliters: [Int],
        unit: WaterUnit
    ) -> [Int]? {
        let resolved = resolvedMilliliters(
            texts: texts,
            savedTexts: savedTexts,
            savedMilliliters: savedMilliliters,
            unit: unit
        )
        let values = resolved.compactMap { $0 }
        guard values.count == defaults.count, values.count == resolved.count else { return nil }
        return values
    }
}

enum WaterUnit: String, CaseIterable, Identifiable {
    case milliliters = "ml"
    case fluidOunces = "floz"

    static let defaultUnit = WaterUnit.milliliters
    static let millilitersPerFluidOunce = 29.5735295625

    var id: String { rawValue }
    var title: String { self == .milliliters ? "Milliliters" : "Fluid Ounces" }
    var symbol: String { self == .milliliters ? "ml" : "fl oz" }
    var accessibilityName: String { self == .milliliters ? "milliliters" : "fluid ounces" }

    func displayAmount(forMilliliters milliliters: Int) -> Double {
        self == .milliliters
            ? Double(milliliters)
            : Double(milliliters) / Self.millilitersPerFluidOunce
    }

    func displayValue(forMilliliters milliliters: Int) -> String {
        if self == .milliliters { return milliliters.formatted() }
        let ounces = displayAmount(forMilliliters: milliliters)
        if abs(ounces.rounded() - ounces) < 0.05 { return Int(ounces.rounded()).formatted() }
        return ounces.formatted(.number.precision(.fractionLength(1)))
    }

    func formatted(milliliters: Int) -> String {
        "\(displayValue(forMilliliters: milliliters)) \(symbol)"
    }

    func milliliters(fromDisplayedValue value: Double) -> Int {
        let converted = self == .milliliters ? value : value * Self.millilitersPerFluidOunce
        return max(1, Int(converted.rounded()))
    }
}

struct WaterEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let milliliters: Int

    init(id: UUID = UUID(), date: Date = .now, milliliters: Int) {
        self.id = id
        self.date = date
        self.milliliters = milliliters
    }
}

@Observable
final class WaterStore {
    private(set) var entries: [WaterEntry] = []
    var onEntriesChanged: (() -> Void)?
    private let entriesBlob: PersistedBlobGuard

    /// True while an unreadable blob is on disk without a backup copy.
    var isPersistenceBlocked: Bool { entriesBlob.isWriteBlocked }

    init(defaults: UserDefaults = .standard, corruptBackupDirectory: URL? = nil) {
        self.entriesBlob = PersistedBlobGuard(
            defaults: defaults,
            key: WaterSettings.entriesKey,
            backupDirectory: corruptBackupDirectory
        )
        load(isInitialLoad: true)
    }

    private func load(isInitialLoad: Bool) {
        switch entriesBlob.loadList(WaterEntry.self) {
        case .missing:
            entries = []
        case .decoded(let decoded, _):
            entries = decoded
        case .corrupt:
            if isInitialLoad { entries = [] }
        }
    }

    @discardableResult
    func add(milliliters: Int, on date: Date) -> WaterEntry? {
        add(id: UUID(), milliliters: milliliters, on: date)
    }

    /// The Watch request UUID becomes the entry UUID so a retried connectivity
    /// transfer can never add the same glass twice.
    @discardableResult
    func add(id: UUID, milliliters: Int, on date: Date) -> WaterEntry? {
        guard milliliters > 0 else { return nil }
        guard !isPersistenceBlocked else { return nil }
        if let existing = entries.first(where: { $0.id == id }) { return existing }
        let entry = WaterEntry(id: id, date: date, milliliters: milliliters)
        entries.append(entry)
        save()
        onEntriesChanged?()
        return entry
    }

    func delete(id: UUID) {
        guard !isPersistenceBlocked else { return }
        entries.removeAll { $0.id == id }
        save()
        onEntriesChanged?()
    }

    func reloadFromDefaults() {
        load(isInitialLoad: false)
        onEntriesChanged?()
    }

    func replaceEntriesFromImport(_ imported: [WaterEntry]) {
        guard !isPersistenceBlocked else { return }
        entries = imported
        save()
        onEntriesChanged?()
    }

    func clear() {
        guard entriesBlob.remove() else { return }
        entries = []
        onEntriesChanged?()
    }

    func entries(on date: Date) -> [WaterEntry] {
        entries
            .filter { Calendar.current.isDate($0.date, inSameDayAs: date) }
            .sorted { $0.date > $1.date }
    }

    func total(on date: Date) -> Int {
        entries(on: date)
            .reduce(0) { $0 + $1.milliliters }
    }

    private func save() {
        entriesBlob.save(entries)
    }
}
