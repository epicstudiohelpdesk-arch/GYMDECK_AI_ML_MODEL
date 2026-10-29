package com.apoorvdarshan.calorietracker.models

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant
import java.util.UUID

@Serializable
data class ChatMessage(
    @Serializable(with = UuidSerializer::class)
    val id: UUID = UUID.randomUUID(),
    val role: Role,
    val content: String,
    val attachmentImageBase64: String? = null,
    @Serializable(with = InstantSerializer::class)
    val timestamp: Instant = Instant.now(),
    /** Workout changes Coach proposed in this reply, shown as Add / Dismiss cards. */
    val proposals: List<CoachExerciseProposal> = emptyList()
) {
    @Serializable
    enum class Role {
        @SerialName("user") USER,
        @SerialName("assistant") ASSISTANT
    }

    /** The text sent back to the model as history: the reply plus what became of each proposal. */
    val contextContent: String
        get() = if (proposals.isEmpty()) content else (listOf(content) + proposals.map { it.contextLine }).joinToString("\n")
}
