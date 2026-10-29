package com.apoorvdarshan.calorietracker.backup

import org.junit.Assert.assertEquals
import org.junit.Test

class CloudBackupErrorMessageTest {
    private val fallback = "Something went wrong"
    private val noSpace = "Not enough free storage"

    @Test
    fun outOfMemoryShowsTheFallbackInsteadOfRawVmText() {
        val oom = OutOfMemoryError(
            "Failed to allocate a 1108648 byte allocation with 135584 free bytes and 132KB until OOM"
        )
        assertEquals(fallback, cloudBackupErrorMessage(oom, fallback, noSpace))
    }

    @Test
    fun missingOrBlankMessagesShowTheFallback() {
        assertEquals(fallback, cloudBackupErrorMessage(IllegalStateException(), fallback, noSpace))
        assertEquals(fallback, cloudBackupErrorMessage(IllegalStateException(" "), fallback, noSpace))
    }

    @Test
    fun backupErrorsKeepTheirOwnMessage() {
        assertEquals(
            "Drive upload failed (403)",
            cloudBackupErrorMessage(IllegalStateException("Drive upload failed (403)"), fallback, noSpace),
        )
    }

    @Test
    fun aRestoreWithoutEnoughStorageSaysSo() {
        assertEquals(noSpace, cloudBackupErrorMessage(CloudBackupNoSpaceException(), fallback, noSpace))
    }

    @Test
    fun aPhotoWriteFailureShowsTheFallback() {
        assertEquals(fallback, cloudBackupErrorMessage(CloudBackupPhotoWriteException(), fallback, noSpace))
    }
}
