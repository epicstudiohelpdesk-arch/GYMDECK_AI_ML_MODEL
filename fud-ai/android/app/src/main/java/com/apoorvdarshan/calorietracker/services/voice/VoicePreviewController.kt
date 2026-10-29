package com.apoorvdarshan.calorietracker.services.voice

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

enum class VoicePreviewPhase { IDLE, PREPARING, PLAYING }
enum class VoicePreviewError { FAILED, BUSY }

data class VoicePreviewState(
    val phase: VoicePreviewPhase = VoicePreviewPhase.IDLE,
    val error: VoicePreviewError? = null
) {
    val active: Boolean get() = phase != VoicePreviewPhase.IDLE
}

/** Deliberately exposes no audio input, image or tool-result methods. */
interface VoicePreviewConnection {
    fun connect()
    fun sendSample(text: String)
    fun close()
}

/** Main-thread owner of one bounded, output-only sample; callbacks are marshalled to [scope]. */
class VoicePreviewController(
    private val scope: CoroutineScope,
    private val prepare: suspend (appLanguage: String) -> LiveSessionConfig,
    private val conversationActive: () -> Boolean,
    private val createAudio: () -> LivePlaybackIO,
    private val createConnection: (LiveSessionConfig, (LiveEvent) -> Unit) -> VoicePreviewConnection,
    private val lifetimeMillis: Long = 30_000
) {
    private val _state = MutableStateFlow(VoicePreviewState())
    val state = _state.asStateFlow()
    private var generation = 0L
    private var preparation: Job? = null
    private var deadline: Job? = null
    private var connection: VoicePreviewConnection? = null
    private var audio: LivePlaybackIO? = null
    private var requested = false
    private var completed = false
    private var receivedBytes = 0L
    private var maxBytes = 0L
    private var quietFinish: Job? = null

    fun start(sample: String, appLanguage: String) {
        stop()
        if (conversationActive()) {
            _state.value = VoicePreviewState(error = VoicePreviewError.BUSY)
            return
        }
        val id = generation
        _state.value = VoicePreviewState(VoicePreviewPhase.PREPARING)
        deadline = scope.launch {
            delay(lifetimeMillis)
            finish(id, VoicePreviewError.FAILED)
        }
        preparation = scope.launch {
            try {
                val config = prepare(appLanguage)
                if (id != generation) return@launch
                if (conversationActive()) {
                    finish(id, VoicePreviewError.BUSY)
                    return@launch
                }
                // The adapter supplies a minimal config; reject accidental assistant-tool reuse.
                require(config.tools.isEmpty())
                maxBytes = config.provider.outputSampleRate.toLong() * 2 * MAX_AUDIO_SECONDS
                connection = createConnection(config) { event ->
                    scope.launch { if (id == generation) handle(id, event, config, sample) }
                }
                connection?.connect()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                finish(id, VoicePreviewError.FAILED)
            }
        }
    }

    fun stop() = finish(generation)

    private fun handle(id: Long, event: LiveEvent, config: LiveSessionConfig, sample: String) {
        // The socket is closed once generation ends. Late network events cannot cut off
        // the queued sample; only drain, Stop, interruption or the total deadline can.
        if (completed) return
        if (conversationActive()) {
            finish(id, VoicePreviewError.BUSY)
            return
        }
        try {
            when (event) {
                LiveEvent.Ready -> if (!requested && !completed) {
                    requested = true
                    val output = createAudio()
                    audio = output // Keep partial starts reachable for cleanup.
                    output.onPlaybackFinished = {
                        scope.launch {
                            if (id == generation && completed && !output.isPlaying) finish(id)
                        }
                    }
                    output.onInterrupted = { scope.launch { finish(id, VoicePreviewError.FAILED) } }
                    output.startPlayback(config.provider.outputSampleRate)
                    // Realtime wires add response.create themselves; send exactly one text turn.
                    connection?.sendSample(sample)
                }
                is LiveEvent.Audio -> if (!completed) {
                    require(requested && event.pcm.isNotEmpty() && event.pcm.size % 2 == 0)
                    receivedBytes += event.pcm.size
                    require(receivedBytes <= maxBytes)
                    audio?.play(event.pcm)
                    _state.value = VoicePreviewState(VoicePreviewPhase.PLAYING)
                    if (!config.provider.reportsTurnEnds) {
                        // GPT-Live never says the sample ended; it's over once audio stops.
                        quietFinish?.cancel()
                        quietFinish = scope.launch {
                            delay(QUIET_FINISH_MS)
                            if (id == generation && !completed) completeSample(id)
                        }
                    }
                }
                is LiveEvent.TurnComplete -> if (!completed) {
                    if (!event.successful) {
                        finish(id, VoicePreviewError.FAILED)
                        return
                    }
                    // GPT-Live's backend finishing doesn't end the spoken sample.
                    if (event.endsSpokenTurn) completeSample(id)
                }
                is LiveEvent.Closed -> if (!completed) finish(id, VoicePreviewError.FAILED)
                is LiveEvent.ProviderError, is LiveEvent.HostedNotice, is LiveEvent.ToolCalls ->
                    finish(id, VoicePreviewError.FAILED)
                LiveEvent.Interrupted -> finish(id, VoicePreviewError.FAILED)
                else -> Unit // No captions, tools or conversation history are retained.
            }
        } catch (_: Exception) {
            finish(id, VoicePreviewError.FAILED)
        }
    }

    private fun completeSample(id: Long) {
        completed = true
        // End provider billing promptly, then let already queued output finish.
        connection?.close()
        connection = null
        if (receivedBytes == 0L) finish(id, VoicePreviewError.FAILED)
        else if (audio?.isPlaying != true) finish(id)
    }

    private fun finish(id: Long, error: VoicePreviewError? = null) {
        if (id != generation) return
        generation++
        quietFinish?.cancel()
        quietFinish = null
        preparation?.cancel()
        preparation = null
        deadline?.cancel()
        deadline = null
        runCatching { connection?.close() }
        connection = null
        runCatching { audio?.stop() }
        audio = null
        requested = false
        completed = false
        receivedBytes = 0
        _state.value = VoicePreviewState(error = error)
    }

    companion object {
        private const val MAX_AUDIO_SECONDS = 30
        /** How long GPT-Live audio must pause before its sample counts as finished. */
        private const val QUIET_FINISH_MS = 1_500L
    }
}
