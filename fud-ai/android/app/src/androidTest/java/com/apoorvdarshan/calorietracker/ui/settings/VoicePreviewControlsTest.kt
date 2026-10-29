package com.apoorvdarshan.calorietracker.ui.settings

import androidx.compose.material3.MaterialTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.apoorvdarshan.calorietracker.R
import com.apoorvdarshan.calorietracker.services.voice.VoicePreviewError
import com.apoorvdarshan.calorietracker.services.voice.VoicePreviewPhase
import com.apoorvdarshan.calorietracker.services.voice.VoicePreviewState
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

/** Physical Compose touches, without opening audio hardware or a live provider connection. */
class VoicePreviewControlsTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test fun stopRemainsTouchableWhilePreparingAndPlayingEvenIfAccessDisappears() {
        val state = mutableStateOf(VoicePreviewState())
        val available = mutableStateOf(true)
        var starts = 0
        var stops = 0
        compose.setContent {
            MaterialTheme {
                Box(Modifier.padding(24.dp)) {
                VoicePreviewControls(state.value, available.value, false) {
                    if (state.value.active) {
                        stops++
                        state.value = VoicePreviewState()
                    } else {
                        starts++
                        state.value = VoicePreviewState(VoicePreviewPhase.PREPARING)
                    }
                }
                }
            }
        }
        val button = compose.onNodeWithTag("voiceSettings.preview")
        button.assertIsEnabled().performClick()
        compose.onNodeWithTag("voiceSettings.previewPreparing").assertIsDisplayed()
        compose.runOnIdle { available.value = false }
        button.assertIsEnabled().assertTextContains(context.getString(R.string.voice_preview_stop)).performClick()
        button.assertIsNotEnabled()
        compose.runOnIdle { available.value = true }
        button.performClick()
        compose.runOnIdle { state.value = VoicePreviewState(VoicePreviewPhase.PLAYING) }
        compose.onNodeWithTag("voiceSettings.previewPreparing").assertDoesNotExist()
        button.performClick()
        compose.runOnIdle {
            assertEquals(2, starts)
            assertEquals(2, stops)
        }
    }

    @Test fun missingAccessAndActiveConversationDisablePreviewAndErrorsRemainVisible() {
        val available = mutableStateOf(false)
        val busy = mutableStateOf(false)
        val state = mutableStateOf(VoicePreviewState())
        compose.setContent {
            MaterialTheme {
                Box(Modifier.padding(24.dp)) {
                VoicePreviewControls(state.value, available.value, busy.value) {
                    error("A disabled preview must not start")
                }
                }
            }
        }
        compose.onNodeWithTag("voiceSettings.preview").assertIsNotEnabled()
        compose.runOnIdle { available.value = true; busy.value = true }
        compose.onNodeWithTag("voiceSettings.preview").assertIsNotEnabled()
        compose.onNodeWithTag("voiceSettings.previewError")
            .assertTextEquals(context.getString(R.string.voice_preview_busy))
        compose.runOnIdle { busy.value = false; state.value = VoicePreviewState(error = VoicePreviewError.FAILED) }
        compose.onNodeWithTag("voiceSettings.preview").assertIsEnabled()
        compose.onNodeWithTag("voiceSettings.previewError")
            .assertTextEquals(context.getString(R.string.voice_preview_failed))
    }
}
