package com.apoorvdarshan.calorietracker.backup

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.RandomAccessFile
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream
import kotlin.random.Random

class CloudBackupRestoreTest {
    @get:Rule
    val temp = TemporaryFolder()

    @Test
    fun leavingTheScreenWhileStagingStillRestoresTheValues() = runBlocking {
        val archive = archiveWith("a.jpg" to byteArrayOf(1, 2), "b.jpg" to byteArrayOf(3))
        val staging = CountDownLatch(1)
        val cancelled = CountDownLatch(1)
        val store = FakePhotoStore(onStage = {
            staging.countDown()
            cancelled.await(5, TimeUnit.SECONDS)
        })
        val committed = CompletableDeferred<CloudBackupDocument>()
        val restore = launch(Dispatchers.IO) {
            CloudBackupRestore.apply(archive, store) { document ->
                // Like a DataStore edit: suspends, so it throws if the caller was cancelled.
                withContext(Dispatchers.Default) { committed.complete(document) }
            }
        }
        assertTrue(staging.await(5, TimeUnit.SECONDS))
        restore.cancel()
        cancelled.countDown()
        restore.join()

        assertTrue(committed.isCompleted)
        assertEquals(true, committed.await().payload.values.getValue("useMetric").b)
        assertEquals(listOf("a.jpg", "b.jpg"), store.current.keys.toList())
    }

    @Test
    fun cancellingBeforeStagingLeavesTheDeviceUntouched() = runBlocking {
        val archive = archiveWith("a.jpg" to byteArrayOf(1))
        val store = FakePhotoStore()
        var committed = false
        val restore = launch(Dispatchers.IO) {
            cancel()
            CloudBackupRestore.apply(archive, store) { committed = true }
        }
        restore.join()

        assertTrue(restore.isCancelled)
        assertTrue(store.events.isEmpty())
        assertTrue(store.current.isEmpty())
        assertFalse(committed)
    }

    @Test
    fun corruptArchiveFailsBeforeAnythingIsStaged() = runBlocking {
        val corrupt = temp.newFile("corrupt.zip").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        val store = FakePhotoStore()
        val error = runCatching { CloudBackupRestore.apply(corrupt, store) { } }.exceptionOrNull()

        assertTrue(error != null)
        assertTrue(store.events.isEmpty())
    }

    @Test
    fun notEnoughStorageFailsBeforeAnythingIsStaged() = runBlocking {
        val photo = ByteArray(4096) { it.toByte() }
        val archive = archiveWith("a.jpg" to photo)
        val needed = CloudBackupRestore.requiredBytes(CloudBackupArchive.inspect(archive))
        val store = FakePhotoStore(freeBytes = needed - 1)
        var committed = false
        val error = runCatching {
            CloudBackupRestore.apply(archive, store) { committed = true }
        }.exceptionOrNull()

        assertTrue(error is CloudBackupNoSpaceException)
        assertTrue(store.events.isEmpty())
        assertFalse(committed)
    }

    @Test
    fun exactlyEnoughStorageRestores() = runBlocking {
        val archive = archiveWith("a.jpg" to ByteArray(4096))
        val needed = CloudBackupRestore.requiredBytes(CloudBackupArchive.inspect(archive))
        val store = FakePhotoStore(freeBytes = needed)
        var committed = false
        CloudBackupRestore.apply(archive, store) { committed = true }

        assertTrue(committed)
        assertEquals(listOf("a.jpg"), store.current.keys.toList())
    }

    @Test
    fun photosMoveInOnlyAfterEveryPhotoIsStaged() = runBlocking {
        val archive = archiveWith("a.jpg" to byteArrayOf(1), "b.jpg" to byteArrayOf(2))
        val store = FakePhotoStore()
        CloudBackupRestore.apply(archive, store) { store.events += "commit" }

        // Deletions stay paused from moving photos in until the values are written.
        assertEquals(
            listOf("start", "stage a.jpg", "stage b.jpg", "begin", "move in", "commit", "end", "discard"),
            store.events,
        )
    }

    @Test
    fun aPhotoThatFailsToStageLeavesThePhotosAndValuesUntouched() = runBlocking {
        val archive = archiveWith("a.jpg" to byteArrayOf(1), "b.jpg" to byteArrayOf(2), "c.jpg" to byteArrayOf(3))
        val store = FakePhotoStore(failing = setOf("b.jpg"))
        store.current["old.jpg"] = byteArrayOf(9)
        var committed = false
        val error = runCatching {
            CloudBackupRestore.apply(archive, store) { committed = true }
        }.exceptionOrNull()

        assertTrue(error is CloudBackupPhotoWriteException)
        assertFalse(committed)
        assertEquals(listOf("old.jpg"), store.current.keys.toList())
        assertFalse("move in" in store.events)
        assertEquals("discard", store.events.last())
    }

    @Test
    fun anArchiveReadFailureWhileStagingLeavesThePhotosAndValuesUntouched() = runBlocking {
        // Random bytes do not compress, so every photo takes its full size in the
        // archive and the reader cannot have buffered the later ones already.
        val random = Random(484)
        val archive = archiveWith(
            "a.jpg" to random.nextBytes(64 * 1024),
            "b.jpg" to random.nextBytes(64 * 1024),
            "c.jpg" to random.nextBytes(64 * 1024),
        )
        val store = FakePhotoStore(onStage = { name ->
            // The archive passed validation, then stops being readable partway.
            if (name == "a.jpg") RandomAccessFile(archive, "rw").use { it.setLength(it.length() / 2) }
        })
        store.current["old.jpg"] = byteArrayOf(9)
        var committed = false
        val error = runCatching {
            CloudBackupRestore.apply(archive, store) { committed = true }
        }.exceptionOrNull()

        assertTrue(error is IOException)
        assertFalse(committed)
        assertEquals(listOf("old.jpg"), store.current.keys.toList())
        assertFalse("begin" in store.events)
        assertFalse("move in" in store.events)
        assertEquals("discard", store.events.last())
    }

    @Test
    fun aPhotoThatCannotBeMovedInLeavesTheValuesUnrestored() = runBlocking {
        val archive = archiveWith("a.jpg" to byteArrayOf(1))
        val store = FakePhotoStore(failMoveIn = true)
        var committed = false
        val error = runCatching {
            CloudBackupRestore.apply(archive, store) { committed = true }
        }.exceptionOrNull()

        assertTrue(error is CloudBackupPhotoWriteException)
        assertFalse(committed)
        assertEquals(listOf("end", "discard"), store.events.takeLast(2))
    }

    @Test
    fun aFailedCommitStillResumesDeletionsAndDiscardsStaging() = runBlocking {
        val archive = archiveWith("a.jpg" to byteArrayOf(1))
        val store = FakePhotoStore()
        val error = runCatching {
            CloudBackupRestore.apply(archive, store) { error("DataStore write failed") }
        }.exceptionOrNull()

        assertTrue(error is IllegalStateException)
        assertEquals(listOf("end", "discard"), store.events.takeLast(2))
    }

    @Test
    fun entriesOutsideThePhotoFolderNeverReachTheStore() = runBlocking {
        val packed = archiveWith()
        val payload = ZipInputStream(packed.inputStream()).use { zip ->
            zip.nextEntry
            zip.readBytes()
        }
        val crafted = temp.newFile("crafted.zip")
        ZipOutputStream(crafted.outputStream()).use { zip ->
            zip.putNextEntry(ZipEntry(CloudBackupPolicy.PAYLOAD_NAME))
            zip.write(payload)
            zip.closeEntry()
            for (name in listOf("photos/../../evil.jpg", "photos/sub/evil.jpg", "/photos/evil.jpg", "photos/ok.jpg")) {
                zip.putNextEntry(ZipEntry(name))
                zip.write(byteArrayOf(7))
                zip.closeEntry()
            }
        }
        val store = FakePhotoStore()
        CloudBackupRestore.apply(crafted, store) { }

        assertEquals(listOf("ok.jpg"), store.stagedNames)
        assertEquals(listOf("ok.jpg"), store.current.keys.toList())
    }

    private fun archiveWith(vararg photos: Pair<String, ByteArray>): File {
        val zip = temp.newFile()
        CloudBackupArchive.pack(
            destination = zip,
            values = mapOf("useMetric" to CloudBackupValue.bool(true)),
            photos = photos.map { (name, bytes) ->
                CloudBackupPhoto(name, bytes.size.toLong()) { ByteArrayInputStream(bytes) }
            },
            exportedAt = "2026-10-17T00:00:00Z",
            appVersion = "test",
        )
        return zip
    }

    /** Keeps the current photos and the staging area in memory, logging each step. */
    private class FakePhotoStore(
        private val freeBytes: Long = Long.MAX_VALUE,
        private val failing: Set<String> = emptySet(),
        private val failMoveIn: Boolean = false,
        private val onStage: (String) -> Unit = {},
    ) : CloudBackupPhotoStore {
        val current = linkedMapOf<String, ByteArray>()
        val stagedNames = mutableListOf<String>()
        private val staged = linkedMapOf<String, ByteArray>()
        val events = mutableListOf<String>()

        override fun bytesFree(): Long = freeBytes

        override fun startStaging() {
            staged.clear()
            events += "start"
        }

        override fun stagePhoto(filename: String, input: InputStream): Boolean {
            onStage(filename)
            events += "stage $filename"
            stagedNames += filename
            if (filename in failing) return false
            staged[filename] = input.readBytes()
            return true
        }

        override fun commitStaged() {
            events += "move in"
            if (failMoveIn) throw CloudBackupPhotoWriteException()
            current.putAll(staged)
        }

        override fun discardStaged() {
            staged.clear()
            events += "discard"
        }

        override fun beginRestore() {
            events += "begin"
        }

        override fun endRestore() {
            events += "end"
        }
    }
}
