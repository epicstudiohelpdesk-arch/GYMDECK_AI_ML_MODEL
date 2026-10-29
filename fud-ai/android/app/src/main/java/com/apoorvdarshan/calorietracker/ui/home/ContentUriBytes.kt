package com.apoorvdarshan.calorietracker.ui.home

import android.content.ContentResolver
import android.net.Uri
import java.io.ByteArrayOutputStream

/**
 * Reads a content URI with a hard size cap. Photo Picker / DocumentsProvider streams
 * are not bounded by the picker UI, so an unbounded [readBytes] can OOM on a huge asset.
 */
internal object ContentUriBytes {
    /** Comfortably above a high-res HEIC/JPEG while still rejecting multi-hundred-MB dumps. */
    private const val MAX_BYTES = 25 * 1024 * 1024
    private const val BUFFER_SIZE = 64 * 1024

    fun readBounded(resolver: ContentResolver, uri: Uri): ByteArray? =
        runCatching {
            resolver.openInputStream(uri)?.use { input ->
                ByteArrayOutputStream(BUFFER_SIZE).use { output ->
                    val buffer = ByteArray(BUFFER_SIZE)
                    var total = 0
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        total += read
                        if (total > MAX_BYTES) return@runCatching null
                        output.write(buffer, 0, read)
                    }
                    output.toByteArray()
                }
            }
        }.getOrNull()?.takeIf { it.isNotEmpty() }
}
