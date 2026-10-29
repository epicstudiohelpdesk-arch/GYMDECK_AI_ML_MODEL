import Foundation

/// Reads the loosely typed arguments models send: numbers may arrive as strings,
/// booleans as numbers, dates as words. Pure functions, so they can be tested.
nonisolated enum VoiceAssistantParsing {
    // MARK: - Values

    static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A finite number from a JSON number or a numeric string ("2200", "1,5").
    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }
        guard let text = string(value) else { return nil }
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        guard let double = Double(normalized), double.isFinite else { return nil }
        return double
    }

    static func bool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.doubleValue != 0 }
        switch string(value)?.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return nil
        }
    }

    // MARK: - Dates

    enum DateError: Error, Equatable {
        case invalid
    }

    /// The start of the day for "today", "yesterday" or "yyyy-MM-dd" in the
    /// user's calendar; nil when no date was given.
    static func day(_ value: Any?, now: Date = .now, calendar: Calendar = .current) throws -> Date? {
        guard let text = string(value)?.lowercased() else { return nil }
        switch text {
        case "today":
            return calendar.startOfDay(for: now)
        case "yesterday":
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) else { throw DateError.invalid }
            return yesterday
        default:
            let parts = text.split(separator: "-").map(String.init)
            guard parts.count == 3, parts[0].count == 4,
                  let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
                  (1...12).contains(month), (1...31).contains(day) else { throw DateError.invalid }
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            guard let date = calendar.date(from: components),
                  calendar.component(.day, from: date) == day,
                  calendar.component(.month, from: date) == month else { throw DateError.invalid }
            return calendar.startOfDay(for: date)
        }
    }

    /// Hour and minute from "HH:mm" (24-hour); nil when no time was given.
    static func time(_ value: Any?) throws -> (hour: Int, minute: Int)? {
        guard let text = string(value) else { return nil }
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { throw DateError.invalid }
        return (hour, minute)
    }

    /// When something should be logged: the given day at the given time; with no
    /// time, now for today and the current time of day on another day (as Home does).
    static func logDate(day: Date?, time: (hour: Int, minute: Int)?, defaultDay: Date, now: Date = .now, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: day ?? defaultDay)
        if let time {
            return calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day) ?? day
        }
        if calendar.isDate(day, inSameDayAs: now) { return now }
        let clock = calendar.dateComponents([.hour, .minute, .second], from: now)
        return calendar.date(bySettingHour: clock.hour ?? 12, minute: clock.minute ?? 0, second: clock.second ?? 0, of: day) ?? day
    }

    static func isoDay(_ date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static func clockTime(_ date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    // MARK: - Units

    static let millilitersPerCup = 240.0
    static let millilitersPerGlass = 250.0
    static let millilitersPerFluidOunce = 29.5735295625
    static let poundsPerKilogram = 2.20462

    /// Water in whole milliliters for ml, l, oz, cup (240 ml) or glass (250 ml).
    static func milliliters(amount: Double, unit: String) -> Int? {
        guard amount.isFinite, amount > 0 else { return nil }
        let factor: Double
        switch unit.lowercased() {
        case "ml", "milliliter", "milliliters": factor = 1
        case "l", "liter", "liters", "litre", "litres": factor = 1000
        case "oz", "fl oz", "floz", "ounce", "ounces": factor = millilitersPerFluidOunce
        case "cup", "cups": factor = millilitersPerCup
        case "glass", "glasses": factor = millilitersPerGlass
        default: return nil
        }
        guard let milliliters = Int(exactly: (amount * factor).rounded()), milliliters > 0 else { return nil }
        return milliliters
    }

    /// Body weight in kilograms for kg or lb.
    static func kilograms(value: Double, unit: String) -> Double? {
        guard value.isFinite, value > 0 else { return nil }
        switch unit.lowercased() {
        case "kg", "kgs", "kilogram", "kilograms": return value
        case "lb", "lbs", "pound", "pounds": return value / poundsPerKilogram
        default: return nil
        }
    }

    static func mealType(_ value: Any?) -> MealType? {
        switch string(value)?.lowercased() {
        case "breakfast": .breakfast
        case "lunch": .lunch
        case "dinner": .dinner
        case "snack": .snack
        default: nil
        }
    }

    /// Grams from a serving text such as "1 bowl (250 g)" or "30g".
    static func grams(inServing serving: String?) -> Double? {
        guard let serving else { return nil }
        let pattern = #"(\d+(?:[.,]\d+)?)\s*(?:g|gram|grams)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: serving, range: NSRange(serving.startIndex..., in: serving)),
              let range = Range(match.range(at: 1), in: serving),
              let grams = Double(serving[range].replacingOccurrences(of: ",", with: ".")),
              grams.isFinite, grams > 0 else { return nil }
        return grams
    }
}
