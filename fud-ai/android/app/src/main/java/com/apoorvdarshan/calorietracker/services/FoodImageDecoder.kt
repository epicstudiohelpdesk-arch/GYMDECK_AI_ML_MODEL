package com.apoorvdarshan.calorietracker.services

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.media.ExifInterface
import android.os.Build
import androidx.annotation.RequiresApi
import androidx.annotation.VisibleForTesting
import java.io.ByteArrayInputStream
import java.io.File
import java.nio.ByteBuffer
import kotlin.math.max

/** Decodes upright pixels without modifying the original photo or its metadata. */
internal object FoodImageDecoder {
    fun decode(bytes: ByteArray, maxDimension: Int = Int.MAX_VALUE): Bitmap? {
        require(maxDimension > 0)
        // BitmapFactory is the fast path for the plain JPEGs the in-app camera produces.
        // Gallery / Photo Picker imports on modern devices can be HEIC/HEIF, WebP, or other
        // formats BitmapFactory rejects on some OEM builds; ImageDecoder (API 28+) covers those.
        decodeWithBitmapFactory(
            maxDimension,
            { options -> BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) },
            { ByteArrayInputStream(bytes).use { ExifInterface(it).orientation() } }
        )?.let { return it }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return null
        return decodeWithImageDecoder(maxDimension) { ImageDecoder.createSource(ByteBuffer.wrap(bytes)) }
    }

    fun decode(file: File, maxDimension: Int = Int.MAX_VALUE): Bitmap? {
        require(maxDimension > 0)
        decodeWithBitmapFactory(
            maxDimension,
            { options -> BitmapFactory.decodeFile(file.absolutePath, options) },
            { ExifInterface(file.absolutePath).orientation() }
        )?.let { return it }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return null
        return decodeWithImageDecoder(maxDimension) { ImageDecoder.createSource(file) }
    }

    /**
     * Longest side from the image header alone (no pixel decode), or null when BitmapFactory
     * can't read the header — e.g. HEIC on some OEM builds; callers then decode to find out.
     */
    fun longestSide(bytes: ByteArray): Int? =
        headerLongestSide { options -> BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) }

    fun longestSide(file: File): Int? =
        headerLongestSide { options -> BitmapFactory.decodeFile(file.absolutePath, options) }

    private fun headerLongestSide(readBitmap: (BitmapFactory.Options) -> Bitmap?): Int? = runCatching {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        readBitmap(bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) null else max(bounds.outWidth, bounds.outHeight)
    }.getOrNull()

    /** The fallback path on its own, so tests can prove it matches the BitmapFactory path. */
    @VisibleForTesting
    @RequiresApi(Build.VERSION_CODES.P)
    fun decodeWithImageDecoder(bytes: ByteArray, maxDimension: Int = Int.MAX_VALUE): Bitmap? {
        require(maxDimension > 0)
        return decodeWithImageDecoder(maxDimension) { ImageDecoder.createSource(ByteBuffer.wrap(bytes)) }
    }

    private fun decodeWithBitmapFactory(
        maxDimension: Int,
        readBitmap: (BitmapFactory.Options) -> Bitmap?,
        readOrientation: () -> Int
    ): Bitmap? = runCatching {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        readBitmap(bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sampleSize = 1
        val longest = max(bounds.outWidth, bounds.outHeight)
        while (longest / sampleSize / 2 >= maxDimension) sampleSize *= 2
        val decoded = readBitmap(BitmapFactory.Options().apply { inSampleSize = sampleSize })
            ?: return null
        val orientation = runCatching(readOrientation).getOrDefault(ExifInterface.ORIENTATION_NORMAL)
        val oriented = decoded.applyingExifOrientation(orientation)
        if (oriented !== decoded) decoded.recycle()
        val scaled = oriented.scaledToMaxDimension(maxDimension)
        if (scaled !== oriented) oriented.recycle()
        scaled
    }.getOrNull()

    @RequiresApi(Build.VERSION_CODES.P)
    private fun decodeWithImageDecoder(
        maxDimension: Int,
        imageDecoderSource: () -> ImageDecoder.Source
    ): Bitmap? = runCatching {
        // ImageDecoder applies EXIF orientation itself, so no Matrix pass is needed here.
        // Scaling happens inside the decoder, which keeps one bounded bitmap alive instead
        // of a full-resolution intermediate.
        val decoded = ImageDecoder.decodeBitmap(imageDecoderSource()) { decoder, info, _ ->
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            decoder.isMutableRequired = false
            val width = info.size.width
            val height = info.size.height
            val longest = max(width, height)
            if (longest > maxDimension) {
                val scale = maxDimension.toFloat() / longest
                decoder.setTargetSize(
                    (width * scale).toInt().coerceAtLeast(1),
                    (height * scale).toInt().coerceAtLeast(1)
                )
            }
        }
        val scaled = decoded.scaledToMaxDimension(maxDimension)
        if (scaled !== decoded) decoded.recycle()
        scaled
    }.getOrNull()

    private fun ExifInterface.orientation(): Int =
        getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)

    fun Bitmap.scaledToMaxDimension(maxDimension: Int): Bitmap {
        require(maxDimension > 0)
        val longest = max(width, height)
        if (longest <= maxDimension) return this
        val scale = maxDimension.toFloat() / longest
        return Bitmap.createScaledBitmap(
            this,
            (width * scale).toInt().coerceAtLeast(1),
            (height * scale).toInt().coerceAtLeast(1),
            true
        )
    }

    private fun Bitmap.applyingExifOrientation(orientation: Int): Bitmap {
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.setScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.setRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.setScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.setRotate(90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.setRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.setRotate(-90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.setRotate(-90f)
            else -> return this
        }
        return Bitmap.createBitmap(this, 0, 0, width, height, matrix, true)
    }
}
