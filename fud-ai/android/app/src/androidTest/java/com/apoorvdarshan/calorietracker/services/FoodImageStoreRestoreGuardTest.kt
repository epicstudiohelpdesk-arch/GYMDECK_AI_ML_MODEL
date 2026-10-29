package com.apoorvdarshan.calorietracker.services

import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.File
import java.util.UUID

/**
 * Moving staged photos in and deleting both evict thumbnails from the LruCache,
 * so this half of the restore tests runs on a device.
 */
class FoodImageStoreRestoreGuardTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    @Test fun deletionsResumeOnceTheRestoreEnds() = withStore { store, _ ->
        store.startStaging()
        assertTrue(store.stagePhoto("kept.jpg", ByteArrayInputStream(byteArrayOf(1))))
        assertTrue(store.stagePhoto("orphan.jpg", ByteArrayInputStream(byteArrayOf(2))))
        store.beginRestore()
        store.commitStaged()
        store.endRestore()
        store.discardStaged()

        // References read after the restore committed describe the restored photos.
        store.pruneUnreferenced(setOf("kept.jpg"), store.restoreGeneration())
        assertTrue(store.file("kept.jpg").exists())
        assertFalse(store.file("orphan.jpg").exists())

        store.delete("kept.jpg")
        assertFalse(store.file("kept.jpg").exists())
    }

    @Test fun movingStagedPhotosInReplacesSameNamesAndLeavesTheRestForThePrune() = withStore { store, root ->
        store.file("same.jpg").writeBytes(byteArrayOf(1))
        store.file("other.jpg").writeBytes(byteArrayOf(2))
        val oldThumbnail = File(root, "fudai-food-thumbnails-v2/same.jpg").apply { writeBytes(byteArrayOf(3)) }

        store.startStaging()
        assertTrue(store.stagePhoto("same.jpg", ByteArrayInputStream(byteArrayOf(4, 4))))
        assertTrue(store.stagePhoto("new.jpg", ByteArrayInputStream(byteArrayOf(5))))
        store.beginRestore()
        store.commitStaged()
        store.endRestore()
        store.discardStaged()

        assertArrayEquals(byteArrayOf(4, 4), store.file("same.jpg").readBytes())
        assertArrayEquals(byteArrayOf(5), store.file("new.jpg").readBytes())
        // Photos the backup lacks stay until the reference-checked prune.
        assertTrue(store.file("other.jpg").exists())
        // The replaced photo's thumbnail is gone, so it is rebuilt from the new photo.
        assertFalse(oldThumbnail.exists())
        assertFalse(store.stagedFile("same.jpg").exists())
    }

    private fun withStore(body: (FoodImageStore, File) -> Unit) {
        val root = File(context.cacheDir, "restore-guard-${UUID.randomUUID()}")
        try {
            body(FoodImageStore.forTests(root), root)
        } finally {
            root.deleteRecursively()
        }
    }
}
