package com.apoorvdarshan.calorietracker.ui.components

import android.graphics.Bitmap
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import com.apoorvdarshan.calorietracker.services.FoodImageStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Loads a food photo thumbnail off the composition thread; shows null until ready. */
@Composable
fun rememberFoodThumbnail(
    imageStore: FoodImageStore,
    filename: String?,
): Bitmap? {
    val bitmap by produceState<Bitmap?>(initialValue = null, filename, imageStore) {
        value = null
        value = filename?.let { name ->
            withContext(Dispatchers.IO) {
                imageStore.loadThumbnail(name)
            }
        }
    }
    return bitmap
}

/** Loads the first available thumbnail from [filenames] off the composition thread. */
@Composable
fun rememberFoodThumbnail(
    imageStore: FoodImageStore,
    filenames: List<String>,
): Bitmap? {
    return rememberFoodThumbnailCandidate(imageStore, filenames)?.second
}

/** Loads the first available thumbnail and its filename, preserving candidate order. */
@Composable
fun rememberFoodThumbnailCandidate(
    imageStore: FoodImageStore,
    filenames: List<String>,
): Pair<String, Bitmap>? {
    val candidate by produceState<Pair<String, Bitmap>?>(initialValue = null, filenames, imageStore) {
        value = null
        value = withContext(Dispatchers.IO) {
            filenames.firstNotNullOfOrNull { filename ->
                imageStore.loadThumbnail(filename)?.let { filename to it }
            }
        }
    }
    return candidate
}

/** Returns the viewer index for the thumbnail among successfully loaded viewer photos. */
fun foodPhotoViewerInitialIndex(loadedFilenames: List<String>, thumbnailFilename: String?): Int =
    thumbnailFilename?.let(loadedFilenames::indexOf)?.takeIf { it >= 0 } ?: 0
