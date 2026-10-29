package com.apoorvdarshan.calorietracker.services.ai

import android.graphics.Bitmap
import com.apoorvdarshan.calorietracker.services.FoodImageDecoder
import java.io.ByteArrayOutputStream

/** Prepares food photos for vision requests without changing the locally stored original. */
internal object FoodImagePreprocessor {
    private const val MAX_DIMENSION = 1_600
    private const val JPEG_QUALITY = 80

    /**
     * Always returns a freshly encoded JPEG, because every provider client labels uploads
     * as `image/jpeg`. Undecodable input (corrupt data, or a HEIC/HEIF the device cannot
     * decode) fails with [AiError.ImageConversionFailed] instead of being uploaded as-is —
     * mislabeled raw bytes made Gemini stall until the request timeout.
     */
    fun prepareForUpload(bytes: ByteArray): ByteArray {
        val bitmap = runCatching { FoodImageDecoder.decode(bytes, MAX_DIMENSION) }.getOrNull()
            ?: throw AiError.ImageConversionFailed
        try {
            return ByteArrayOutputStream().use { output ->
                if (!bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, output)) {
                    throw AiError.ImageConversionFailed
                }
                output.toByteArray()
            }
        } catch (error: AiError) {
            throw error
        } catch (error: Throwable) {
            throw AiError.ImageConversionFailed
        } finally {
            bitmap.recycle()
        }
    }
}
