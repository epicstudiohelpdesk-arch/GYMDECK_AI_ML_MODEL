package com.apoorvdarshan.calorietracker.services.voice

import com.apoorvdarshan.calorietracker.data.VoiceAssistantPreferences
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class VoicePreviewControllerTest {
    private class Output : LivePlaybackIO {
        override var onPlaybackFinished: (() -> Unit)? = null
        override var onInterrupted: (() -> Unit)? = null
        override var isPlaying = false
        var starts = 0
        var stops = 0
        var bytes = 0
        var failStart = false
        override fun startPlayback(outputSampleRate: Int) {
            starts++
            assertEquals(24_000, outputSampleRate)
            if (failStart) error("Private device error")
        }
        override fun play(pcm16: ByteArray) { bytes += pcm16.size; isPlaying = true }
        override fun stop() { stops++; isPlaying = false }
        fun drain() { isPlaying = false; onPlaybackFinished?.invoke() }
    }

    private class Connection(val emit: (LiveEvent) -> Unit) : VoicePreviewConnection {
        var connected = false
        var closes = 0
        val samples = mutableListOf<String>()
        override fun connect() { connected = true }
        override fun sendSample(text: String) { samples += text }
        override fun close() { closes++ }
    }

    private class Fixture(scope: TestScope, prepare: suspend (String) -> LiveSessionConfig = { config() }) {
        var busy = false
        var failAudioStart = false
        val outputs = mutableListOf<Output>()
        val connections = mutableListOf<Connection>()
        val controller = VoicePreviewController(scope, prepare, { busy }, {
            Output().also { it.failStart = failAudioStart; outputs += it }
        }, { config, emit ->
            assertTrue(config.tools.isEmpty())
            Connection(emit).also { connections += it }
        })
    }

    @Test fun sampleIsSentOnceAndCompletionClosesNetworkBeforeDrainingAudio() = runTest {
        val fixture = Fixture(this)
        fixture.controller.start("Localized sample", "fr")
        runCurrent()
        val connection = fixture.connections.single()
        connection.emit(LiveEvent.Ready)
        connection.emit(LiveEvent.Ready) // A resumed session must not repeat the sample.
        runCurrent()
        assertEquals(listOf("Localized sample"), connection.samples)
        val audio = fixture.outputs.single()
        assertEquals(1, audio.starts)
        connection.emit(LiveEvent.Audio(byteArrayOf(1, 2), null))
        runCurrent()
        audio.drain() // A streaming gap is not the end of the response.
        runCurrent()
        assertTrue(fixture.controller.state.value.active)
        connection.emit(LiveEvent.Audio(byteArrayOf(3, 4), null))
        connection.emit(LiveEvent.TurnComplete())
        runCurrent()
        assertEquals(1, connection.closes)
        assertEquals(0, audio.stops)
        assertTrue(fixture.controller.state.value.active)
        connection.emit(LiveEvent.Closed(LiveFailure.Closed(1000, null)))
        connection.emit(LiveEvent.ProviderError("late shutdown error"))
        connection.emit(LiveEvent.HostedNotice("session_limit"))
        runCurrent()
        assertTrue(fixture.controller.state.value.active)
        audio.drain()
        runCurrent()
        assertEquals(VoicePreviewState(), fixture.controller.state.value)
        assertEquals(1, audio.stops)
    }

    @Test fun gptLiveSampleEndsWhenAudioGoesQuietNotWhenItsBackendFinishes() = runTest {
        val fixture = Fixture(this, prepare = {
            voicePreviewConfig(LiveProvider.GPT_LIVE, VoiceAssistantPreferences(), "en", "saved-key", null)
        })
        fixture.controller.start("Sample", "en")
        runCurrent()
        val connection = fixture.connections.single()
        connection.emit(LiveEvent.Ready)
        runCurrent()
        // The backend finishes before GPT-Live speaks the sample.
        connection.emit(LiveEvent.TurnComplete(endsSpokenTurn = false))
        runCurrent()
        assertTrue(fixture.controller.state.value.active)
        assertEquals(0, connection.closes)
        connection.emit(LiveEvent.Audio(byteArrayOf(1, 2), null))
        runCurrent()
        advanceTimeBy(1_000)
        runCurrent()
        assertEquals(0, connection.closes)
        advanceTimeBy(1_000)
        runCurrent()
        assertEquals(1, connection.closes)
        fixture.outputs.single().drain()
        runCurrent()
        assertEquals(VoicePreviewState(), fixture.controller.state.value)
    }

    @Test fun gptLiveUnsuccessfulBackendCompletionFailsThePreview() = runTest {
        val fixture = Fixture(this, prepare = {
            voicePreviewConfig(LiveProvider.GPT_LIVE, VoiceAssistantPreferences(), "en", "saved-key", null)
        })
        fixture.controller.start("Sample", "en")
        runCurrent()
        val connection = fixture.connections.single()
        connection.emit(LiveEvent.Ready)
        runCurrent()
        connection.emit(LiveEvent.TurnComplete(successful = false, endsSpokenTurn = false))
        runCurrent()
        assertFalse(fixture.controller.state.value.active)
        assertEquals(VoicePreviewError.FAILED, fixture.controller.state.value.error)
    }

    @Test fun alreadyDrainedAudioFinishesWhenTheProviderCompletes() = runTest {
        val fixture = Fixture(this)
        fixture.controller.start("Sample", "en")
        runCurrent()
        val connection = fixture.connections.single()
        connection.emit(LiveEvent.Ready)
        connection.emit(LiveEvent.Audio(byteArrayOf(1, 2), null))
        runCurrent()
        fixture.outputs.single().drain()
        connection.emit(LiveEvent.TurnComplete())
        runCurrent()
        assertEquals(VoicePreviewState(), fixture.controller.state.value)
        assertEquals(1, connection.closes)
    }

    @Test fun unsuccessfulRealtimeCompletionStopsPartialAudioWithVisibleFailure() = runTest {
        for (wire in listOf(OpenAIRealtimeWire(), XAIVoiceWire())) {
            for (status in listOf("cancelled", "incomplete")) {
                val fixture = Fixture(this)
                fixture.controller.start("Sample", "en")
                runCurrent()
                val connection = fixture.connections.single()
                connection.emit(LiveEvent.Ready)
                connection.emit(LiveEvent.Audio(byteArrayOf(1, 2), null))
                runCurrent()
                val output = fixture.outputs.single()
                assertTrue(output.isPlaying)
                wire.parse("""{"type":"response.done","response":{"id":"r1","status":"$status"}}""")
                    .forEach(connection.emit)
                runCurrent()
                assertEquals(VoicePreviewState(error = VoicePreviewError.FAILED), fixture.controller.state.value)
                assertEquals(1, connection.closes)
                assertEquals(1, output.stops)
                assertFalse(output.isPlaying)
                output.onPlaybackFinished?.invoke()
                runCurrent()
                assertEquals(VoicePreviewError.FAILED, fixture.controller.state.value.error)
            }
        }
    }

    @Test fun stopCancelsPreparationAndLateCallbacksCannotAffectTheNextPreview() = runTest {
        val ready = CompletableDeferred<Unit>()
        val fixture = Fixture(this) { ready.await(); config() }
        fixture.controller.start("Old", "en")
        runCurrent()
        fixture.controller.stop()
        ready.complete(Unit)
        runCurrent()
        assertTrue(fixture.connections.isEmpty())
        fixture.controller.start("First", "en")
        runCurrent()
        val old = fixture.connections.single()
        old.emit(LiveEvent.Ready)
        runCurrent()
        val lateInterruption = fixture.outputs.single().onInterrupted!!
        fixture.controller.stop()
        fixture.controller.start("Second", "en")
        runCurrent()
        old.emit(LiveEvent.ProviderError("private provider details"))
        lateInterruption()
        runCurrent()
        assertTrue(fixture.controller.state.value.active)
        assertNull(fixture.controller.state.value.error)
        assertEquals(0, fixture.connections.last().closes)
        fixture.controller.stop()
    }

    @Test fun totalDeadlineCoversCredentialLookupAndStreamingWithoutCompletion() = runTest {
        val unresolved = CompletableDeferred<LiveSessionConfig>()
        val loading = Fixture(this) { unresolved.await() }
        loading.controller.start("Sample", "en")
        advanceTimeBy(30_000)
        runCurrent()
        assertEquals(VoicePreviewError.FAILED, loading.controller.state.value.error)
        assertTrue(loading.connections.isEmpty())

        val streaming = Fixture(this)
        streaming.controller.start("Sample", "en")
        runCurrent()
        val connection = streaming.connections.single()
        connection.emit(LiveEvent.Ready)
        connection.emit(LiveEvent.Audio(byteArrayOf(1, 2), null))
        runCurrent()
        advanceTimeBy(30_000)
        runCurrent()
        assertEquals(VoicePreviewError.FAILED, streaming.controller.state.value.error)
        assertEquals(1, connection.closes)
        assertEquals(1, streaming.outputs.single().stops)
    }

    @Test fun responseAudioHasADurationCapEvenIfItArrivesFasterThanRealtime() = runTest {
        val fixture = Fixture(this)
        fixture.controller.start("Sample", "en")
        runCurrent()
        val connection = fixture.connections.single()
        connection.emit(LiveEvent.Ready)
        connection.emit(LiveEvent.Audio(ByteArray(24_000 * 2 * 30 + 2), null))
        runCurrent()
        assertEquals(VoicePreviewError.FAILED, fixture.controller.state.value.error)
        assertEquals(0, fixture.outputs.single().bytes)
    }

    @Test fun activeConversationBlocksBeforeAndAfterAsynchronousPreparation() = runTest {
        val fixture = Fixture(this)
        fixture.busy = true
        fixture.controller.start("Sample", "en")
        runCurrent()
        assertEquals(VoicePreviewError.BUSY, fixture.controller.state.value.error)
        assertTrue(fixture.connections.isEmpty())

        val ready = CompletableDeferred<Unit>()
        val loading = Fixture(this) { ready.await(); config() }
        loading.controller.start("Sample", "en")
        runCurrent()
        loading.busy = true
        ready.complete(Unit)
        runCurrent()
        assertEquals(VoicePreviewError.BUSY, loading.controller.state.value.error)
        assertTrue(loading.connections.isEmpty())
    }

    @Test fun providerErrorsAreSanitizedAndLateReadyCannotReviveThePreview() = runTest {
        val fixture = Fixture(this)
        fixture.controller.start("Sample", "en")
        runCurrent()
        val connection = fixture.connections.single()
        connection.emit(LiveEvent.ProviderError("private response with credential-like data"))
        connection.emit(LiveEvent.Ready)
        runCurrent()
        assertEquals(VoicePreviewState(error = VoicePreviewError.FAILED), fixture.controller.state.value)
        assertTrue(fixture.outputs.isEmpty())
        assertTrue(connection.samples.isEmpty())
    }

    @Test fun partialAudioStartsAreCleanedUpAndOutputInterruptionsStopTheConnection() = runTest {
        val fixture = Fixture(this)
        fixture.failAudioStart = true
        fixture.controller.start("Sample", "en")
        runCurrent()
        fixture.connections.single().emit(LiveEvent.Ready)
        runCurrent()
        assertEquals(VoicePreviewError.FAILED, fixture.controller.state.value.error)
        assertEquals(1, fixture.connections.single().closes)
        assertEquals(1, fixture.outputs.single().stops)
        assertTrue(fixture.connections.single().samples.isEmpty())

        fixture.failAudioStart = false
        fixture.controller.start("Sample", "en")
        runCurrent()
        fixture.connections.last().emit(LiveEvent.Ready)
        runCurrent()
        fixture.outputs.last().onInterrupted!!()
        runCurrent()
        assertEquals(VoicePreviewError.FAILED, fixture.controller.state.value.error)
        assertEquals(1, fixture.connections.last().closes)
        assertEquals(1, fixture.outputs.last().stops)
    }

    @Test fun hostedLimitsAndEmptyResponsesEndWithVisibleFailure() = runTest {
        for (event in listOf(LiveEvent.HostedNotice("voice_quota_exceeded"), LiveEvent.TurnComplete())) {
            val fixture = Fixture(this)
            fixture.controller.start("Sample", "en")
            runCurrent()
            val connection = fixture.connections.single()
            connection.emit(event)
            runCurrent()
            assertEquals(VoicePreviewError.FAILED, fixture.controller.state.value.error)
            assertEquals(1, connection.closes)
        }
    }

    @Test fun previewConfigurationUsesSelectedVoiceModelLanguageAndOnlyItsOwnCredential() {
        val prefs = VoiceAssistantPreferences(
            models = LiveProvider.entries.associateWith { it.models.last() },
            voices = LiveProvider.entries.associateWith { it.voices.last() },
            language = "ja"
        )
        for (provider in LiveProvider.entries) {
            val config = voicePreviewConfig(provider, prefs, "fr", "saved-key", "hosted-user")
            assertEquals(provider.models.last(), config.model)
            assertEquals(provider.voices.last(), config.voice)
            assertTrue(config.tools.isEmpty())
            assertTrue(config.instructions.contains("tag ja"))
            assertEquals(if (provider.usesOwnKey) "saved-key" else null, config.apiKey)
            assertEquals(if (provider == LiveProvider.HOSTED) "hosted-user" else null, config.hostedUserId)
        }
        for (language in listOf(VoiceAssistantPreferences.LANGUAGE_APP, VoiceAssistantPreferences.LANGUAGE_AUTOMATIC)) {
            assertTrue(voicePreviewConfig(LiveProvider.GEMINI, prefs.copy(language = language), "fr", null, null)
                .instructions.contains("tag fr"))
        }
    }

    companion object {
        private fun config() = voicePreviewConfig(LiveProvider.GEMINI, VoiceAssistantPreferences(), "en", "saved-key", null)
    }
}
