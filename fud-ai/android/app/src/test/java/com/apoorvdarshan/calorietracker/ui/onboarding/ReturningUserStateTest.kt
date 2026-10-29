package com.apoorvdarshan.calorietracker.ui.onboarding

import com.apoorvdarshan.calorietracker.backup.CloudBackupFormatException
import com.apoorvdarshan.calorietracker.backup.CloudBackupNoSpaceException
import com.apoorvdarshan.calorietracker.backup.CloudBackupNotFoundException
import com.apoorvdarshan.calorietracker.backup.CloudBackupSignInRequiredException
import com.apoorvdarshan.calorietracker.ui.onboarding.ReturningSource.DRIVE
import com.apoorvdarshan.calorietracker.ui.onboarding.ReturningSource.HEALTH
import com.apoorvdarshan.calorietracker.ui.onboarding.ReturningStepStatus.DONE
import com.apoorvdarshan.calorietracker.ui.onboarding.ReturningStepStatus.FAILED
import com.apoorvdarshan.calorietracker.ui.onboarding.ReturningStepStatus.SKIPPED
import com.apoorvdarshan.calorietracker.ui.onboarding.ReturningStepStatus.WAITING
import com.apoorvdarshan.calorietracker.ui.onboarding.ReturningStepStatus.WORKING
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException

class ReturningUserStateTest {

    private fun picked(vararg sources: ReturningSource): ReturningUserState =
        sources.fold(ReturningUserState().opened()) { state, source -> state.toggled(source) }

    private fun ReturningUserState.statuses() = steps.map { it.source to it.status }

    // -- Opening -------------------------------------------------------------------------

    @Test
    fun survivingHealthConnectGrantsOpenWelcomeBackOnTheWelcomeStep() {
        val state = ReturningUserState().afterGrantCheck(granted = true, step = OnboardingStep.WELCOME)
        assertTrue(state.visible)
        assertTrue(state.promotionSettled)
    }

    @Test
    fun noGrantsKeepThePlainWelcome() {
        val state = ReturningUserState().afterGrantCheck(granted = false, step = OnboardingStep.WELCOME)
        assertFalse(state.visible)
        assertTrue(state.promotionSettled)
    }

    @Test
    fun aLateCheckNeverPullsTheUserBackFromLaterSteps() {
        val state = ReturningUserState().afterGrantCheck(granted = true, step = OnboardingStep.GENDER)
        assertFalse(state.visible)
        assertFalse(state.afterGrantCheck(granted = true, step = OnboardingStep.WELCOME).visible)
    }

    @Test
    fun aCheckAfterTheUserChoseChangesNothing() {
        val closed = ReturningUserState().opened().closed()
        assertEquals(closed, closed.afterGrantCheck(granted = true, step = OnboardingStep.WELCOME))
        val opened = ReturningUserState().opened()
        assertEquals(opened, opened.afterGrantCheck(granted = false, step = OnboardingStep.WELCOME))
    }

    // -- Picking -------------------------------------------------------------------------

    @Test
    fun continueNeedsAtLeastOneSource() {
        val none = ReturningUserState().opened()
        assertFalse(none.canContinue)
        assertEquals(none, none.started())
        assertTrue(none.toggled(HEALTH).canContinue)
        assertFalse(none.toggled(HEALTH).toggled(HEALTH).canContinue)
    }

    @Test
    fun bothRunDriveFirstAndHealthWaits() {
        val running = picked(HEALTH, DRIVE).started()
        assertEquals(ReturningPhase.RUNNING, running.phase)
        assertEquals(listOf(DRIVE to WORKING, HEALTH to WAITING), running.statuses())
        assertFalse(running.healthPermissionRequested)
        assertTrue(running.busy)
    }

    @Test
    fun healthAloneAsksForItsSheetRightAway() {
        val running = picked(HEALTH).started()
        assertEquals(listOf(HEALTH to WORKING), running.statuses())
        assertTrue(running.healthPermissionRequested)
    }

    @Test
    fun theSelectionIsFixedOnceItRuns() {
        val running = picked(DRIVE).started()
        assertEquals(running, running.toggled(HEALTH))
    }

    // -- Running -------------------------------------------------------------------------

    @Test
    fun aFailedRestoreStillRunsTheHealthImportAndSaysWhichStepFailed() {
        val afterDrive = picked(DRIVE, HEALTH).started()
            .finished(DRIVE, FAILED, ReturningMessage.DRIVE_UNREACHABLE)
        assertEquals(listOf(DRIVE to FAILED, HEALTH to WORKING), afterDrive.statuses())
        assertEquals(ReturningMessage.DRIVE_UNREACHABLE, afterDrive.step(DRIVE)!!.message)
        assertTrue(afterDrive.healthPermissionRequested)
        assertFalse(afterDrive.restoredBackup)

        val finished = afterDrive.copy(healthPermissionRequested = false).finished(HEALTH, DONE)
        assertEquals(ReturningPhase.FINISHED, finished.phase)
        assertTrue(finished.anyStepUnfinished)
        assertFalse(finished.busy)
    }

    @Test
    fun aCancelledRestoreMovesOnToo() {
        val state = picked(DRIVE, HEALTH).started().copy(confirmingRestore = true)
            .finished(DRIVE, SKIPPED, ReturningMessage.DRIVE_CANCELLED)
        assertFalse(state.confirmingRestore)
        assertEquals(HEALTH to WORKING, state.statuses().last())
    }

    @Test
    fun theDriveRowShowsRestoringOnceConfirmed() {
        val state = picked(DRIVE).started().copy(confirmingRestore = true).restoring()
        assertFalse(state.confirmingRestore)
        assertTrue(state.step(DRIVE)!!.restoring)
        assertFalse(state.finished(DRIVE, DONE).step(DRIVE)!!.restoring)
    }

    @Test
    fun aLateCallbackForAFinishedStepChangesNothing() {
        val afterDrive = picked(DRIVE, HEALTH).started().finished(DRIVE, DONE)
        assertEquals(afterDrive, afterDrive.finished(DRIVE, FAILED, ReturningMessage.SIGN_IN_FAILED))
        val finished = picked(DRIVE).started().finished(DRIVE, DONE)
        assertEquals(finished, finished.finished(DRIVE, FAILED))
    }

    // -- Leaving and retrying ------------------------------------------------------------

    @Test
    fun theScreenCantBeLeftWhileWorkingOrAfterARestore() {
        assertTrue(picked(DRIVE).started().closed().visible)
        val restored = picked(DRIVE).started().copy(restoredBackup = true, restoredSetup = true).finished(DRIVE, DONE)
        assertEquals(ReturningPhase.FINISHED, restored.phase)
        assertTrue(restored.closed().visible)
        val restarting = ReturningUserState().opened().copy(restartRequested = true)
        assertTrue(restarting.closed().visible)
    }

    @Test
    fun pickingAndUnrestoredResultsCanBeLeft() {
        assertFalse(ReturningUserState().opened().closed().visible)
        val failed = picked(DRIVE).started().finished(DRIVE, FAILED, ReturningMessage.NO_BACKUP)
        assertFalse(failed.closed().visible)
    }

    @Test
    fun reopeningAfterAnUnrestoredRunStartsAtThePicker() {
        val reopened = picked(HEALTH).started().finished(HEALTH, DONE).closed().opened()
        assertEquals(ReturningPhase.SELECTING, reopened.phase)
        assertTrue(reopened.steps.isEmpty())
        assertEquals(setOf(HEALTH), reopened.selected)
    }

    @Test
    fun retryWithoutARestoreReturnsToThePicker() {
        val retried = picked(DRIVE).started().finished(DRIVE, FAILED, ReturningMessage.NO_BACKUP).retried()
        assertEquals(ReturningPhase.SELECTING, retried.phase)
        assertEquals(setOf(DRIVE), retried.selected)
        assertTrue(retried.steps.isEmpty())
    }

    @Test
    fun retryAfterARestoreOnlyRunsTheHealthImportAgain() {
        val finished = picked(DRIVE, HEALTH).started()
            .copy(restoredBackup = true, restoredSetup = true)
            .finished(DRIVE, DONE)
            .finished(HEALTH, FAILED, ReturningMessage.HEALTH_DENIED)
        val retried = finished.retried()
        assertEquals(ReturningPhase.RUNNING, retried.phase)
        assertEquals(listOf(DRIVE to DONE, HEALTH to WORKING), retried.statuses())
        assertTrue(retried.healthPermissionRequested)
        assertNull(retried.step(HEALTH)!!.message)
    }

    // -- Messages and summaries ----------------------------------------------------------

    @Test
    fun driveFailuresMapToTheirOwnMessages() {
        assertEquals(ReturningMessage.NO_BACKUP, returningDriveMessage(CloudBackupNotFoundException()))
        assertEquals(ReturningMessage.SIGN_IN_FAILED, returningDriveMessage(CloudBackupSignInRequiredException()))
        assertEquals(ReturningMessage.NO_SPACE, returningDriveMessage(CloudBackupNoSpaceException()))
        assertEquals(ReturningMessage.NEEDS_NEWER_APP, returningDriveMessage(CloudBackupFormatException(needsNewerApp = true)))
        assertEquals(ReturningMessage.NOT_A_BACKUP, returningDriveMessage(CloudBackupFormatException(needsNewerApp = false)))
    }

    @Test
    fun networkAndHttpFailuresReadAsDriveUnreachable() {
        assertEquals(ReturningMessage.DRIVE_UNREACHABLE, returningDriveMessage(IOException("timeout")))
        assertEquals(ReturningMessage.DRIVE_UNREACHABLE, returningDriveMessage(IllegalStateException("Drive list failed (401)")))
        assertEquals(ReturningMessage.DRIVE_UNREACHABLE, returningDriveMessage(OutOfMemoryError()))
    }

    @Test
    fun healthSummaryNamesWhatCameBack() {
        assertEquals(HealthImportSummary.MEALS_AND_WEIGH_INS, healthImportSummary(HealthRecordCounts(120, 45, 3)))
        assertEquals(HealthImportSummary.MEALS, healthImportSummary(HealthRecordCounts(1, 0, 0)))
        assertEquals(HealthImportSummary.WEIGH_INS, healthImportSummary(HealthRecordCounts(0, 2, 9)))
        assertEquals(HealthImportSummary.OTHER_DATA, healthImportSummary(HealthRecordCounts(0, 0, 4)))
        assertEquals(HealthImportSummary.NOTHING, healthImportSummary(HealthRecordCounts()))
    }

    @Test
    fun afterARestoreTheSummaryCountsOnlyWhatWasAdded() {
        val restored = HealthRecordCounts(meals = 300, weighIns = 80, other = 12)
        val afterImport = HealthRecordCounts(meals = 312, weighIns = 80, other = 12)
        assertEquals(HealthRecordCounts(meals = 12), afterImport - restored)
        // A store can only grow here, but a negative difference must never show.
        assertEquals(HealthRecordCounts(), HealthRecordCounts(1, 1, 1) - HealthRecordCounts(2, 2, 2))
    }

    // -- Pre-fill ------------------------------------------------------------------------

    @Test
    fun weightPrefillRoundsToTheWheelAndStaysInsideIt() {
        assertEquals(72.3, onboardingWeightFromReading(72.34, weightMetric = true)!!, 1e-9)
        assertEquals(72.4, onboardingWeightFromReading(72.36, weightMetric = true)!!, 1e-9)
        assertEquals(30.0, onboardingWeightFromReading(12.0, weightMetric = true)!!, 1e-9)
        assertEquals(250.0, onboardingWeightFromReading(300.0, weightMetric = true)!!, 1e-9)
    }

    @Test
    fun weightPrefillUsesThePoundWheelRangeForImperial() {
        // 60–500 lb.
        assertEquals(60.0, onboardingWeightFromReading(20.0, weightMetric = false)!! * 2.20462, 1e-6)
        assertEquals(500.0, onboardingWeightFromReading(300.0, weightMetric = false)!! * 2.20462, 1e-6)
        assertEquals(80.0, onboardingWeightFromReading(80.0, weightMetric = false)!!, 1e-9)
    }

    @Test
    fun impossibleWeightsAreIgnored() {
        assertNull(onboardingWeightFromReading(0.0, weightMetric = true))
        assertNull(onboardingWeightFromReading(-5.0, weightMetric = false))
        assertNull(onboardingWeightFromReading(Double.NaN, weightMetric = true))
        assertNull(onboardingWeightFromReading(Double.POSITIVE_INFINITY, weightMetric = true))
    }

    @Test
    fun bodyFatPrefillSnapsToHalfPercentSteps() {
        assertEquals(0.235, onboardingBodyFatFromReading(0.2337)!!, 1e-9)
        assertEquals(0.18, onboardingBodyFatFromReading(0.1812)!!, 1e-9)
        // The wheel holds 3–60 %.
        assertEquals(0.03, onboardingBodyFatFromReading(0.012)!!, 1e-9)
        assertEquals(0.60, onboardingBodyFatFromReading(0.75)!!, 1e-9)
    }

    @Test
    fun bodyFatOutsideZeroToHundredPercentIsIgnored() {
        assertNull(onboardingBodyFatFromReading(0.0))
        assertNull(onboardingBodyFatFromReading(23.5)) // a percentage, not a fraction
        assertNull(onboardingBodyFatFromReading(Double.NaN))
    }
}
