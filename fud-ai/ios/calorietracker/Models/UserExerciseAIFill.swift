import Foundation

/// "Fill with AI" in the custom exercise editor (#499). The prompt lists the
/// catalog's own metadata values and the parser keeps only values from those
/// lists, so every prefilled field matches an editor option. Nothing is saved
/// here: the suggestion prefills the draft and the user reviews it.
enum UserExerciseAIFill {
    struct Options: Equatable {
        var categories: [String]
        var equipment: [String]
        var primaryMuscles: [String]
        var secondaryMuscles: [String]
    }

    struct Suggestion: Equatable {
        var name: String
        var category: String?
        var equipment: String?
        var primaryMuscles: [String] = []
        var secondaryMuscles: [String] = []
        var instructions: [String] = []
    }

    static let maxNameLength = 80
    static let maxPrimaryMuscles = 3
    static let maxSecondaryMuscles = 4
    static let maxInstructionSteps = 8
    static let maxInstructionLength = 300

    static func prompt(options: Options) -> String {
        """
        Identify the exercise in this photo. It may show a gym machine, a piece of exercise equipment, or a person doing the exercise. Your answer prefills a custom exercise form that the user reviews before saving.
        Respond ONLY with a JSON object in this exact format, no other text:
        {"name":"...","category":"...","equipment":"...","primary_muscles":["..."],"secondary_muscles":["..."],"instructions":["..."]}
        - name: the common name of the exercise, at most 60 characters.
        - category: exactly one value from the allowed categories.
        - equipment: exactly one value from the allowed equipment, or null when none fits.
        - primary_muscles: 1 to 3 main muscles worked, each from the allowed primary muscles.
        - secondary_muscles: up to 4 other muscles worked, each from the allowed secondary muscles. Never repeat a primary muscle.
        - instructions: 2 to 6 short steps for doing the exercise with good form, one step per item, without numbering.
        Copy every category, equipment and muscle value exactly as written in the lists below. Never use a value that is not listed.
        If the photo shows no exercise, exercise equipment or person exercising, return {"name":null}.
        Allowed categories: \(jsonList(options.categories))
        Allowed equipment: \(jsonList(options.equipment))
        Allowed primary muscles: \(jsonList(options.primaryMuscles))
        Allowed secondary muscles: \(jsonList(options.secondaryMuscles))
        """
    }

    /// Reads the AI reply. A missing name means the reply is unusable; any
    /// category, equipment or muscle outside `options` is dropped.
    static func parse(_ response: String, options: Options) throws -> Suggestion {
        let jsonString = GeminiService.extractJSON(from: response)
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawName = json["name"] as? String
        else { throw GeminiService.AnalysisError.invalidResponse }

        let name = String(collapsingWhitespace(rawName).prefix(maxNameLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw GeminiService.AnalysisError.invalidResponse }

        let primaryMuscles = Array(matches(json["primary_muscles"], in: options.primaryMuscles)
            .prefix(maxPrimaryMuscles))
        let secondaryMuscles = Array(matches(json["secondary_muscles"], in: options.secondaryMuscles)
            .filter { !primaryMuscles.contains($0) }
            .prefix(maxSecondaryMuscles))

        return Suggestion(
            name: name,
            category: match(json["category"], in: options.categories),
            equipment: match(json["equipment"], in: options.equipment),
            primaryMuscles: primaryMuscles,
            secondaryMuscles: secondaryMuscles,
            instructions: instructionSteps(json["instructions"])
        )
    }

    /// The allowed value that `raw` names, ignoring case, accents and spacing.
    static func match(_ raw: Any?, in allowed: [String]) -> String? {
        guard let text = raw as? String else { return nil }
        let key = matchKey(text)
        guard !key.isEmpty else { return nil }
        return allowed.first { matchKey($0) == key }
    }

    private static func matches(_ raw: Any?, in allowed: [String]) -> [String] {
        let values: [Any]
        if let array = raw as? [Any] {
            values = array
        } else if let single = raw as? String {
            values = [single]
        } else {
            return []
        }
        var result: [String] = []
        for value in values {
            if let allowedValue = match(value, in: allowed), !result.contains(allowedValue) {
                result.append(allowedValue)
            }
        }
        return result
    }

    private static func instructionSteps(_ raw: Any?) -> [String] {
        let texts: [String]
        if let array = raw as? [Any] {
            texts = array.compactMap { $0 as? String }
        } else if let text = raw as? String {
            texts = [text]
        } else {
            return []
        }
        return Array(
            texts
                .flatMap { $0.components(separatedBy: .newlines) }
                .map(stepText)
                .filter { !$0.isEmpty }
                .prefix(maxInstructionSteps)
                .map { String($0.prefix(maxInstructionLength)) }
        )
    }

    /// Trims a step and drops a leading list marker such as "1.", "2)" or "-".
    private static func stepText(_ line: String) -> String {
        let trimmed = collapsingWhitespace(line)
        guard let marker = trimmed.range(of: #"^(?:\d{1,2}[.)]|[-*•])\s+"#, options: .regularExpression) else {
            return trimmed
        }
        return String(trimmed[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matchKey(_ value: String) -> String {
        collapsingWhitespace(value)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func collapsingWhitespace(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func jsonList(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.withoutEscapingSlashes]) else {
            return "[]"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

extension UserExerciseDraft {
    /// Prefills the editor from an AI suggestion. Fields the AI left out or
    /// answered with an unlisted value keep their current values; the photo is
    /// untouched and nothing is saved until the user taps Save.
    mutating func apply(_ suggestion: UserExerciseAIFill.Suggestion) {
        name = suggestion.name
        if let category = suggestion.category {
            self.category = category
        }
        if let equipment = suggestion.equipment {
            rawEquipment = equipment
        }
        if !suggestion.primaryMuscles.isEmpty {
            primaryMuscles = suggestion.primaryMuscles
        }
        let suggestedSecondary = suggestion.secondaryMuscles.filter { !primaryMuscles.contains($0) }
        if !suggestedSecondary.isEmpty {
            secondaryMuscles = suggestedSecondary
        } else if !suggestion.primaryMuscles.isEmpty {
            // No usable secondary muscles: keep the current ones, minus any that are now primary.
            secondaryMuscles.removeAll { primaryMuscles.contains($0) }
        }
        if !suggestion.instructions.isEmpty {
            instructions = suggestion.instructions.joined(separator: "\n")
        }
    }
}
