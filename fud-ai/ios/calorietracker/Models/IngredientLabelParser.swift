import Foundation

/// One entry of a scanned ingredient label, for display only (#428).
nonisolated struct IngredientLabelItem: Equatable, Sendable {
    nonisolated struct Segment: Equatable, Sendable {
        let text: String
        /// Open Food Facts marks declared allergens with underscores, e.g. `_milk_`.
        let isAllergen: Bool
    }

    let segments: [Segment]
    /// True when the entry mentions one of the user's allergen sensitivities.
    let matchesSensitivity: Bool

    var text: String { segments.map(\.text).joined() }

    /// Whether VoiceOver announces the entry as a possible allergen: it matches a
    /// sensitivity, or Open Food Facts flags part of it (shown in bold, which
    /// VoiceOver does not read).
    var announcesAllergen: Bool { matchesSensitivity || segments.contains(where: \.isAllergen) }
}

/// A scanned ingredient label split for display (#428).
nonisolated struct IngredientLabel: Equatable, Sendable {
    /// One entry per ingredient. Empty when the label does not make a useful list.
    let items: [IngredientLabelItem]
    /// Sentences after the ingredient list, such as "May contain traces of nuts.",
    /// kept whole so precautionary statements never read as ingredients.
    var notes: [IngredientLabelItem] = []
    /// The whole label as one entry when it does not make a useful list, so a
    /// single-ingredient label or one longer than `maxItems` keeps its
    /// sensitivity warning. Nil for a list or a blank label.
    var paragraph: IngredientLabelItem?
}

/// Turns an Open Food Facts ingredient label into a readable list (#428).
/// Display only: the stored label and the allergen check keep using the whole
/// text, and label entries never become macro-bearing meal ingredients.
/// Mirrors Android `IngredientLabelParser`; keep both in sync.
enum IngredientLabelParser {
    /// Longer labels stay a paragraph so nothing is cut off.
    static let maxItems = 60

    /// The label's first sentence split into entries, plus any later sentences
    /// as notes. The entries are empty when that sentence does not make a useful
    /// list (a single entry, or more than `maxItems`); show `paragraph` instead.
    static func parse(_ text: String, sensitivities: [String] = []) -> IngredientLabel {
        let sentences = splitSentences(strippingHeading(from: text))
        let parts = splitTopLevel(sentences.first ?? "")
        guard parts.count > 1, parts.count <= maxItems else {
            let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return IngredientLabel(
                items: [],
                paragraph: whole.isEmpty ? nil : item(from: whole, sensitivities: sensitivities)
            )
        }
        return IngredientLabel(
            items: parts.map { item(from: $0, sensitivities: sensitivities) },
            notes: sentences.dropFirst()
                .map(collapsingWhitespace)
                .filter { !$0.isEmpty }
                .map { item(from: $0, sensitivities: sensitivities) }
        )
    }

    /// The entries of `parse(_:sensitivities:)`.
    static func items(from text: String, sensitivities: [String] = []) -> [IngredientLabelItem] {
        parse(text, sensitivities: sensitivities).items
    }

    private static func item(from text: String, sensitivities: [String]) -> IngredientLabelItem {
        let segments = segments(in: text)
        let plain = segments.map(\.text).joined()
        return IngredientLabelItem(
            segments: segments,
            matchesSensitivity: AllergenAnalysis.mentionsAny(of: sensitivities, in: plain)
        )
    }

    /// Open Food Facts' `ingredients_text` often carries no allergen markers; the
    /// allergens it flags are in `ingredients_text_with_allergens` as
    /// `<span class="allergen">` tags. Returns `plain` with those spans turned into
    /// the `_allergen_` markers `segments(in:)` reads, or `plain` itself when the
    /// markup is missing or does not match it word for word.
    static func markingAllergens(plain: String?, markup: String?) -> String? {
        let fallback = plain
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        guard let markup, !markup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
        var converted = ""
        var cursor = markup.startIndex
        for match in allergenSpan.matches(in: markup, range: NSRange(markup.startIndex..., in: markup)) {
            guard let whole = Range(match.range, in: markup),
                  let innerRange = Range(match.range(at: 1), in: markup)
            else { continue }
            converted += markup[cursor..<whole.lowerBound]
            let inner = removingSpanTags(String(markup[innerRange])).replacingOccurrences(of: "_", with: "")
            // Spaces and punctuation at the edges stay outside the marker ("contenir: _cacahuète_").
            let leading = inner.prefix(while: isMarkerEdge)
            let rest = inner.dropFirst(leading.count)
            let trailing = String(rest.reversed().prefix(while: isMarkerEdge).reversed())
            let core = rest.dropLast(trailing.count)
            converted += core.isEmpty ? inner : String(leading) + "_" + String(core) + "_" + trailing
            cursor = whole.upperBound
        }
        converted += markup[cursor...]
        let marked = decodingEntities(removingSpanTags(converted)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !marked.isEmpty else { return fallback }
        if let fallback, comparable(marked) != comparable(fallback) { return fallback }
        return marked
    }

    /// Splits `_allergen_` markers into emphasized segments and drops stray underscores.
    static func segments(in text: String) -> [IngredientLabelItem.Segment] {
        var result: [IngredientLabelItem.Segment] = []
        var plain = ""
        var remaining = Substring(text)
        while let open = remaining.firstIndex(of: "_") {
            let afterOpen = remaining.index(after: open)
            guard let close = remaining[afterOpen...].firstIndex(of: "_") else { break }
            plain += remaining[..<open]
            let marked = String(remaining[afterOpen..<close])
            if marked.trimmingCharacters(in: .whitespaces).isEmpty {
                plain += marked
            } else {
                if !plain.isEmpty {
                    result.append(.init(text: plain, isAllergen: false))
                    plain = ""
                }
                result.append(.init(text: marked, isAllergen: true))
            }
            remaining = remaining[remaining.index(after: close)...]
        }
        plain += remaining.replacingOccurrences(of: "_", with: "")
        if !plain.isEmpty {
            result.append(.init(text: plain, isAllergen: false))
        }
        return result
    }

    /// Removes a leading "Ingredients:" style heading in the app's label languages.
    static func strippingHeading(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return trimmed }
        let heading = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
        guard !heading.isEmpty,
              heading.count <= 30,
              !heading.contains(where: { separators.contains($0) || openers.contains($0) })
        else { return trimmed }
        let lowered = heading.lowercased()
        let folded = lowered.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        guard headingStems.contains(where: { lowered.contains($0) || folded.contains($0) }) else { return trimmed }
        return String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits at full stops outside brackets that end a sentence: followed by a
    /// line break, by a capitalised word ("… acerola. May contain …"), or by a
    /// precautionary statement in any case ("… salt. may contain …"). Decimals
    /// ("8.7%") and abbreviations before a single letter ("vit. C") stay together.
    /// Each sentence keeps its full stop.
    static func splitSentences(_ text: String) -> [String] {
        let characters = Array(text)
        var sentences: [String] = []
        var current = ""
        var depth = 0
        for (index, character) in characters.enumerated() {
            current.append(character)
            if openers.contains(character) {
                depth += 1
            } else if closers.contains(character) {
                depth = max(0, depth - 1)
            } else if depth == 0, character == ".", endsSentence(characters, at: index) {
                sentences.append(current)
                current = ""
            }
        }
        sentences.append(current)
        return sentences
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Splits on commas and semicolons outside brackets, keeping decimal commas ("8,7%").
    static func splitTopLevel(_ text: String) -> [String] {
        let characters = Array(text)
        var parts: [String] = []
        var current = ""
        var depth = 0
        for (index, character) in characters.enumerated() {
            if openers.contains(character) {
                depth += 1
            } else if closers.contains(character) {
                depth = max(0, depth - 1)
            } else if depth == 0,
                      separators.contains(character),
                      !isDecimalComma(characters, at: index) {
                parts.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        parts.append(current)
        return parts.map(clean).filter { !$0.isEmpty }
    }

    private static let separators: Set<Character> = [",", ";", "，", "；", "、", "\u{060C}", "\u{061B}"]
    private static let openers: Set<Character> = ["(", "[", "{", "（", "［", "【"]
    private static let closers: Set<Character> = [")", "]", "}", "）", "］", "】"]
    private static let headingStems = [
        "ingred", "zutaten", "składnik", "skladnik", "slozeni", "icindekiler", "tərkib", "terkib",
        "состав", "склад", "配料", "原材料", "원재료", "المكونات", "सामग्री"
    ]
    /// Precautionary statements that end the list after a full stop even in lower
    /// case ("salt. may contain nuts"), compared without case or accents.
    private static let statementStarts = [
        "may contain", "contains", "traces", "allergy advice", "allergen advice",
        "peut contenir", "contient", "kann spuren", "kann enthalten", "enthält",
        "puede contener", "contiene", "può contenere", "kan sporen", "kan bevatten", "bevat",
        "może zawierać", "zawiera", "pode conter", "contém", "poate conține", "conține",
        "может содержать", "содержит", "може містити", "містить", "může obsahovat", "obsahuje",
        "eser miktarda", "قد يحتوي", "يحتوي"
    ].map(folded)

    private static let allergenSpan = try! NSRegularExpression(
        pattern: #"<span\s+class\s*=\s*["']allergen["']\s*>(.*?)</span\s*>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let markerEdgePunctuation: Set<Character> = [
        ":", ";", ",", ".", "：", "；", "，", "、", "。", "\u{060C}", "\u{061B}"
    ]
    private static let spanTag = try! NSRegularExpression(pattern: #"</?span\b[^>]*>"#, options: [.caseInsensitive])
    private static let htmlEntity = try! NSRegularExpression(
        pattern: #"&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|amp|lt|gt|quot|apos|nbsp);"#
    )
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}"
    ]

    private static func endsSentence(_ characters: [Character], at index: Int) -> Bool {
        var next = index + 1
        guard next < characters.count, characters[next].isWhitespace else { return false }
        var lineBreak = false
        while next < characters.count, characters[next].isWhitespace {
            if characters[next].isNewline { lineBreak = true }
            next += 1
        }
        guard next < characters.count else { return false }
        return lineBreak
            || (characters[next].isUppercase && next + 1 < characters.count && characters[next + 1].isLetter)
            || startsStatement(characters, at: next)
    }

    private static func startsStatement(_ characters: [Character], at index: Int) -> Bool {
        let window = folded(String(characters[index..<min(characters.count, index + 48)]))
        return statementStarts.contains { phrase in
            guard window.hasPrefix(phrase) else { return false }
            return window.dropFirst(phrase.count).first.map { !$0.isLetter } ?? true
        }
    }

    /// Lower case without accents, matching Android's NFD folding.
    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func isMarkerEdge(_ character: Character) -> Bool {
        character.isWhitespace || markerEdgePunctuation.contains(character)
    }

    private static func removingSpanTags(_ text: String) -> String {
        spanTag.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
    }

    private static func decodingEntities(_ text: String) -> String {
        var result = ""
        var cursor = text.startIndex
        for match in htmlEntity.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text),
                  let nameRange = Range(match.range(at: 1), in: text)
            else { continue }
            result += text[cursor..<whole.lowerBound]
            let name = String(text[nameRange])
            let codePoint: UInt32? = if name.hasPrefix("#x") || name.hasPrefix("#X") {
                UInt32(name.dropFirst(2), radix: 16)
            } else if name.hasPrefix("#") {
                UInt32(name.dropFirst())
            } else {
                nil
            }
            if let codePoint {
                result += Unicode.Scalar(codePoint).map { String(Character($0)) } ?? String(text[whole])
            } else {
                result += namedEntities[name] ?? String(text[whole])
            }
            cursor = whole.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// Entities decoded on both sides, so a plain label that still has `&amp;` can match.
    private static func comparable(_ text: String) -> String {
        collapsingWhitespace(decodingEntities(text).replacingOccurrences(of: "_", with: ""))
    }

    private static func collapsingWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isDecimalComma(_ characters: [Character], at index: Int) -> Bool {
        guard characters[index] == ",", index > 0, index + 1 < characters.count else { return false }
        return isASCIIDigit(characters[index - 1]) && isASCIIDigit(characters[index + 1])
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character.isASCII && character.isWholeNumber
    }

    private static func clean(_ part: String) -> String {
        var value = collapsingWhitespace(part)
        while let last = value.last, last == "." || last == "。" || last == " " {
            value.removeLast()
        }
        return value
    }
}
