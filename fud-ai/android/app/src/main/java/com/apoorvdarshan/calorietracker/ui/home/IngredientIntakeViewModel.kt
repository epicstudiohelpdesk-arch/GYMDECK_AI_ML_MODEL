package com.apoorvdarshan.calorietracker.ui.home

import android.content.ContentResolver
import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.apoorvdarshan.calorietracker.models.MealIngredient
import com.apoorvdarshan.calorietracker.models.toMealIngredient
import com.apoorvdarshan.calorietracker.services.FoodImageStore
import com.apoorvdarshan.calorietracker.services.ai.FoodAnalysis
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal data class IngredientIntakeState(
    val busy: Boolean = false,
    val result: MealIngredient? = null,
    val error: String? = null
)

/** Keeps an ingredient request alive without retaining callbacks to a recreated sheet. */
internal class IngredientIntakeViewModel : ViewModel() {
    private val mutableState = MutableStateFlow(IngredientIntakeState())
    val state = mutableState.asStateFlow()
    private var request: Job? = null
    private var imageStoreRef: FoodImageStore? = null
    /** Filename written for the in-flight/unpublished result; cleared once the host consumes it. */
    private var ownedImageFilename: String? = null

    fun analyze(
        imageBytes: ByteArray?,
        imageStore: FoodImageStore,
        failureMessage: String,
        block: suspend () -> FoodAnalysis
    ) = start(imageStore, failureMessage, loadImage = { imageBytes }, analyze = { block() })

    /** Reads the picked photo on IO first; Photo Picker URIs may stream from the cloud. */
    fun analyzeImportedPhoto(
        resolver: ContentResolver,
        uri: Uri,
        imageStore: FoodImageStore,
        failureMessage: String,
        block: suspend (ByteArray) -> FoodAnalysis
    ) = start(
        imageStore,
        failureMessage,
        loadImage = {
            withContext(Dispatchers.IO) {
                ContentUriBytes.readBounded(resolver, uri)
            } ?: throw IllegalStateException(failureMessage)
        },
        analyze = { bytes -> block(bytes ?: throw IllegalStateException(failureMessage)) }
    )

    private fun start(
        imageStore: FoodImageStore,
        failureMessage: String,
        loadImage: suspend () -> ByteArray?,
        analyze: suspend (ByteArray?) -> FoodAnalysis
    ) {
        if (mutableState.value.busy || mutableState.value.result != null) return
        imageStoreRef = imageStore
        mutableState.value = IngredientIntakeState(busy = true)
        request = viewModelScope.launch {
            var storedFilename: String? = null
            try {
                val imageBytes = loadImage()
                val ingredient = analyze(imageBytes).toMealIngredient()
                storedFilename = imageBytes?.let {
                    withContext(Dispatchers.IO) { imageStore.storeBytes(it, UUID.randomUUID()) }
                }
                ownedImageFilename = storedFilename
                mutableState.value = IngredientIntakeState(result = ingredient.copy(imageFilename = storedFilename))
            } catch (cancelled: CancellationException) {
                deleteOwnedImage(imageStore, storedFilename)
                throw cancelled
            } catch (error: Exception) {
                deleteOwnedImage(imageStore, storedFilename)
                mutableState.value = IngredientIntakeState(
                    error = error.message?.takeIf { it.isNotBlank() } ?: failureMessage
                )
            }
        }
    }

    fun consumeResult() {
        ownedImageFilename = null
        mutableState.value = mutableState.value.copy(result = null)
    }

    fun dismissError() {
        mutableState.value = mutableState.value.copy(error = null)
    }

    fun discard() {
        val job = request
        request = null
        job?.cancel()
        val orphan = ownedImageFilename
        ownedImageFilename = null
        mutableState.value = IngredientIntakeState()
        val store = imageStoreRef
        if (orphan != null && store != null) {
            viewModelScope.launch(NonCancellable + Dispatchers.IO) { store.delete(orphan) }
        }
    }

    private suspend fun deleteOwnedImage(imageStore: FoodImageStore, filename: String?) {
        ownedImageFilename = null
        if (filename == null) return
        withContext(NonCancellable + Dispatchers.IO) { imageStore.delete(filename) }
    }
}
