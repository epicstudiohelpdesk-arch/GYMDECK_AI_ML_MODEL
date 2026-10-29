package com.apoorvdarshan.calorietracker.data

import com.apoorvdarshan.calorietracker.models.ChatMessage
import com.apoorvdarshan.calorietracker.models.CoachExerciseProposal
import com.apoorvdarshan.calorietracker.models.CoachProposalCollector
import com.apoorvdarshan.calorietracker.models.UserExerciseDraft
import com.apoorvdarshan.calorietracker.models.WorkoutPersistedState
import com.apoorvdarshan.calorietracker.models.resolvingProposal
import com.apoorvdarshan.calorietracker.services.FoodImageStore
import com.apoorvdarshan.calorietracker.services.ai.CoachProposalApplier
import com.apoorvdarshan.calorietracker.services.ai.CoachTools
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import java.util.UUID

class CoachProposalApplyTest {
    private class MemoryStore : WorkoutStateStore {
        private val flow = MutableStateFlow(WorkoutPersistedState())
        override val workoutState = flow
        var writes = 0
            private set

        override suspend fun setWorkoutState(state: WorkoutPersistedState) {
            writes += 1
            flow.value = state
        }

        override suspend fun clearWorkoutState() {
            flow.value = WorkoutPersistedState()
        }
    }

    private val clock = Clock.fixed(Instant.parse("2026-10-17T12:00:00Z"), ZoneOffset.UTC)

    /** The same settings PreferencesStore reads the chat history with. */
    private val json = Json { ignoreUnknownKeys = true; coerceInputValues = true }
    private val imageStore = FoodImageStore.forTests(Files.createTempDirectory("coach-proposals").toFile())

    @Test
    fun onlyTheAddActionWritesToTheDiaryOrLibrary() = runBlocking {
        val store = MemoryStore()
        val repository = WorkoutRepository(store)
        val collector = CoachProposalCollector()
        val tools = tools(collector)

        tools.execute("propose_custom_exercise", mapOf("name" to "Coach Test Row", "primary_muscles" to listOf("lats")))
        tools.execute("propose_add_exercise_to_day", mapOf("catalog_id" to "Leg_Press", "sets" to 3, "reps" to 10))
        assertEquals(2, collector.proposals.size)
        assertEquals(0, store.writes)
        assertEquals(WorkoutPersistedState(), store.workoutState.value)

        // Dismissing never runs the write; tapping Add on the other card does.
        val message = ChatMessage(role = ChatMessage.Role.ASSISTANT, content = "Two ideas.", proposals = collector.proposals)
        val apply: suspend (CoachExerciseProposal) -> Boolean = {
            CoachProposalApplier.apply(it, repository, imageStore, library) == CoachProposalApplier.Outcome.APPLIED
        }
        val custom = collector.proposals.first()
        val addToDay = collector.proposals.last()
        val afterDismiss = listOf(message).resolvingProposal(message.id, custom.id, CoachExerciseProposal.Status.DISMISSED, apply)!!
        assertEquals(0, store.writes)
        afterDismiss.resolvingProposal(message.id, addToDay.id, CoachExerciseProposal.Status.ADDED, apply)!!
        assertTrue(repository.snapshot().userExercises.isEmpty())
        assertEquals(addToDay.entryId, repository.planNow("2026-10-17").exercises.single().id)
    }

    @Test
    fun applyingAnAddToDayProposalTwiceAddsOneEntry() = runBlocking {
        val repository = WorkoutRepository(MemoryStore())
        val proposal = propose("propose_add_exercise_to_day", mapOf("catalog_id" to "Leg_Press", "sets" to 3, "reps" to 10))

        assertEquals(CoachProposalApplier.Outcome.APPLIED, CoachProposalApplier.apply(proposal, repository, imageStore, library))
        assertEquals(CoachProposalApplier.Outcome.APPLIED, CoachProposalApplier.apply(proposal, repository, imageStore, library))

        val entry = repository.planNow("2026-10-17").exercises.single()
        assertEquals(proposal.entryId, entry.id)
        assertEquals("Leg_Press", entry.itemId)
        assertEquals(listOf("10", "10", "10"), entry.sets.map { it.reps })
        assertNull(entry.timer)
    }

    @Test
    fun applyingATimedProposalSavesTheDurationWithoutSets() = runBlocking {
        val repository = WorkoutRepository(MemoryStore())
        val proposal = propose(
            "propose_add_exercise_to_day",
            mapOf("catalog_id" to "Running_Treadmill", "date" to "2026-10-16", "duration_minutes" to 25)
        )

        assertEquals(CoachProposalApplier.Outcome.APPLIED, CoachProposalApplier.apply(proposal, repository, imageStore, library))

        val entry = repository.planNow("2026-10-16").exercises.single()
        assertTrue(entry.sets.isEmpty())
        assertEquals(1_500.0, entry.timer!!.savedSeconds, 0.0)
    }

    @Test
    fun applyingACustomExerciseProposalTwiceCreatesOneExercise() = runBlocking {
        val repository = WorkoutRepository(MemoryStore())
        val proposal = propose(
            "propose_custom_exercise",
            mapOf(
                "name" to "Iso-Lateral Row", "equipment" to "machine", "primary_muscles" to listOf("middle back"),
                "secondary_muscles" to listOf("biceps"), "instructions" to "Pull."
            )
        )

        assertEquals(CoachProposalApplier.Outcome.APPLIED, CoachProposalApplier.apply(proposal, repository, imageStore, emptyList()))
        assertEquals(CoachProposalApplier.Outcome.APPLIED, CoachProposalApplier.apply(proposal, repository, imageStore, emptyList()))

        val saved = repository.snapshot().userExercises.single()
        assertEquals(proposal.itemId, saved.itemId)
        assertEquals("Iso-Lateral Row", saved.name)
        assertEquals("Machine", saved.equipment)
        assertEquals(listOf("Middle Back"), saved.primaryMuscles)
        assertEquals(listOf("Biceps"), saved.secondaryMuscles)
        assertEquals(listOf("Pull."), saved.instructions)
    }

    @Test
    fun aCustomExerciseNameSavedWhileTheCardWaitedIsRefused() = runBlocking {
        val repository = WorkoutRepository(MemoryStore())
        // Each reply proposes against the library as it was, so two cards can share a name.
        val row = mapOf("name" to "Iso-Lateral Row", "primary_muscles" to listOf("middle back"))
        val earlier = propose("propose_custom_exercise", row)
        val later = propose("propose_custom_exercise", row)
        assertNotEquals(earlier.itemId, later.itemId)

        assertEquals(CoachProposalApplier.Outcome.APPLIED, CoachProposalApplier.apply(later, repository, imageStore, library))
        assertEquals(CoachProposalApplier.Outcome.NAME_TAKEN, CoachProposalApplier.apply(earlier, repository, imageStore, library))
        // The card that saved still retries as a no-op.
        assertEquals(CoachProposalApplier.Outcome.APPLIED, CoachProposalApplier.apply(later, repository, imageStore, library))
        assertEquals(listOf(later.itemId), repository.snapshot().userExercises.map { it.itemId })

        // An exercise the user made by hand, in another letter case, also blocks a waiting card,
        // and that card stays pending so the user can still dismiss it.
        val waiting = propose("propose_custom_exercise", mapOf("name" to "Cable Pullover", "primary_muscles" to listOf("lats")))
        repository.saveUserExercise(UserExerciseDraft(name = " cable pullover", primaryMuscles = listOf("Lats")), imageStore)
        val message = ChatMessage(role = ChatMessage.Role.ASSISTANT, content = "Try this.", proposals = listOf(waiting))
        assertNull(
            listOf(message).resolvingProposal(message.id, waiting.id, CoachExerciseProposal.Status.ADDED) {
                CoachProposalApplier.apply(it, repository, imageStore, library) == CoachProposalApplier.Outcome.APPLIED
            }
        )
        assertEquals(2, repository.snapshot().userExercises.size)
        assertTrue(repository.snapshot().userExercises.none { it.itemId == waiting.itemId })

        // So does a catalog exercise that reached the library after the card was made.
        val squat = propose("propose_custom_exercise", mapOf("name" to "Hack Squat", "primary_muscles" to listOf("quadriceps")))
        val updatedCatalog = library + item("Hack_Squat", "Hack Squat", "Strength", listOf("Quadriceps"))
        assertEquals(CoachProposalApplier.Outcome.NAME_TAKEN, CoachProposalApplier.apply(squat, repository, imageStore, updatedCatalog))
        assertEquals(2, repository.snapshot().userExercises.size)
    }

    @Test
    fun applyingAProposalForADeletedExerciseFailsWithoutWriting() = runBlocking {
        val store = MemoryStore()
        val proposal = propose("propose_add_exercise_to_day", mapOf("catalog_id" to "user_exercise_hammer"))
        val withoutIt = library.filterNot { it.id == "user_exercise_hammer" }

        assertEquals(
            CoachProposalApplier.Outcome.EXERCISE_MISSING,
            CoachProposalApplier.apply(proposal, WorkoutRepository(store), imageStore, withoutIt)
        )
        assertEquals(0, store.writes)
    }

    @Test
    fun aCardIsResolvedOnlyOnceAndOnlyAfterItsWriteSucceeds() = runBlocking {
        val message = ChatMessage(
            role = ChatMessage.Role.ASSISTANT,
            content = "Here you go.",
            proposals = listOf(proposal("p1"), proposal("p2"))
        )
        var applied = 0
        val history = listOf(message)

        // A failed write leaves the card pending.
        assertNull(history.resolvingProposal(message.id, "p1", CoachExerciseProposal.Status.ADDED) { applied++; false })
        val added = history.resolvingProposal(message.id, "p1", CoachExerciseProposal.Status.ADDED) { applied++; true }!!
        assertEquals(2, applied)
        assertEquals(CoachExerciseProposal.Status.ADDED, added.single().proposals.first().status)

        // A resolved card never runs its write again, and cannot be dismissed afterwards.
        assertNull(added.resolvingProposal(message.id, "p1", CoachExerciseProposal.Status.ADDED) { applied++; true })
        assertNull(added.resolvingProposal(message.id, "p1", CoachExerciseProposal.Status.DISMISSED))
        val dismissed = added.resolvingProposal(message.id, "p2", CoachExerciseProposal.Status.DISMISSED)!!
        assertNull(dismissed.resolvingProposal(message.id, "p2", CoachExerciseProposal.Status.ADDED) { applied++; true })
        assertNull(dismissed.resolvingProposal(UUID.randomUUID(), "p1", CoachExerciseProposal.Status.ADDED) { applied++; true })
        assertEquals(2, applied)

        // Outcomes survive the saved history, and the model hears about them on the next turn.
        val restored = json.decodeFromString(
            ListSerializer(ChatMessage.serializer()),
            json.encodeToString(ListSerializer(ChatMessage.serializer()), dismissed)
        ).single()
        assertEquals(listOf(CoachExerciseProposal.Status.ADDED, CoachExerciseProposal.Status.DISMISSED), restored.proposals.map { it.status })
        assertTrue(
            restored.contextContent.contains(
                "[Coach proposed adding \"Leg Press\" (catalog_id Leg_Press) to the workout diary on 2026-10-17: added by the user]"
            )
        )
        assertTrue(restored.contextContent.contains("dismissed by the user"))
    }

    @Test
    fun messagesSavedBeforeProposalsStillDecode() {
        val legacy = """[{"id":"6f9619ff-8b86-d011-b42d-00c04fc964ff","role":"assistant","content":"Hi","timestamp":0}]"""
        val decoded = json.decodeFromString(ListSerializer(ChatMessage.serializer()), legacy).single()
        assertTrue(decoded.proposals.isEmpty())
        assertEquals("Hi", decoded.contextContent)
    }

    private val library: List<ExerciseItem> = listOf(
        item("Leg_Press", "Leg Press", "Strength", listOf("Quadriceps")),
        item("Running_Treadmill", "Running, Treadmill", "Cardio", listOf("Quadriceps")),
        item("user_exercise_hammer", "Hammer Strength Chest Press", "Strength", listOf("Chest"))
    )

    private fun tools(collector: CoachProposalCollector) = CoachTools(
        weights = emptyList(),
        bodyFats = emptyList(),
        foods = emptyList(),
        exerciseLibrary = library,
        proposals = collector,
        clock = clock
    )

    private fun propose(tool: String, args: Map<String, Any?>): CoachExerciseProposal {
        val collector = CoachProposalCollector()
        tools(collector).execute(tool, args)
        return collector.proposals.single()
    }

    private fun proposal(id: String) = CoachExerciseProposal(
        id = id,
        kind = CoachExerciseProposal.Kind.ADD_TO_DAY,
        name = "Leg Press",
        itemId = "Leg_Press",
        dateKey = "2026-10-17",
        sets = 3,
        entryId = UUID.randomUUID()
    )

    private fun item(id: String, name: String, category: String, muscles: List<String>) = ExerciseItem(
        id = id,
        name = name,
        level = "Beginner",
        imagePaths = emptyList(),
        force = "Unspecified",
        mechanic = "Unspecified",
        category = category,
        equipment = "Machine",
        primaryMuscles = muscles,
        secondaryMuscles = emptyList(),
        instructions = emptyList()
    )
}
