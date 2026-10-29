package com.apoorvdarshan.calorietracker.ui.components

import org.junit.Assert.assertEquals
import org.junit.Test

class FoodThumbnailStateTest {
    @Test
    fun viewerStartsAtThumbnailAfterEarlierPhotoFailsToLoad() {
        assertEquals(
            1,
            foodPhotoViewerInitialIndex(
                loadedFilenames = listOf("first.jpg", "final.jpg"),
                thumbnailFilename = "final.jpg"
            )
        )
    }

    @Test
    fun viewerFallsBackToFirstLoadedPhotoWhenThumbnailIsUnavailable() {
        assertEquals(
            0,
            foodPhotoViewerInitialIndex(
                loadedFilenames = listOf("first.jpg"),
                thumbnailFilename = "missing.jpg"
            )
        )
    }
}
