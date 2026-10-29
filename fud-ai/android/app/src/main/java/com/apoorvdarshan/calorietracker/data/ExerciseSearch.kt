package com.apoorvdarshan.calorietracker.data

/**
 * Lowercased word lists precomputed once per exercise so library search does not
 * re-tokenize every item on each keystroke. Mirrors iOS `ExerciseSearchIndex`.
 */
class ExerciseSearchIndex(name: String, metadata: List<String>) {
    val nameWords: List<String> = ExerciseSearch.words(name)

    /**
     * The name words joined without separators, starting at each word in turn
     * ("cablechestpress", "chestpress", "press"), so phrase matches stay word-aligned
     * and "pushup" / "push up" / "push-up" all compare equal.
     */
    val nameSuffixes: List<String> = nameWords.indices.map { nameWords.drop(it).joinToString("") }

    /**
     * Equipment, category, and primary-muscle values with their words joined
     * ("lowerback", "bodyonly"). They only match a query that names one of them as a
     * whole ("cable", "lower back", or an alias such as "abs"), so free-text queries
     * such as "chest press" still need every word in the name. Instructions and
     * secondary muscles are never searched: they mention many unrelated words.
     */
    val metadataTerms: List<String> =
        metadata.map { ExerciseSearch.words(it).joinToString("") }.filter { it.isNotEmpty() }
}

/**
 * Tokenized AND search over exercise names, with optional query aliases and
 * relevance ranking: exact name > name prefix > phrase inside the name >
 * every word in the name > query that names a muscle group, equipment, or category.
 */
object ExerciseSearch {
    private val aliases = mapOf(
        "cable pushdown" to "Triceps_Pushdown",
        "triceps cable pushdown" to "Triceps_Pushdown",
        "tricep cable pushdown" to "Triceps_Pushdown",
        "tricep pushdown" to "Triceps_Pushdown",
    )

    /**
     * Gym shorthand that is not a prefix of the catalog value it means, mapped to
     * [ExerciseSearchIndex.metadataTerms] values. Applies only to the whole query.
     * Mirrors iOS `ExerciseSearchMatcher.metadataAliases`.
     */
    private val metadataAliases = mapOf(
        "abs" to listOf("abdominals"),
        "core" to listOf("abdominals"),
        "pec" to listOf("chest"),
        "pecs" to listOf("chest"),
        "pectoral" to listOf("chest"),
        "pectorals" to listOf("chest"),
        "delt" to listOf("shoulders"),
        "delts" to listOf("shoulders"),
        "deltoid" to listOf("shoulders"),
        "deltoids" to listOf("shoulders"),
        "quads" to listOf("quadriceps"),
        "hams" to listOf("hamstrings"),
        "calf" to listOf("calves"),
        "trapezius" to listOf("traps"),
        "back" to listOf("lats", "middleback", "lowerback"),
        "bodyweight" to listOf("bodyonly"),
    )

    // Marks stay inside words so Devanagari vowel signs and combining accents do not split
    // them (Swift's Character-based split already keeps those graphemes whole).
    private val wordSeparators = Regex("[^\\p{L}\\p{M}\\p{N}]+")

    /** Lowercased runs of letters and digits; punctuation and whitespace separate words. */
    fun words(text: String): List<String> =
        text.lowercase().split(wordSeparators).filter { it.isNotEmpty() }

    fun tokens(query: String): List<String> = words(query)

    /**
     * Relevance rank for [query] (lower is better), or null when the item does not match.
     * An empty query matches everything with rank 0.
     */
    fun relevance(index: ExerciseSearchIndex, query: String, exerciseId: String): Int? {
        val queryTokens = tokens(query)
        if (queryTokens.isEmpty()) return 0

        val compactQuery = queryTokens.joinToString("")
        val compactName = index.nameSuffixes.firstOrNull().orEmpty()
        if (aliases[queryTokens.joinToString(" ")] == exerciseId || compactName == compactQuery) return 0
        if (compactName.startsWith(compactQuery)) return 1
        if (index.nameSuffixes.drop(1).any { it.startsWith(compactQuery) }) return 2
        if (queryTokens.all { token -> index.nameWords.any { wordMatches(it, token) } }) return 3
        val aliasTerms = metadataAliases[queryTokens.joinToString(" ")].orEmpty()
        if (index.metadataTerms.any { it.startsWith(compactQuery) || it in aliasTerms }) return 4
        return null
    }

    fun relevance(item: ExerciseItem, query: String): Int? = relevance(item.searchIndex, query, item.id)

    fun matches(item: ExerciseItem, query: String): Boolean = relevance(item, query) != null

    /**
     * Word-prefix match, so "tricep" finds "Triceps" but "press" no longer matches
     * inside unrelated words. Non-ASCII tokens also match inside a word because
     * scripts such as Japanese or Chinese do not separate words with spaces.
     * Plural tokens also match the singular word ("abs" finds "Ab", "curls" finds "Curl").
     */
    private fun wordMatches(word: String, token: String): Boolean {
        if (word.startsWith(token)) return true
        if (token.any { it.code > 127 }) return word.contains(token)
        if (token.length < 3 || !token.endsWith("s")) return false
        return word == token.dropLast(1) || (token.endsWith("es") && word == token.dropLast(2))
    }
}
