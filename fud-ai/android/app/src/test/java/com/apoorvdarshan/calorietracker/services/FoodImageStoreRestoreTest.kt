package com.apoorvdarshan.calorietracker.services

import org.junit.Assert.assertArrayEquals
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
import java.nio.file.Files

/**
 * JVM tests for the restore paths that never touch the thumbnail LruCache, which
 * is not available off-device; FoodImageStoreRestoreGuardTest covers the rest.
 */
class FoodImageStoreRestoreTest {
    @get:Rule
    val temp = TemporaryFolder()

    @Test
    fun stagedPhotoIsWrittenInFullAndLeavesCurrentPhotosAlone() {
        val store = FoodImageStore.forTests(temp.newFolder("files"))
        store.file("current.jpg").writeBytes(byteArrayOf(9))
        val bytes = ByteArray(20_000) { it.toByte() }

        store.startStaging()
        assertTrue(store.stagePhoto("a.jpg", ByteArrayInputStream(bytes)))

        assertArrayEquals(bytes, store.stagedFile("a.jpg").readBytes())
        assertEquals(listOf("current.jpg"), store.listedFilenames())
        store.discardStaged()
        assertFalse(store.stagedFile("a.jpg").exists())
    }

    @Test
    fun aFailedStageWriteLeavesNoCutOffPhoto() {
        val store = FoodImageStore.forTests(temp.newFolder("files"))
        store.startStaging()

        assertFalse(store.stagePhoto("a.jpg", FullDiskStream(after = 10_000)))
        assertFalse(store.stagedFile("a.jpg").exists())
        assertTrue(store.stagedFile("a.jpg").parentFile!!.listFiles()!!.isEmpty())
    }

    @Test
    fun stagingRefusesNamesThatLeaveTheStagingFolder() {
        val root = temp.newFolder("app")
        val files = File(root, "files")
        val store = FoodImageStore.forTests(files)
        store.startStaging()
        val stagingDir = store.stagedFile("x.jpg").parentFile!!

        for (name in listOf(
            "../escape.jpg", "../../escape.jpg", "../fudai-food-images/escape.jpg", "sub/escape.jpg",
            "${root.absolutePath}/escape.jpg", "..\\escape.jpg", ".escape.jpg", "escape.txt", "",
        )) {
            assertFalse(name, store.stagePhoto(name, ByteArrayInputStream(byteArrayOf(1))))
        }

        val written = root.walkTopDown().filter { it.isFile }.toList()
        assertTrue(written.toString(), written.isEmpty())
        assertTrue(stagingDir.listFiles()!!.isEmpty())
    }

    @Test
    fun stagingRefusesANameThatIsASymbolicLinkOutOfTheFolder() {
        val root = temp.newFolder("app")
        val store = FoodImageStore.forTests(File(root, "files"))
        val outside = File(root, "outside.jpg").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        store.startStaging()
        Files.createSymbolicLink(store.stagedFile("link.jpg").toPath(), outside.toPath())

        assertFalse(store.stagePhoto("link.jpg", ByteArrayInputStream(byteArrayOf(9, 9))))
        assertArrayEquals(byteArrayOf(1, 2, 3), outside.readBytes())
    }

    @Test
    fun startingStagingClearsWhatAnInterruptedRestoreLeft() {
        val store = FoodImageStore.forTests(temp.newFolder("files"))
        store.startStaging()
        assertTrue(store.stagePhoto("left.jpg", ByteArrayInputStream(byteArrayOf(1))))

        // The process dies here; the next restore starts over.
        store.startStaging()
        assertFalse(store.stagedFile("left.jpg").exists())
        store.discardStaged()
    }

    @Test
    fun startupCleanupKeepsARunningRestoreAndRemovesAnAbandonedOne() {
        val files = temp.newFolder("files")
        val store = FoodImageStore.forTests(files)
        store.startStaging()
        assertTrue(store.stagePhoto("running.jpg", ByteArrayInputStream(byteArrayOf(1))))
        store.discardAbandonedStaging()
        assertTrue(store.stagedFile("running.jpg").exists())
        store.discardStaged()

        // A restore in a process that was killed left its staging behind.
        val killed = FoodImageStore.forTests(files)
        killed.startStaging()
        assertTrue(killed.stagePhoto("abandoned.jpg", ByteArrayInputStream(byteArrayOf(1))))
        val nextLaunch = FoodImageStore.forTests(files)
        nextLaunch.discardAbandonedStaging()
        assertFalse(nextLaunch.stagedFile("abandoned.jpg").exists())
    }

    @Test
    fun pruneWithReferencesReadBeforeARestoreKeepsTheRestoredPhotos() {
        val store = FoodImageStore.forTests(temp.newFolder("files"))
        // A diary edit reads the generation and the old diary's references...
        val generation = store.restoreGeneration()
        val oldReferences = setOf("old.jpg")
        // ...a restore then moves its photos in and commits the new diary...
        store.beginRestore()
        store.file("restored.jpg").writeBytes(byteArrayOf(1))
        store.endRestore()
        // ...and only afterwards does the edit prune.
        store.pruneUnreferenced(oldReferences, generation)

        assertTrue(store.file("restored.jpg").exists())
    }

    @Test
    fun pruneAndDeleteAreSkippedWhileARestoreRuns() {
        val store = FoodImageStore.forTests(temp.newFolder("files"))
        store.beginRestore()
        store.file("restored.jpg").writeBytes(byteArrayOf(1))

        store.pruneUnreferenced(setOf("old.jpg"))
        store.delete("restored.jpg")

        assertTrue(store.file("restored.jpg").exists())
        store.endRestore()
    }

    /** Hands out [after] bytes, then fails, so the copy stops partway as it does on a full disk. */
    private class FullDiskStream(private val after: Int) : InputStream() {
        private var sent = 0

        override fun read(): Int {
            if (sent >= after) throw IOException("No space left on device")
            sent++
            return 1
        }
    }
}
