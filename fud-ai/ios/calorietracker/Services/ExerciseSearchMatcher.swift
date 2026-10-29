import Foundation

/// Lowercased word lists precomputed once per exercise so library search does not
/// re-tokenize every item on each keystroke.
struct ExerciseSearchIndex: Hashable, Sendable {
    let nameWords: [String]
    /// The name words joined without separators, starting at each word in turn
    /// ("cablechestpress", "chestpress", "press"), so phrase matches stay word-aligned
    /// and "pushup" / "push up" / "push-up" all compare equal.
    let nameSuffixes: [String]
    /// Equipment, category, and primary-muscle values with their words joined
    /// ("lowerback", "bodyonly"). They only match a query that names one of them as a
    /// whole ("cable", "lower back", or an alias such as "abs"), so free-text queries
    /// such as "chest press" still need every word in the name. Instructions and
    /// secondary muscles are never searched: they mention many unrelated words.
    let metadataTerms: [String]

    nonisolated init(name: String, metadata: [String]) {
        let nameWords = ExerciseSearchMatcher.words(in: name)
        self.nameWords = nameWords
        self.nameSuffixes = nameWords.indices.map { nameWords[$0...].joined() }
        self.metadataTerms = metadata
            .map { ExerciseSearchMatcher.words(in: $0).joined() }
            .filter { !$0.isEmpty }
    }
}

/// Tokenized AND search over exercise names, with optional query aliases and
/// relevance ranking: exact name > name prefix > phrase inside the name >
/// every word in the name > query that names a muscle group, equipment, or category.
enum ExerciseSearchMatcher {
    /// Maps common multi-word phrases to catalog exercise IDs.
    nonisolated static let aliases: [String: String] = [
        "cable pushdown": "Triceps_Pushdown",
        "triceps cable pushdown": "Triceps_Pushdown",
        "tricep cable pushdown": "Triceps_Pushdown",
        "tricep pushdown": "Triceps_Pushdown",
    ]

    /// Gym shorthand that is not a prefix of the catalog value it means, mapped to
    /// `ExerciseSearchIndex.metadataTerms` values. Applies only to the whole query.
    nonisolated static let metadataAliases: [String: [String]] = [
        "abs": ["abdominals"],
        "core": ["abdominals"],
        "pec": ["chest"],
        "pecs": ["chest"],
        "pectoral": ["chest"],
        "pectorals": ["chest"],
        "delt": ["shoulders"],
        "delts": ["shoulders"],
        "deltoid": ["shoulders"],
        "deltoids": ["shoulders"],
        "quads": ["quadriceps"],
        "hams": ["hamstrings"],
        "calf": ["calves"],
        "trapezius": ["traps"],
        "back": ["lats", "middleback", "lowerback"],
        "bodyweight": ["bodyonly"],
    ]

    /// Lowercased runs of letters and digits; punctuation and whitespace separate words.
    nonisolated static func words(in text: String) -> [String] {
        text
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    nonisolated static func tokens(from query: String) -> [String] {
        words(in: query)
    }

    /// Relevance rank for `query` (lower is better), or nil when the item does not match.
    /// An empty query matches everything with rank 0.
    nonisolated static func relevance(of index: ExerciseSearchIndex, query: String, exerciseID: String) -> Int? {
        let tokens = tokens(from: query)
        guard !tokens.isEmpty else { return 0 }

        let compactQuery = tokens.joined()
        let compactName = index.nameSuffixes.first ?? ""
        if aliases[tokens.joined(separator: " ")] == exerciseID || compactName == compactQuery {
            return 0
        }
        if compactName.hasPrefix(compactQuery) {
            return 1
        }
        if index.nameSuffixes.dropFirst().contains(where: { $0.hasPrefix(compactQuery) }) {
            return 2
        }
        if tokens.allSatisfy({ token in index.nameWords.contains { word($0, matches: token) } }) {
            return 3
        }
        let aliasTerms = metadataAliases[tokens.joined(separator: " ")] ?? []
        if index.metadataTerms.contains(where: { $0.hasPrefix(compactQuery) || aliasTerms.contains($0) }) {
            return 4
        }
        return nil
    }

    nonisolated static func relevance(of item: ExerciseLibraryItem, query: String) -> Int? {
        relevance(of: item.searchIndex, query: query, exerciseID: item.id)
    }

    nonisolated static func matches(_ item: ExerciseLibraryItem, query: String) -> Bool {
        relevance(of: item, query: query) != nil
    }

    /// Word-prefix match, so "tricep" finds "Triceps" but "press" no longer matches
    /// inside unrelated words. Non-ASCII tokens also match inside a word because
    /// scripts such as Japanese or Chinese do not separate words with spaces.
    /// Plural tokens also match the singular word ("abs" finds "Ab", "curls" finds "Curl").
    nonisolated private static func word(_ word: String, matches token: String) -> Bool {
        if word.hasPrefix(token) { return true }
        guard token.allSatisfy(\.isASCII) else { return word.contains(token) }
        guard token.count >= 3, token.hasSuffix("s") else { return false }
        return word == token.dropLast() || (token.hasSuffix("es") && word == token.dropLast(2))
    }
}
