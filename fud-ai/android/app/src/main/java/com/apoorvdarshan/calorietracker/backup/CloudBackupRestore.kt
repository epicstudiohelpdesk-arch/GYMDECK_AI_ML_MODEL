package com.apoorvdarshan.calorietracker.backup

import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.io.InputStream

/**
 * Where a restore puts photos: FoodImageStore in the app, a fake in tests.
 * Restored photos are staged first, so the current ones stay untouched until
 * every photo in the archive has been read and written.
 */
interface CloudBackupPhotoStore {
    /** Free storage for staging. The current photos stay on disk meanwhile. */
    fun bytesFree(): Long

    /** Starts an empty staging area, removing anything an interrupted restore left. */
    fun startStaging()

    /**
     * Copies one restored photo into the staging area. False when [filename]
     * is not a plain photo name that stays inside the staging area, or the
     * write fails.
     */
    fun stagePhoto(filename: String, input: InputStream): Boolean

    /**
     * Moves every staged photo into place, replacing a current photo with the
     * same name. Other current photos stay until the reference-checked prune
     * finds nothing in the restored diary using them. Throws if a photo cannot
     * be moved.
     */
    fun commitStaged()

    /** Deletes the staging area. Safe to call when there is none. */
    fun discardStaged()

    /**
     * Brackets [commitStaged] and the values write. In between, deletions
     * decided from the old diary are skipped.
     */
    fun beginRestore()
    fun endRestore()
}

/** Not enough free storage to restore. Thrown before anything local changes. */
class CloudBackupNoSpaceException : IOException()

/** A restored photo could not be written or moved into place. */
class CloudBackupPhotoWriteException : IOException()

object CloudBackupRestore {
    // Each restored photo also gets a thumbnail; the reserve covers file-system
    // overhead and keeps the phone from being filled to the last byte.
    const val THUMBNAIL_ALLOWANCE_BYTES = 64L * 1024
    const val RESERVE_BYTES = 16L * 1024 * 1024

    /** Storage a restore of [contents] needs: photos, thumbnails, and the values write. */
    fun requiredBytes(contents: CloudBackupContents): Long =
        contents.photoBytes +
            contents.photoCount * THUMBNAIL_ALLOWANCE_BYTES +
            contents.payloadBytes +
            RESERVE_BYTES

    /**
     * Stages every photo in [archive], then moves them into place and passes
     * the document to [commit], which restores the backed-up values. A read or
     * write failure while staging throws before any current photo or value
     * changes, so the diary never points at photos the restore removed.
     */
    suspend fun apply(
        archive: File,
        photos: CloudBackupPhotoStore,
        commit: suspend (document: CloudBackupDocument) -> Unit,
    ) {
        // Validates the whole archive before anything is written.
        val contents = CloudBackupArchive.inspect(archive)
        // The downloaded archive and the current photos stay on disk while the
        // restored photos are staged, so check before writing any of them.
        if (photos.bytesFree() < requiredBytes(contents)) throw CloudBackupNoSpaceException()
        currentCoroutineContext().ensureActive()
        // The app stays usable during a restore, so the screen that started it
        // can close midway (#484). A validated restore runs to the end instead
        // of stopping between moving photos in and writing the diary.
        withContext(NonCancellable) {
            try {
                photos.startStaging()
                CloudBackupArchive.forEachPhoto(archive) { name, input ->
                    if (!photos.stagePhoto(name, input)) throw CloudBackupPhotoWriteException()
                }
                photos.beginRestore()
                try {
                    photos.commitStaged()
                    commit(contents.document)
                } finally {
                    photos.endRestore()
                }
            } finally {
                photos.discardStaged()
            }
        }
    }
}
