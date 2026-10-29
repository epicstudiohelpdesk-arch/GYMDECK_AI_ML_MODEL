package com.apoorvdarshan.calorietracker.services.voice

import com.apoorvdarshan.calorietracker.services.SecureHttpClient
import okhttp3.OkHttpClient
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import java.util.concurrent.TimeUnit
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture

/**
 * One live speech-to-speech connection (Scowld's LiveSession, on OkHttp).
 *
 * Setup messages go out first. Everything else waits in a queue until the provider is
 * ready (Gemini sends setupComplete; OpenAI and xAI send session.updated); microphone
 * audio in that queue is capped, so a slow connection keeps only the latest seconds of
 * speech. Gemini's goAway moves the session to a new connection with its resumption
 * handle. Events arrive on OkHttp's reader thread through [onEvent], in order.
 */
class LiveSession(
    val config: LiveSessionConfig,
    val wire: LiveWire = LiveWire.forConfig(config),
    private val client: OkHttpClient = defaultClient,
    private val setupTimeoutMillis: Long = 20_000,
    private val onEvent: (LiveEvent) -> Unit
) {
    private val lock = Any()
    private var socket: WebSocket? = null
    private var connection = 0
    private var ready = false
    private var closed = false
    private val queued = ArrayDeque<Queued>()
    private var queuedAudioBytes = 0
    private var resumptionHandle: String? = null
    private var setupDeadline: ScheduledFuture<*>? = null

    private class Queued(val message: String, val audioBytes: Int)

    fun connect() = open()

    fun sendAudio(pcm16: ByteArray) {
        if (pcm16.isEmpty()) return
        enqueue(wire.audioMessage(pcm16), pcm16.size)
    }

    /** A user text turn; [respond] asks the model to answer it. */
    fun sendText(text: String, respond: Boolean = true) {
        wire.textMessages(text, respond).forEach { enqueue(it, 0) }
    }

    fun sendImage(jpeg: ByteArray) {
        wire.imageMessages(jpeg).forEach { enqueue(it, 0) }
    }

    fun sendToolResults(results: List<LiveToolResult>) {
        wire.toolResultMessages(results).forEach { enqueue(it, 0) }
    }

    fun sendResponseCreate() {
        wire.responseCreateMessage()?.let { enqueue(it, 0) }
    }

    /** Tells the provider how much of reply [itemId] the user heard before speaking over it. */
    fun truncate(itemId: String, audioEndMs: Int) {
        wire.truncateMessage(itemId, audioEndMs)?.let { enqueue(it, 0) }
    }

    fun close() {
        val current = synchronized(lock) {
            closed = true
            connection += 1
            setupDeadline?.cancel(false)
            setupDeadline = null
            queued.clear()
            queuedAudioBytes = 0
            socket.also { socket = null }
        }
        current?.close(NORMAL_CLOSURE, null)
    }

    // MARK: - Connection

    private fun open() {
        val id: Int
        val handle: String?
        synchronized(lock) {
            if (closed) return
            connection += 1
            id = connection
            ready = false
            handle = resumptionHandle
        }
        val webSocket = client.newWebSocket(wire.request(config), Listener(id))
        val setup = wire.setupMessages(config, handle)
        val becomeReady = synchronized(lock) {
            if (id != connection || closed) {
                webSocket.cancel()
                return
            }
            socket = webSocket
            // OkHttp holds frames sent before the upgrade and writes them, in order, once
            // connected, so setup always goes first.
            setup.forEach { webSocket.send(it) }
            setupDeadline?.cancel(false)
            setupDeadline = deadlines.schedule({
                synchronized(lock) {
                    if (id == connection && !closed && !ready) {
                        ended(id, LiveFailure.Network("setup_timeout"))
                    }
                }
            }, setupTimeoutMillis, TimeUnit.MILLISECONDS)
            !wire.waitsForSetupAcknowledgement
        }
        if (becomeReady) markReady(id)
    }

    private inner class Listener(private val id: Int) : WebSocketListener() {
        override fun onMessage(webSocket: WebSocket, text: String) = handle(id, text)

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) = handle(id, bytes.utf8())

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(NORMAL_CLOSURE, null)
            ended(id, LiveFailure.Closed(code, reason.ifBlank { null }))
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            ended(id, LiveFailure.Closed(code, reason.ifBlank { null }))
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            val failure = if (response != null && response.code >= 400) {
                // A refused upgrade: the hosted Worker answers with JSON like the other routes.
                val body = runCatching { response.body.string() }.getOrNull()
                LiveFailure.Refused(response.code, body?.let(::errorCode))
            } else {
                LiveFailure.Network(t.message)
            }
            ended(id, failure)
        }
    }

    private fun handle(id: Int, text: String) {
        if (!isCurrent(id)) return
        for (event in wire.parse(text)) {
            if (!isCurrent(id)) return
            when (event) {
                LiveEvent.Ready -> markReady(id)
                is LiveEvent.ResumptionHandle -> synchronized(lock) { resumptionHandle = event.handle }
                LiveEvent.GoAway -> reconnect(id)
                else -> onEvent(event)
            }
        }
    }

    private fun isCurrent(id: Int): Boolean = synchronized(lock) { id == connection && !closed }

    private fun markReady(id: Int) {
        synchronized(lock) {
            val current = socket
            if (id != connection || closed || current == null || ready) return
            ready = true
            setupDeadline?.cancel(false)
            setupDeadline = null
            while (queued.isNotEmpty()) current.send(queued.removeFirst().message)
            queuedAudioBytes = 0
        }
        onEvent(LiveEvent.Ready)
    }

    private fun enqueue(message: String, audioBytes: Int) {
        synchronized(lock) {
            if (closed) return
            val current = socket
            if (ready && current != null) {
                current.send(message)
                return
            }
            queued.addLast(Queued(message, audioBytes))
            queuedAudioBytes += audioBytes
            dropOldestQueuedAudio()
        }
    }

    /** Keeps only the latest few seconds of speech while waiting; other messages stay. */
    private fun dropOldestQueuedAudio() {
        if (queuedAudioBytes <= MAX_QUEUED_AUDIO_BYTES) return
        val iterator = queued.iterator()
        while (queuedAudioBytes > MAX_QUEUED_AUDIO_BYTES && iterator.hasNext()) {
            val next = iterator.next()
            if (next.audioBytes > 0) {
                queuedAudioBytes -= next.audioBytes
                iterator.remove()
            }
        }
    }

    /** Gemini asks clients to move before it closes a connection; the handle carries the conversation over. */
    private fun reconnect(id: Int) {
        val old = synchronized(lock) {
            if (id != connection || closed) return
            // Retire the old connection first, so its closing can't end the session.
            connection += 1
            setupDeadline?.cancel(false)
            setupDeadline = null
            ready = false
            socket.also { socket = null }
        }
        VoiceLog.info(TAG, "Moving the live session to a new connection")
        old?.close(NORMAL_CLOSURE, null)
        open()
    }

    private fun ended(id: Int, failure: LiveFailure) {
        val current = synchronized(lock) {
            if (id != connection || closed) return
            closed = true
            setupDeadline?.cancel(false)
            setupDeadline = null
            queued.clear()
            queuedAudioBytes = 0
            socket.also { socket = null }
        }
        VoiceLog.warn(TAG, "Live connection ended: ${describe(failure)}")
        current?.cancel()
        onEvent(LiveEvent.Closed(failure))
    }

    companion object {
        private const val TAG = "LiveSession"
        const val NORMAL_CLOSURE = 1000

        /** Audio waiting for a connection beyond this is dropped, oldest first (six seconds at 24 kHz). */
        const val MAX_QUEUED_AUDIO_BYTES = 24_000 * 2 * 6

        private val deadlines = Executors.newSingleThreadScheduledExecutor { task ->
            Thread(task, "fudai-live-setup-timeout").apply { isDaemon = true }
        }

        val defaultClient: OkHttpClient by lazy {
            SecureHttpClient.builder()
                .connectTimeout(15, TimeUnit.SECONDS)
                .writeTimeout(15, TimeUnit.SECONDS)
                // A live socket is idle between turns; keep it open and probe it instead.
                .readTimeout(0, TimeUnit.MILLISECONDS)
                .callTimeout(0, TimeUnit.MILLISECONDS)
                .pingInterval(20, TimeUnit.SECONDS)
                .build()
        }

        /** The `error` code of a hosted JSON error body (`{"error":"voice_quota_exceeded"}`). */
        internal fun errorCode(body: String): String? =
            LiveJson.objectOrNull(body)?.let { LiveJson.string(it, "error") }?.takeIf { it.isNotBlank() }

        /** Logged without bodies or keys. */
        private fun describe(failure: LiveFailure): String = when (failure) {
            is LiveFailure.Refused -> "refused HTTP ${failure.status} ${failure.code.orEmpty()}"
            is LiveFailure.Closed -> "closed ${failure.code}"
            is LiveFailure.Network -> "network"
        }
    }
}
