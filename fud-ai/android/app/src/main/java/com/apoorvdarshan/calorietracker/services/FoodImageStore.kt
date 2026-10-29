package com.apoorvdarshan.calorietracker.services

import android.app.ActivityManager
import android.content.Context
import android.graphics.Bitmap
import android.util.LruCache
import androidx.annotation.VisibleForTesting
import com.apoorvdarshan.calorietracker.backup.CloudBackupPhotoStore
import com.apoorvdarshan.calorietracker.backup.CloudBackupPhotoWriteException
import com.apoorvdarshan.calorietracker.backup.CloudBackupPolicy
import com.apoorvdarshan.calorietracker.models.UserExercise
import com.apoorvdarshan.calorietracker.services.FoodImageDecoder.scaledToMaxDimension
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write
import kotlin.math.max

/**
 * Local food-photo cache. Port of iOS FoodImageStore.
 * JPEGs live under filesDir/fudai-food-images/{uuid}.jpg so they stay out of
 * the DataStore blob (which would otherwise inflate past quick-read limits).
 */
class FoodImageStore private constructor(
    private val filesRoot: File,
    cleanupLegacyThumbnails: Boolean,
    thumbnailCacheKb: Int
) : CloudBackupPhotoStore {
    private val dir: File = File(filesRoot, DIR_NAME).apply { mkdirs() }
    private val thumbnailDir: File = File(filesRoot, THUMBNAIL_DIR_NAME).apply { mkdirs() }
    private val thumbnailCache = object : LruCache<String, Bitmap>(thumbnailCacheKb) {
        override fun sizeOf(key: String, value: Bitmap): Int = value.byteCount / 1024
    }
    private val thumbnailLocks = ConcurrentHashMap<String, Any>()

    // A Drive restore writes its photos here first and moves them into [dir]
    // only once every one of them has been read and written (#484).
    private val stagingDir: File = File(filesRoot, STAGING_DIR_NAME)
    private val stagingThumbnailDir: File = File(filesRoot, STAGING_THUMBNAIL_DIR_NAME)
    private val stagingLock = Any()
    private var stagingActive = false

    // True from startStaging to discardStaged. Guarded by photoFileLock, so
    // Compress Photos checks it in the same step as its swap and never
    // replaces a photo while a restore is staging or moving photos in.
    private var restoreWritingPhotos = false

    // A Drive restore replaces the photos while the app stays usable (#484).
    // Deletions decided from the diary as it was before the restore would
    // remove restored photos, so they are skipped until it commits; the
    // reference-checked prune collects anything left behind. Written under
    // the write lock.
    private val restoreLock = ReentrantReadWriteLock()
    private var restoresRunning = 0
    private var generation = 0L

    constructor(context: Context) : this(
        filesRoot = context.filesDir,
        cleanupLegacyThumbnails = true,
        thumbnailCacheKb = thumbnailCacheKbFor(context)
    )

    /** One-time cleanup of the pre-v2 thumbnail cache directory. Safe to call repeatedly. */
    fun cleanupLegacyThumbnailDirectory() {
        // Legacy thumbnails lost EXIF orientation during compression. Rebuild them
        // lazily in the new cache directory; original photos remain byte-identical.
        runCatching { File(filesRoot, LEGACY_THUMBNAIL_DIR_NAME).deleteRecursively() }
    }

    /** Writes the bitmap as JPEG (quality 80) under a new filename. Returns filename or null. */
    fun store(bitmap: Bitmap, entryId: UUID): String? = runCatching {
        val filename = "${entryId}.jpg"
        synchronized(photoFileLock) {
            FileOutputStream(File(dir, filename)).use { out ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 80, out)
            }
        }
        runCatching { writeThumbnail(filename, bitmap) }
        filename
    }.getOrNull()

    /**
     * Writes a newly captured photo. Photos whose longest side exceeds [STORED_MAX_DIMENSION]
     * are stored as an upright JPEG at that size (the viewer never decodes more) when that copy
     * is smaller; smaller, undecodable or already well-compressed images keep their original
     * bytes. Pass [writeThumbnail] = false on latency-sensitive paths; [loadThumbnail] /
     * [warmThumbnails] generate it lazily on first use.
     */
    fun storeBytes(bytes: ByteArray, entryId: UUID, writeThumbnail: Boolean = true): String? = runCatching {
        val filename = "${entryId}.jpg"
        val stored = smallerOrOriginal(bytes, downscaledForStorage(bytes))
        synchronized(photoFileLock) { File(dir, filename).writeBytes(stored) }
        if (writeThumbnail) runCatching {
            FoodImageDecoder.decode(stored, THUMBNAIL_MAX_DIMENSION)?.let { writeThumbnail(filename, it) }
        }
        filename
    }.getOrNull()

    fun load(filename: String): Bitmap? =
        runCatching { FoodImageDecoder.decode(File(dir, filename)) }.getOrNull()

    /** Bounded decode for full-screen viewer — avoids loading full-resolution on the main thread. */
    fun loadForViewer(filename: String, maxDimension: Int = VIEWER_MAX_DIMENSION): Bitmap? =
        runCatching { FoodImageDecoder.decode(File(dir, filename), maxDimension) }.getOrNull()

    fun loadThumbnail(filename: String, maxDimension: Int = THUMBNAIL_MAX_DIMENSION): Bitmap? {
        val key = "$filename:$maxDimension"
        thumbnailCache.get(key)?.takeUnless { it.isRecycled }?.let { return it }

        synchronized(thumbnailLockFor(filename)) {
            thumbnailCache.get(key)?.takeUnless { it.isRecycled }?.let { return it }

            val thumbFile = File(thumbnailDir, filename)
            val bitmap = when {
                thumbFile.exists() -> runCatching {
                    FoodImageDecoder.decode(thumbFile, maxDimension)
                }.getOrNull()
                else -> runCatching {
                    val fullFile = File(dir, filename)
                    FoodImageDecoder.decode(fullFile, maxDimension)?.also { writeThumbnail(filename, it) }
                }.getOrNull()
            }

            if (bitmap != null) thumbnailCache.put(key, bitmap)
            return bitmap
        }
    }

    /** Prefetch thumbnails into memory/disk cache. Call from a background dispatcher. */
    fun warmThumbnails(filenames: Collection<String>) {
        filenames.asSequence()
            .filter { it.isNotBlank() }
            .distinct()
            .forEach { loadThumbnail(it) }
    }

    fun file(filename: String): File = File(dir, filename)

    fun listedFilenames(): List<String> =
        dir.listFiles()?.filter { it.isFile }?.map { it.name }.orEmpty()

    fun loadBytes(filename: String): ByteArray? {
        val file = File(dir, filename)
        return if (file.isFile) runCatching { file.readBytes() }.getOrNull() else null
    }

    /** Writes backup bytes byte-identical — restores are never re-compressed. */
    fun restoreBytes(filename: String, bytes: ByteArray): Boolean = runCatching {
        synchronized(photoFileLock) { File(dir, filename).writeBytes(bytes) }
        runCatching {
            FoodImageDecoder.decode(bytes, THUMBNAIL_MAX_DIMENSION)?.let { writeThumbnail(filename, it) }
        }
        true
    }.getOrDefault(false)

    override fun bytesFree(): Long = filesRoot.usableSpace

    override fun startStaging() {
        synchronized(stagingLock) {
            stagingActive = true
            synchronized(photoFileLock) { restoreWritingPhotos = true }
            deleteStagingFolders()
            if (!stagingDir.mkdirs() || !stagingThumbnailDir.mkdirs()) throw CloudBackupPhotoWriteException()
        }
    }

    /**
     * Copies a restored photo into the staging folder without holding it in
     * memory. The copy goes to a temp file first, so a failed write (a full
     * disk) leaves no cut-off photo.
     */
    override fun stagePhoto(filename: String, input: InputStream): Boolean {
        val target = childFile(stagingDir, filename) ?: return false
        val temp = File(target.parentFile, "${target.name}.${UUID.randomUUID()}$TEMP_SUFFIX")
        return runCatching {
            FileOutputStream(temp).use { input.copyTo(it) }
            check(temp.renameTo(target)) { "Could not move the staged photo into place" }
            runCatching {
                FoodImageDecoder.decode(target, THUMBNAIL_MAX_DIMENSION)?.let {
                    writeThumbnailFile(it, File(stagingThumbnailDir, target.name))
                }
            }
            true
        }.getOrElse {
            temp.delete()
            false
        }
    }

    override fun commitStaged() {
        val staged = stagingDir.listFiles()
            ?.mapNotNull { file -> CloudBackupPolicy.safePhotoName(file.name)?.takeIf { file.isFile } }
            .orEmpty()
        try {
            for (name in staged) {
                val source = childFile(stagingDir, name) ?: throw CloudBackupPhotoWriteException()
                val target = childFile(dir, name) ?: throw CloudBackupPhotoWriteException()
                // A rename within the app's files folder replaces any photo
                // with the same name in one step. The bytes move as staged,
                // never re-encoded, and under the lock Compress Photos swaps in.
                val moved = synchronized(photoFileLock) { source.renameTo(target) }
                if (!moved) throw CloudBackupPhotoWriteException()
                val thumbnail = File(thumbnailDir, target.name)
                val stagedThumbnail = File(stagingThumbnailDir, target.name)
                // A thumbnail of the photo just replaced must not outlive it.
                if (!stagedThumbnail.isFile || !stagedThumbnail.renameTo(thumbnail)) thumbnail.delete()
            }
        } finally {
            thumbnailCache.evictAll()
        }
    }

    override fun discardStaged() {
        synchronized(stagingLock) {
            deleteStagingFolders()
            stagingActive = false
            synchronized(photoFileLock) { restoreWritingPhotos = false }
        }
    }

    /** Removes staging a restore left behind when the process died; keeps one still running. */
    fun discardAbandonedStaging() {
        synchronized(stagingLock) {
            if (!stagingActive) deleteStagingFolders()
        }
    }

    @VisibleForTesting
    fun stagedFile(filename: String): File = File(stagingDir, filename)

    private fun deleteStagingFolders() {
        stagingDir.deleteRecursively()
        stagingThumbnailDir.deleteRecursively()
    }

    /**
     * [folder]/[filename] when [filename] is a plain photo name whose canonical
     * path is a direct child of [folder], else null. Restored names come from a
     * downloaded archive, so this keeps a crafted name, or a symbolic link
     * already at that name, from reaching outside the folder.
     */
    private fun childFile(folder: File, filename: String): File? {
        val name = CloudBackupPolicy.safePhotoName(filename) ?: return null
        return try {
            val root = folder.canonicalFile
            val file = File(root, name).canonicalFile
            if (file.toPath().startsWith(root.toPath()) && file.parentFile == root) file else null
        } catch (_: IOException) {
            null
        }
    }

    /** Stores a custom exercise photo under a fresh filename (never overwrites diary snapshots). */
    fun storeExercisePhoto(bytes: ByteArray): String? = runCatching {
        val filename = UserExercise.newPhotoFilename()
        val bitmap = FoodImageDecoder.decode(bytes, VIEWER_MAX_DIMENSION) ?: return null
        val jpeg = ByteArrayOutputStream().use { out ->
            bitmap.compress(Bitmap.CompressFormat.JPEG, 80, out)
            out.toByteArray()
        }
        bitmap.recycle()
        if (restoreBytes(filename, jpeg)) filename else null
    }.getOrNull()

    override fun beginRestore() {
        restoreLock.write {
            restoresRunning++
            generation++
        }
    }

    override fun endRestore() {
        restoreLock.write {
            restoresRunning--
            generation++
        }
    }

    /** Read before collecting the references passed to [pruneUnreferenced]. */
    fun restoreGeneration(): Long = restoreLock.read { generation }

    /** Skipped while a Drive restore runs; see [beginRestore]. */
    fun delete(filename: String) {
        restoreLock.read {
            if (restoresRunning > 0) return
            deleteFiles(filename)
        }
    }

    private fun deleteFiles(filename: String) {
        synchronized(photoFileLock) { runCatching { File(dir, filename).delete() } }
        runCatching { File(thumbnailDir, filename).delete() }
        evictThumbnails(filename)
    }

    fun clearAll() {
        synchronized(photoFileLock) { dir.listFiles()?.forEach { runCatching { it.delete() } } }
        thumbnailDir.listFiles()?.forEach { runCatching { it.delete() } }
        thumbnailCache.evictAll()
    }

    /** Disk space used by stored photos and by the regenerable thumbnail cache. */
    fun storageUsage(): PhotoStorageUsage {
        val photos = dir.listFiles()?.filter { it.isFile }.orEmpty()
        return PhotoStorageUsage(
            photoCount = photos.size,
            photoBytes = photos.sumOf { it.length() },
            thumbnailBytes = thumbnailDir.listFiles()?.filter { it.isFile }?.sumOf { it.length() } ?: 0L
        )
    }

    /** Deletes cached thumbnails only; [loadThumbnail] rebuilds them from the photos on demand. */
    fun clearThumbnailCache() {
        thumbnailDir.listFiles()?.forEach { runCatching { it.delete() } }
        runCatching { thumbnailCache.evictAll() }
    }

    /**
     * Downscales existing photos larger than [STORED_MAX_DIMENSION], one file at a time so only
     * one bounded bitmap is alive. Each result is staged outside the photo folder and renamed
     * over the original only when it is smaller and the original is unchanged; files that can't
     * be decoded, or whose copy couldn't be written or swapped in, are left as they are and
     * counted. An error on one photo never stops the rest. Thumbnails stay valid because both
     * versions decode upright. Lossy and permanent, so it only ever runs after the user confirms
     * it in Settings.
     *
     * Only plain photo names whose canonical path is a direct child of the photo folder are
     * touched. While a Drive restore is staging or moving photos in, no photo is replaced; the
     * ones the run reaches meanwhile are counted as failed so the user can run it again.
     */
    fun compressExistingPhotos(onProgress: (done: Int, total: Int) -> Unit = { _, _ -> }): PhotoCompressionResult {
        val photos = dir.listFiles()
            ?.mapNotNull { file -> childFile(dir, file.name)?.takeIf { it.isFile } }
            .orEmpty()
        val staging = File(filesRoot, COMPRESSION_STAGING_DIR_NAME)
        staging.deleteRecursively()
        staging.mkdirs()
        var compressed = 0
        var unreadable = 0
        var failed = 0
        var bytesSaved = 0L
        try {
            photos.forEachIndexed { index, photo ->
                val outcome = try {
                    compressStoredPhoto(photo, staging)
                } catch (e: Exception) {
                    CompressionOutcome.Failed
                }
                when (outcome) {
                    is CompressionOutcome.Compressed -> {
                        compressed++
                        bytesSaved += outcome.bytesSaved
                    }
                    CompressionOutcome.Unchanged -> Unit
                    CompressionOutcome.Unreadable -> unreadable++
                    CompressionOutcome.Failed -> failed++
                }
                onProgress(index + 1, photos.size)
            }
        } finally {
            staging.deleteRecursively()
        }
        return PhotoCompressionResult(compressed, unreadable, bytesSaved, failed)
    }

    private sealed interface CompressionOutcome {
        data class Compressed(val bytesSaved: Long) : CompressionOutcome
        data object Unchanged : CompressionOutcome
        data object Unreadable : CompressionOutcome
        data object Failed : CompressionOutcome
    }

    private fun compressStoredPhoto(photo: File, staging: File): CompressionOutcome {
        if (synchronized(photoFileLock) { restoreWritingPhotos }) return CompressionOutcome.Failed
        val lengthBefore = photo.length()
        val modifiedBefore = photo.lastModified()
        val headerLongest = FoodImageDecoder.longestSide(photo)
        if (headerLongest != null && headerLongest <= STORED_MAX_DIMENSION) return CompressionOutcome.Unchanged
        val bitmap = FoodImageDecoder.decode(photo, STORED_MAX_DIMENSION) ?: return CompressionOutcome.Unreadable
        val staged = File(staging, "${photo.name}.${UUID.randomUUID()}.tmp")
        try {
            if (headerLongest == null && max(bitmap.width, bitmap.height) < STORED_MAX_DIMENSION) {
                return CompressionOutcome.Unchanged
            }
            val written = runCatching {
                FileOutputStream(staged).use { out ->
                    bitmap.compress(Bitmap.CompressFormat.JPEG, STORED_JPEG_QUALITY, out)
                }
            }.getOrDefault(false)
            if (!written) {
                staged.delete()
                return CompressionOutcome.Failed
            }
        } finally {
            bitmap.recycle()
        }
        // A copy that isn't smaller (an already heavily compressed photo) is never swapped in.
        if (staged.length() >= lengthBefore) {
            staged.delete()
            return CompressionOutcome.Unchanged
        }
        synchronized(photoFileLock) {
            // A restore that started while we were encoding owns the photo folder until it ends.
            if (restoreWritingPhotos) {
                staged.delete()
                return CompressionOutcome.Failed
            }
            // Skip if the photo was deleted, restored, or rewritten while we were encoding it.
            val unchanged = photo.isFile && photo.length() == lengthBefore && photo.lastModified() == modifiedBefore
            if (!unchanged) {
                staged.delete()
                return CompressionOutcome.Unchanged
            }
            if (!staged.renameTo(photo)) {
                staged.delete()
                return CompressionOutcome.Failed
            }
            return CompressionOutcome.Compressed(lengthBefore - photo.length())
        }
    }

    /**
     * Removes only image files that are no longer referenced by persisted app data.
     * Callers must include food-log, saved-meal, and pending-draft filenames in
     * [referencedFilenames]. This is safe to run repeatedly, including at startup,
     * and repairs orphaned files left by older builds without touching user data.
     *
     * Pass the [restoreGeneration] read before collecting [referencedFilenames]:
     * if a Drive restore started since, those references describe the photos it
     * replaced, and nothing is pruned.
     */
    fun pruneUnreferenced(referencedFilenames: Set<String>, generationAtRead: Long = restoreGeneration()) {
        restoreLock.read {
            if (restoresRunning > 0 || generationAtRead != generation) return
            val referenced = referencedFilenames.mapTo(mutableSetOf()) { File(it).name }

            dir.listFiles()
                ?.filter { it.isFile && it.name !in referenced }
                ?.forEach { deleteFiles(it.name) }

            // A crash can leave a thumbnail without its full-size image. Clean those
            // independently while preserving every thumbnail still referenced.
            thumbnailDir.listFiles()
                ?.filter { it.isFile && it.name !in referenced }
                ?.forEach { file ->
                    runCatching { file.delete() }
                    evictThumbnails(file.name)
                }
        }
    }

    private fun writeThumbnail(filename: String, bitmap: Bitmap) {
        val thumb = writeThumbnailFile(bitmap, File(thumbnailDir, filename))
        thumbnailCache.put("$filename:$THUMBNAIL_MAX_DIMENSION", thumb)
    }

    /** Writes [bitmap]'s thumbnail to [target] through a temp file and returns it. */
    private fun writeThumbnailFile(bitmap: Bitmap, target: File): Bitmap {
        val thumb = bitmap.scaledToMaxDimension(THUMBNAIL_MAX_DIMENSION)
        val temp = File(target.parentFile, "${target.name}.${UUID.randomUUID()}$TEMP_SUFFIX")
        try {
            FileOutputStream(temp).use { out ->
                thumb.compress(Bitmap.CompressFormat.JPEG, 76, out)
            }
            if (!temp.renameTo(target)) {
                temp.copyTo(target, overwrite = true)
                temp.delete()
            }
            return thumb
        } catch (e: Exception) {
            temp.delete()
            throw e
        }
    }

    private fun thumbnailLockFor(filename: String): Any =
        thumbnailLocks.getOrPut(filename) { Any() }

    private fun evictThumbnails(filename: String) {
        for (key in thumbnailCache.snapshot().keys) {
            if (key.startsWith("$filename:")) thumbnailCache.remove(key)
        }
    }

    data class PhotoStorageUsage(
        val photoCount: Int,
        val photoBytes: Long,
        val thumbnailBytes: Long
    )

    data class PhotoCompressionResult(
        val compressedCount: Int,
        val unreadableCount: Int,
        val bytesSaved: Long,
        /**
         * Photos left as they were because writing or swapping in the smaller copy failed (for
         * example with no free space), because a Drive restore was replacing photos at the time,
         * or that the run never reached because it stopped early.
         */
        val failedCount: Int = 0
    )

    companion object {
        private const val DIR_NAME = "fudai-food-images"
        private const val THUMBNAIL_DIR_NAME = "fudai-food-thumbnails-v2"
        private const val LEGACY_THUMBNAIL_DIR_NAME = "fudai-food-thumbnails"
        private const val COMPRESSION_STAGING_DIR_NAME = "fudai-food-images-compressing"
        private const val STAGING_DIR_NAME = "fudai-food-images-restore"
        private const val STAGING_THUMBNAIL_DIR_NAME = "fudai-food-thumbnails-restore"
        private const val TEMP_SUFFIX = ".tmp"
        private const val THUMBNAIL_MAX_DIMENSION = 320
        const val VIEWER_MAX_DIMENSION = 2048
        /** Longest side kept for stored photos: the viewer never decodes more than this. */
        const val STORED_MAX_DIMENSION = VIEWER_MAX_DIMENSION
        const val STORED_JPEG_QUALITY = 80
        private const val THUMBNAIL_CACHE_KB_DEFAULT = 12 * 1024

        /**
         * Serializes photo writes and deletes with the compressor's last unchanged-file check and
         * rename, so a photo saved, restored or deleted mid-compression is never replaced by a
         * copy of the older bytes. Process-wide because some screens build their own instance.
         * Held only around single file operations.
         */
        private val photoFileLock = Any()

        /** [candidate] when it is a smaller encoding than [original]; otherwise [original] unchanged. */
        internal fun smallerOrOriginal(original: ByteArray, candidate: ByteArray?): ByteArray =
            candidate?.takeIf { it.size < original.size } ?: original

        /**
         * Upright JPEG capped at [maxDimension] on the longest side, or null when the image is
         * already within the cap or can't be decoded — callers then keep the original bytes.
         */
        internal fun downscaledForStorage(bytes: ByteArray, maxDimension: Int = STORED_MAX_DIMENSION): ByteArray? =
            runCatching {
                val headerLongest = FoodImageDecoder.longestSide(bytes)
                if (headerLongest != null && headerLongest <= maxDimension) return null
                val bitmap = FoodImageDecoder.decode(bytes, maxDimension) ?: return null
                try {
                    // Formats BitmapFactory can't read report no header size; the decoder only
                    // scales images over the cap, so a smaller result means it was within bounds.
                    if (headerLongest == null && max(bitmap.width, bitmap.height) < maxDimension) return null
                    ByteArrayOutputStream().use { out ->
                        if (!bitmap.compress(Bitmap.CompressFormat.JPEG, STORED_JPEG_QUALITY, out)) return null
                        out.toByteArray()
                    }
                } finally {
                    bitmap.recycle()
                }
            }.getOrNull()

        fun thumbnailCacheKbFor(context: Context): Int {
            val memoryClass =
                (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).memoryClass
            return when {
                memoryClass <= 128 -> 4 * 1024
                memoryClass <= 192 -> 8 * 1024
                else -> THUMBNAIL_CACHE_KB_DEFAULT
            }
        }

        @VisibleForTesting
        fun forTests(baseDir: File): FoodImageStore =
            FoodImageStore(
                baseDir.apply { mkdirs() },
                cleanupLegacyThumbnails = false,
                thumbnailCacheKb = THUMBNAIL_CACHE_KB_DEFAULT
            )
    }
}
