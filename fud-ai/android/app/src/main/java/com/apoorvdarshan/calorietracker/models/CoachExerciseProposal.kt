package com.apoorvdarshan.calorietracker.models

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.util.UUID

/**
 * A workout change Coach suggests in chat. Coach can only propose: nothing is written until the
 * user taps Add on the card shown under the reply, and a resolved card never applies again.
 * Mirrors iOS CoachExerciseProposal.
 */
@Serializable
data class CoachExerciseProposal(
    val id: String,
    val kind: Kind,
    val status: Status = Status.PENDING,
    /** The new exercise's name, or the library exercise being added. */
    val name: String,
    /**
     * Custom exercise: the id it is saved under, chosen up front so Add can never create it twice.
     * Add to day: the catalog or custom exercise id.
     */
    val itemId: String,
    val category: String? = null,
    val equipment: String? = null,
    val primaryMuscles: List<String> = emptyList(),
    val secondaryMuscles: List<String> = emptyList(),
    val instructions: List<String> = emptyList(),
    val dateKey: String? = null,
    val sets: Int? = null,
    val reps: Int? = null,
    val durationMinutes: Int? = null,
    /** The diary entry's id, chosen up front so Add can never append the exercise twice. */
    @Serializable(with = UuidSerializer::class)
    val entryId: UUID? = null
) {
    @Serializable
    enum class Kind {
        @SerialName("custom_exercise") CUSTOM_EXERCISE,
        @SerialName("add_to_day") ADD_TO_DAY
    }

    @Serializable
    enum class Status {
        @SerialName("pending") PENDING,
        @SerialName("added") ADDED,
        @SerialName("dismissed") DISMISSED
    }

    /** True when two proposals suggest the same change, so a repeated tool call shows one card. */
    fun suggestsSameChange(other: CoachExerciseProposal): Boolean {
        if (kind != other.kind) return false
        return when (kind) {
            Kind.CUSTOM_EXERCISE -> name.equals(other.name, ignoreCase = true)
            Kind.ADD_TO_DAY -> itemId == other.itemId && dateKey == other.dateKey && sets == other.sets &&
                reps == other.reps && durationMinutes == other.durationMinutes
        }
    }

    /** What the model is told about this card on later turns, so it knows what the user did. */
    val contextLine: String
        get() {
            val outcome = when (status) {
                Status.PENDING -> "waiting for the user to tap Add"
                Status.ADDED -> "added by the user"
                Status.DISMISSED -> "dismissed by the user"
            }
            return when (kind) {
                Kind.CUSTOM_EXERCISE -> "[Coach proposed creating the custom exercise \"$name\": $outcome]"
                Kind.ADD_TO_DAY ->
                    "[Coach proposed adding \"$name\" (catalog_id $itemId) to the workout diary on ${dateKey ?: "today"}: $outcome]"
            }
        }
}

/** Collects the proposals Coach makes while answering one message, for the chat to show as cards. */
class CoachProposalCollector {
    private val collected = mutableListOf<CoachExerciseProposal>()

    val proposals: List<CoachExerciseProposal>
        get() = synchronized(collected) { collected.toList() }

    /** A provider fallback re-runs the whole reply, so proposals from a failed attempt are dropped. */
    fun reset() {
        synchronized(collected) { collected.clear() }
    }

    /**
     * Keeps the proposal and returns it, or returns the earlier card for the same change.
     * Returns null once a reply already holds [MAX_PROPOSALS] proposals.
     */
    fun add(proposal: CoachExerciseProposal): CoachExerciseProposal? = synchronized(collected) {
        collected.firstOrNull { it.suggestsSameChange(proposal) }?.let { return it }
        if (collected.size >= MAX_PROPOSALS) return null
        collected += proposal
        proposal
    }

    companion object {
        const val MAX_PROPOSALS = 10
    }
}

/**
 * Resolves one card in a saved conversation. Returns null, without calling [apply], when the
 * proposal is missing or no longer pending, and also when [apply] reports a failure, so a card is
 * marked added only after its write succeeded and a second tap never writes twice.
 */
suspend fun List<ChatMessage>.resolvingProposal(
    messageId: UUID,
    proposalId: String,
    status: CoachExerciseProposal.Status,
    apply: suspend (CoachExerciseProposal) -> Boolean = { true }
): List<ChatMessage>? {
    val message = firstOrNull { it.id == messageId } ?: return null
    val proposal = message.proposals.firstOrNull { it.id == proposalId } ?: return null
    if (proposal.status != CoachExerciseProposal.Status.PENDING || status == CoachExerciseProposal.Status.PENDING) return null
    if (status == CoachExerciseProposal.Status.ADDED && !apply(proposal)) return null
    return map { candidate ->
        if (candidate.id != messageId) {
            candidate
        } else {
            candidate.copy(proposals = candidate.proposals.map {
                if (it.id == proposalId) it.copy(status = status) else it
            })
        }
    }
}
