package com.apoorvdarshan.calorietracker.ui.onboarding

import android.content.IntentSender
import com.apoorvdarshan.calorietracker.backup.CloudBackupFormatException
import com.apoorvdarshan.calorietracker.backup.CloudBackupNoSpaceException
import com.apoorvdarshan.calorietracker.backup.CloudBackupNotFoundException
import com.apoorvdarshan.calorietracker.backup.CloudBackupSignInRequiredException
import java.time.Instant
import kotlin.math.roundToInt

/** What a returning user can bring back. Runs in this order: the Drive backup is the full
 *  snapshot, and the Health Connect import afterwards only adds to it. */
enum class ReturningSource { DRIVE, HEALTH }

enum class ReturningPhase {
    /** Picking sources. */
    SELECTING,
    /** Working through the picked sources one after another. */
    RUNNING,
    /** Every picked source finished; the step list shows how each went. */
    FINISHED
}

enum class ReturningStepStatus { WAITING, WORKING, DONE, FAILED, SKIPPED }

/** One-line outcome under a step. */
enum class ReturningMessage {
    SIGN_IN_FAILED,
    DRIVE_CANCELLED,
    NO_BACKUP,
    DRIVE_UNREACHABLE,
    NO_SPACE,
    NOT_A_BACKUP,
    NEEDS_NEWER_APP,
    SETUP_MISSING,
    HEALTH_DENIED,
    HEALTH_UNAVAILABLE,
    HEALTH_READ_FAILED
}

/** Which Health Connect import summary to show. */
enum class HealthImportSummary { NOTHING, MEALS, WEIGH_INS, MEALS_AND_WEIGH_INS, OTHER_DATA }

data class ReturningStep(
    val source: ReturningSource,
    val status: ReturningStepStatus = ReturningStepStatus.WAITING,
    val message: ReturningMessage? = null,
    /** Drive: the backup is downloading and being applied, past sign-in and lookup. */
    val restoring: Boolean = false
)

/** What the local stores hold, to tell what a Health Connect import added. */
data class HealthRecordCounts(val meals: Int = 0, val weighIns: Int = 0, val other: Int = 0) {
    operator fun minus(before: HealthRecordCounts) = HealthRecordCounts(
        meals = (meals - before.meals).coerceAtLeast(0),
        weighIns = (weighIns - before.weighIns).coerceAtLeast(0),
        other = (other - before.other).coerceAtLeast(0)
    )
}

/**
 * The Welcome back sub-screen of the WELCOME step, for people who used Fud AI before.
 * It is a state of WELCOME, not an [OnboardingStep], so progress, tags and back stay as they are.
 */
data class ReturningUserState(
    val visible: Boolean = false,
    /** The launch-time Health Connect check ran, or the user chose something first; it never
     *  opens this screen after that. */
    val promotionSettled: Boolean = false,
    val selected: Set<ReturningSource> = emptySet(),
    val phase: ReturningPhase = ReturningPhase.SELECTING,
    val steps: List<ReturningStep> = emptyList(),
    /** Google asks for consent: the screen launches this, then clears it. */
    val driveConsent: IntentSender? = null,
    /** A backup was found; waiting for the user to confirm it replaces this phone. */
    val confirmingRestore: Boolean = false,
    val backupModifiedAt: Instant? = null,
    /** The Health Connect step started: the screen opens its sheet once, then clears this. */
    val healthPermissionRequested: Boolean = false,
    /** A backup was applied in this run, so later imports may only add to it. */
    val restoredBackup: Boolean = false,
    /** ...and it held a finished setup, so Continue opens the app instead of the setup. */
    val restoredSetup: Boolean = false,
    val healthAdded: HealthRecordCounts? = null,
    /** Relaunch the app so every screen loads the restored data. */
    val restartRequested: Boolean = false
) {
    /** Sources run one after another; the screen can't be left until they finish. */
    val busy: Boolean get() = phase == ReturningPhase.RUNNING || restartRequested

    val canContinue: Boolean get() = phase == ReturningPhase.SELECTING && selected.isNotEmpty()

    val anyStepUnfinished: Boolean
        get() = steps.any { it.status == ReturningStepStatus.FAILED || it.status == ReturningStepStatus.SKIPPED }

    fun step(source: ReturningSource): ReturningStep? = steps.firstOrNull { it.source == source }

    /** Health Connect grants that are still there (in-app Delete All Data keeps them) suggest
     *  a returning user. Opens the screen only while the plain welcome is still showing and
     *  the user hasn't picked anything yet; a later check or a second answer changes nothing. */
    fun afterGrantCheck(granted: Boolean, step: OnboardingStep): ReturningUserState =
        if (promotionSettled) this
        else copy(promotionSettled = true, visible = granted && step == OnboardingStep.WELCOME)

    /** Opens the screen. A run that finished without restoring anything starts over at the
     *  picker; anything else (a run in progress, or a restore) comes back as it was. */
    fun opened(): ReturningUserState =
        if (phase == ReturningPhase.FINISHED && !restoredBackup) {
            copy(
                visible = true, promotionSettled = true, phase = ReturningPhase.SELECTING,
                steps = emptyList(), backupModifiedAt = null, healthAdded = null
            )
        } else {
            copy(visible = true, promotionSettled = true)
        }

    /** Back to the plain welcome. Not while working, and never once a backup is applied:
     *  Get Started would then run the full setup over the restored data. */
    fun closed(): ReturningUserState =
        if (busy || restoredBackup) this else copy(visible = false, promotionSettled = true)

    fun toggled(source: ReturningSource): ReturningUserState {
        if (phase != ReturningPhase.SELECTING) return this
        return copy(selected = if (source in selected) selected - source else selected + source)
    }

    /** Continue: the first picked source starts, the rest wait their turn. */
    fun started(): ReturningUserState {
        if (!canContinue) return this
        val ordered = ReturningSource.values().filter { it in selected }
        return advance(copy(phase = ReturningPhase.RUNNING, steps = ordered.map { ReturningStep(it) }, healthAdded = null))
    }

    /** [source] ended; the next waiting source starts, or the run finishes. */
    fun finished(
        source: ReturningSource,
        status: ReturningStepStatus,
        message: ReturningMessage? = null
    ): ReturningUserState {
        // A late callback for a step that already ended changes nothing.
        if (phase != ReturningPhase.RUNNING || step(source)?.status != ReturningStepStatus.WORKING) return this
        val updated = copy(
            steps = steps.map {
                if (it.source == source) it.copy(status = status, message = message, restoring = false) else it
            },
            confirmingRestore = if (source == ReturningSource.DRIVE) false else confirmingRestore,
            driveConsent = if (source == ReturningSource.DRIVE) null else driveConsent
        )
        return advance(updated)
    }

    fun restoring(): ReturningUserState = copy(
        confirmingRestore = false,
        steps = steps.map { if (it.source == ReturningSource.DRIVE) it.copy(restoring = true) else it }
    )

    /**
     * Try again after a failed or skipped step. With nothing restored, every choice is safe
     * again, so it returns to the picker. After a restore only the Health Connect import can
     * run again: restoring once more, or Start fresh, would undo what came back.
     */
    fun retried(): ReturningUserState {
        if (phase != ReturningPhase.FINISHED) return this
        if (!restoredBackup) {
            return copy(phase = ReturningPhase.SELECTING, steps = emptyList(), backupModifiedAt = null, healthAdded = null)
        }
        val health = step(ReturningSource.HEALTH) ?: ReturningStep(ReturningSource.HEALTH)
        if (health.status == ReturningStepStatus.DONE) return this
        val steps = steps.filter { it.source != ReturningSource.HEALTH } + health.copy(status = ReturningStepStatus.WAITING, message = null)
        return advance(copy(phase = ReturningPhase.RUNNING, steps = steps))
    }

    private fun advance(state: ReturningUserState): ReturningUserState {
        if (state.steps.any { it.status == ReturningStepStatus.WORKING }) return state
        val next = state.steps.firstOrNull { it.status == ReturningStepStatus.WAITING }
            ?: return state.copy(phase = ReturningPhase.FINISHED)
        return state.copy(
            steps = state.steps.map { if (it.source == next.source) it.copy(status = ReturningStepStatus.WORKING) else it },
            healthPermissionRequested = next.source == ReturningSource.HEALTH
        )
    }
}

/** What a failed Drive lookup or restore tells the user. Anything unrecognized is treated as
 *  Drive being unreachable, which is what offline, timeouts and HTTP errors all mean here. */
fun returningDriveMessage(failure: Throwable): ReturningMessage = when (failure) {
    is CloudBackupNotFoundException -> ReturningMessage.NO_BACKUP
    is CloudBackupSignInRequiredException -> ReturningMessage.SIGN_IN_FAILED
    is CloudBackupNoSpaceException -> ReturningMessage.NO_SPACE
    is CloudBackupFormatException ->
        if (failure.needsNewerApp) ReturningMessage.NEEDS_NEWER_APP else ReturningMessage.NOT_A_BACKUP
    else -> ReturningMessage.DRIVE_UNREACHABLE
}

fun healthImportSummary(added: HealthRecordCounts): HealthImportSummary = when {
    added.meals > 0 && added.weighIns > 0 -> HealthImportSummary.MEALS_AND_WEIGH_INS
    added.meals > 0 -> HealthImportSummary.MEALS
    added.weighIns > 0 -> HealthImportSummary.WEIGH_INS
    added.other > 0 -> HealthImportSummary.OTHER_DATA
    else -> HealthImportSummary.NOTHING
}

private const val LBS_PER_KG = 2.20462

/**
 * The newest Health Connect weigh-in as the onboarding weight: rounded to the wheel's 0.1 kg
 * and kept inside the wheel for the chosen unit (30–250 kg, or 60–500 lb). Null when the
 * reading can't be a body weight.
 */
fun onboardingWeightFromReading(kg: Double, weightMetric: Boolean): Double? {
    if (!kg.isFinite() || kg <= 0.0) return null
    val range = if (weightMetric) 30.0..250.0 else (60.0 / LBS_PER_KG)..(500.0 / LBS_PER_KG)
    return ((kg * 10).roundToInt() / 10.0).coerceIn(range)
}

/**
 * The newest Health Connect body-fat reading (a fraction) as the onboarding value: rounded to
 * the wheel's 0.5 % steps and kept inside its 3–60 %. Null for readings outside 0–100 %.
 */
fun onboardingBodyFatFromReading(fraction: Double): Double? {
    if (!fraction.isFinite() || fraction <= 0.0 || fraction > 1.0) return null
    val halfPercents = (fraction * 200).roundToInt().coerceIn(6, 120)
    return halfPercents / 200.0
}
