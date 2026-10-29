package com.apoorvdarshan.calorietracker.services

import kotlinx.coroutines.Dispatchers
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.UUID

/**
 * File-level guarantees of Settings › Storage. Real pixel downscaling is covered by the
 * instrumented FoodImageDecoderTest; here nothing decodes, so every photo is "unreadable".
 */
class StorageMaintenanceTest {
    private lateinit var root: File
    private lateinit var photos: FoodImageStore
    private val photoDir get() = File(root, "fudai-food-images")
    private val thumbnailDir get() = File(root, "fudai-food-thumbnails-v2")

    @Before
    fun setUp() {
        root = Files.createTempDirectory("fud-storage").toFile()
        photos = FoodImageStore.forTests(root)
    }

    @After
    fun tearDown() {
        root.deleteRecursively()
    }

    private fun maintenance(
        frameBytes: () -> Long = { 0L },
        onClearFrames: () -> Unit = {},
        modelBytes: Long = 0L,
        compress: ((onProgress: (Int, Int) -> Unit) -> FoodImageStore.PhotoCompressionResult)? = null
    ) = StorageMaintenance(
        photos = photos,
        workoutFrameCacheBytes = frameBytes,
        clearWorkoutFrameCache = onClearFrames,
        modelBytes = { modelBytes },
        dispatcher = Dispatchers.Unconfined,
        compressExistingPhotos = compress ?: photos::compressExistingPhotos
    )

    @Test
    fun usageSeparatesPhotosRegenerableCacheAndModels() {
        File(photoDir, "a.jpg").writeBytes(ByteArray(300))
        File(photoDir, "b.jpg").writeBytes(ByteArray(200))
        File(thumbnailDir, "a.jpg").writeBytes(ByteArray(40))

        assertEquals(FoodImageStore.PhotoStorageUsage(photoCount = 2, photoBytes = 500, thumbnailBytes = 40), photos.storageUsage())

        var frameMeasurements = 0
        val storage = maintenance(frameBytes = { frameMeasurements++; 1_000 }, modelBytes = 5_000)
        storage.refresh()

        assertEquals(StorageMaintenance.Usage(photoBytes = 500, cacheBytes = 1_040, modelBytes = 5_000), storage.ui.value.usage)
        // The disk walk runs once, before the state update rather than inside it.
        assertEquals(1, frameMeasurements)
    }

    @Test
    fun clearCacheDeletesThumbnailsAndFramesButNeverPhotos() {
        val photoBytes = ByteArray(64) { it.toByte() }
        File(photoDir, "meal.jpg").writeBytes(photoBytes)
        File(thumbnailDir, "meal.jpg").writeBytes(ByteArray(8))
        var framesCleared = false

        val storage = maintenance(onClearFrames = { framesCleared = true })
        storage.clearCache()

        assertArrayEquals(photoBytes, File(photoDir, "meal.jpg").readBytes())
        assertFalse(File(thumbnailDir, "meal.jpg").exists())
        assertTrue(framesCleared)
        assertFalse(storage.ui.value.busy)
        assertEquals(0L, storage.ui.value.usage?.cacheBytes)
    }

    @Test
    fun compressionLeavesUndecodablePhotosByteIdenticalAndCleansUp() {
        val original = "not an image".toByteArray()
        File(photoDir, "broken.jpg").writeBytes(original)

        val storage = maintenance()
        storage.compressPhotos()

        val result = storage.ui.value.compressionResult
        assertEquals(FoodImageStore.PhotoCompressionResult(compressedCount = 0, unreadableCount = 1, bytesSaved = 0), result)
        assertArrayEquals(original, File(photoDir, "broken.jpg").readBytes())
        assertEquals(listOf("broken.jpg"), photoDir.list()!!.toList())
        assertFalse(File(root, "fudai-food-images-compressing").exists())
        assertFalse(storage.ui.value.compressing)

        storage.dismissCompressionResult()
        assertEquals(null, storage.ui.value.compressionResult)
    }

    @Test
    fun compressionReplacesNothingWhileARestoreIsStagingOrMovingPhotosIn() {
        val original = "not an image".toByteArray()
        File(photoDir, "meal.jpg").writeBytes(original)

        photos.startStaging()
        // Skipped before it is even decoded, and reported so the user can run it again.
        assertEquals(
            FoodImageStore.PhotoCompressionResult(compressedCount = 0, unreadableCount = 0, bytesSaved = 0, failedCount = 1),
            photos.compressExistingPhotos()
        )
        assertArrayEquals(original, File(photoDir, "meal.jpg").readBytes())
        photos.discardStaged()

        // Once the restore ends the photo is examined again (here it does not decode).
        assertEquals(
            FoodImageStore.PhotoCompressionResult(compressedCount = 0, unreadableCount = 1, bytesSaved = 0),
            photos.compressExistingPhotos()
        )
        assertArrayEquals(original, File(photoDir, "meal.jpg").readBytes())
    }

    @Test
    fun compressionOnlyExaminesPlainPhotoNamesDirectlyInsideThePhotoFolder() {
        val bytes = "not an image".toByteArray()
        File(photoDir, "meal.jpg").writeBytes(bytes)
        File(photoDir, ".hidden.jpg").writeBytes(bytes)
        File(photoDir, "notes.txt").writeBytes(bytes)
        File(photoDir, "nested").mkdirs()
        File(photoDir, "nested/inner.jpg").writeBytes(bytes)
        val outside = File(root, "outside.jpg").apply { writeBytes(bytes) }
        Files.createSymbolicLink(File(photoDir, "link.jpg").toPath(), outside.toPath())
        val progress = mutableListOf<Pair<Int, Int>>()

        val result = photos.compressExistingPhotos { done, total -> progress += done to total }

        assertEquals(listOf(1 to 1), progress)
        assertEquals(1, result.unreadableCount)
        for (file in listOf("meal.jpg", ".hidden.jpg", "notes.txt", "nested/inner.jpg")) {
            assertArrayEquals(file, bytes, File(photoDir, file).readBytes())
        }
        assertArrayEquals(bytes, outside.readBytes())
    }

    @Test
    fun anInterruptedCompressionIsReportedAsFailedNotAsNothingToDo() {
        val storage = maintenance(compress = { onProgress ->
            onProgress(1, 3)
            throw IOException("No space left on device")
        })
        storage.compressPhotos()

        val state = storage.ui.value
        assertEquals(
            FoodImageStore.PhotoCompressionResult(compressedCount = 0, unreadableCount = 0, bytesSaved = 0, failedCount = 2),
            state.compressionResult
        )
        assertFalse(state.compressing)
        assertTrue(state.usage != null)
    }

    @Test
    fun aDownscaledCopyIsKeptOnlyWhenItIsSmaller() {
        val original = ByteArray(100) { 1 }
        val smaller = ByteArray(60) { 2 }

        assertArrayEquals(smaller, FoodImageStore.smallerOrOriginal(original, smaller))
        assertArrayEquals(original, FoodImageStore.smallerOrOriginal(original, ByteArray(100) { 3 }))
        assertArrayEquals(original, FoodImageStore.smallerOrOriginal(original, ByteArray(140) { 3 }))
        assertArrayEquals(original, FoodImageStore.smallerOrOriginal(original, null))
    }

    @Test
    fun storeAndRestoreKeepBytesThatAreNotOversizedPhotos() {
        val bytes = "small or unreadable".toByteArray()

        val stored = photos.storeBytes(bytes, UUID.randomUUID())!!
        assertTrue(photos.restoreBytes("restored.jpg", bytes))

        assertArrayEquals(bytes, photos.loadBytes(stored))
        assertArrayEquals(bytes, photos.loadBytes("restored.jpg"))
    }
}
