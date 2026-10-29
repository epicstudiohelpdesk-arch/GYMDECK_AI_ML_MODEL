package com.apoorvdarshan.calorietracker.services.voice

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.ByteString.Companion.encodeUtf8
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

class LiveSessionTest {
    private val server = MockWebServer()
    private val client = OkHttpClient.Builder().readTimeout(0, TimeUnit.MILLISECONDS).build()
    private val userId = "\$RCAnonymousID:0123456789abcdef0123456789abcdef"

    /** The Worker's side of one connection. */
    private class ServerSide : WebSocketListener() {
        val messages = LinkedBlockingQueue<String>()
        val opened = CountDownLatch(1)
        @Volatile var socket: WebSocket? = null

        override fun onOpen(webSocket: WebSocket, response: Response) {
            socket = webSocket
            opened.countDown()
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            messages.add(text)
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(code, null)
        }

        fun awaitOpen(): WebSocket {
            assertTrue("The client never connected", opened.await(5, TimeUnit.SECONDS))
            return socket!!
        }

        fun next(): String = messages.poll(5, TimeUnit.SECONDS) ?: error("No message from the client")
    }

    @Before
    fun setUp() {
        server.start()
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    private fun hostedConfig() = LiveSessionConfig(
        provider = LiveProvider.HOSTED,
        model = LiveProvider.HOSTED_MODEL,
        voice = "Kore",
        instructions = "Be brief.",
        tools = VoiceToolCatalog.declared(RepoFiles.catalog, workoutDiaryEnabled = true),
        hostedUserId = userId,
        hostedUrl = server.url("/api/hosted-ai/v1/live").toString().replaceFirst("http", "ws")
    )

    private fun session(events: LinkedBlockingQueue<LiveEvent>, config: LiveSessionConfig = hostedConfig()) =
        LiveSession(config, client = client) { events.add(it) }

    private fun LinkedBlockingQueue<LiveEvent>.next(): LiveEvent = poll(5, TimeUnit.SECONDS) ?: error("No event")

    @Test
    fun hostedSessionSendsIdentityThenSetupAndHoldsAudioUntilSetupCompletes() {
        val worker = ServerSide()
        server.enqueue(MockResponse().withWebSocketUpgrade(worker))
        val events = LinkedBlockingQueue<LiveEvent>()
        val live = session(events)
        live.connect()
        live.sendAudio(byteArrayOf(1, 2, 3, 4))

        val request = server.takeRequest(5, TimeUnit.SECONDS)!!
        assertEquals("/api/hosted-ai/v1/live", request.path)
        assertEquals(userId, request.getHeader("X-Fud-User-Id"))
        assertEquals("android", request.getHeader("X-Fud-Platform"))

        val socket = worker.awaitOpen()
        val first = Json.parseToJsonElement(worker.next()).jsonObject
        assertTrue("The first message must be setup", first.containsKey("setup"))
        assertNull("Audio waits for setupComplete", worker.messages.poll(300, TimeUnit.MILLISECONDS))

        socket.send("""{"setupComplete":{}}""")
        assertEquals(LiveEvent.Ready, events.next())
        val audio = Json.parseToJsonElement(worker.next()).jsonObject
        assertTrue(audio["realtimeInput"]!!.jsonObject.containsKey("audio"))

        live.sendToolResults(listOf(LiveToolResult("c1", "get_app_state", ToolResults.ok { })))
        assertTrue(Json.parseToJsonElement(worker.next()).jsonObject.containsKey("toolResponse"))
        live.close()
    }

    @Test
    fun binaryFramesAreDecodedAsJson() {
        val worker = ServerSide()
        server.enqueue(MockResponse().withWebSocketUpgrade(worker))
        val events = LinkedBlockingQueue<LiveEvent>()
        val live = session(events)
        live.connect()
        val socket = worker.awaitOpen()
        socket.send("""{"setupComplete":{}}""".encodeUtf8())
        assertEquals(LiveEvent.Ready, events.next())
        socket.send("""{"fudVoice":{"secondsRemaining":540}}""".encodeUtf8())
        assertEquals(LiveEvent.HostedStatus(540), events.next())
        live.close()
    }

    @Test
    fun outOfMinutesNoticeThenClose4402() {
        val worker = ServerSide()
        server.enqueue(MockResponse().withWebSocketUpgrade(worker))
        val events = LinkedBlockingQueue<LiveEvent>()
        session(events).connect()
        val socket = worker.awaitOpen()
        socket.send("""{"setupComplete":{}}""")
        assertEquals(LiveEvent.Ready, events.next())
        socket.send("""{"fudVoice":{"error":"voice_quota_exceeded"}}""")
        socket.close(HostedLiveWire.CLOSE_OUT_OF_MINUTES, "voice_quota_exceeded")
        assertEquals(LiveEvent.HostedNotice("voice_quota_exceeded"), events.next())
        val closed = events.next() as LiveEvent.Closed
        assertEquals(LiveFailure.Closed(4402, "voice_quota_exceeded"), closed.failure)
    }

    @Test
    fun sessionLimitClose4408() {
        val worker = ServerSide()
        server.enqueue(MockResponse().withWebSocketUpgrade(worker))
        val events = LinkedBlockingQueue<LiveEvent>()
        session(events).connect()
        val socket = worker.awaitOpen()
        socket.close(HostedLiveWire.CLOSE_SESSION_LIMIT, "session_limit")
        val closed = events.next() as LiveEvent.Closed
        assertEquals(4408, (closed.failure as LiveFailure.Closed).code)
    }

    @Test
    fun refusedUpgradesReportTheStatusAndWorkerCode() {
        val cases = listOf(
            401 to "invalid_user_id",
            402 to "voice_quota_exceeded",
            403 to "subscription_required",
            429 to "rate_limited",
            503 to "voice_unavailable"
        )
        for ((status, code) in cases) {
            server.enqueue(MockResponse().setResponseCode(status).setBody("""{"error":"$code"}"""))
            val events = LinkedBlockingQueue<LiveEvent>()
            session(events).connect()
            val closed = events.next() as LiveEvent.Closed
            assertEquals("HTTP $status", LiveFailure.Refused(status, code), closed.failure)
        }
    }

    @Test
    fun goAwayMovesToANewConnectionWithTheResumptionHandle() {
        val first = ServerSide()
        val second = ServerSide()
        server.enqueue(MockResponse().withWebSocketUpgrade(first))
        server.enqueue(MockResponse().withWebSocketUpgrade(second))
        val events = LinkedBlockingQueue<LiveEvent>()
        val live = session(events)
        live.connect()

        val firstSocket = first.awaitOpen()
        first.next()
        firstSocket.send("""{"setupComplete":{}}""")
        assertEquals(LiveEvent.Ready, events.next())
        firstSocket.send("""{"sessionResumptionUpdate":{"newHandle":"resume-7","resumable":true}}""")
        firstSocket.send("""{"goAway":{"timeLeft":"5s"}}""")

        second.awaitOpen()
        val setup = Json.parseToJsonElement(second.next()).jsonObject["setup"]!!.jsonObject
        assertEquals("resume-7", setup["sessionResumption"]!!.jsonObject["handle"]!!.jsonPrimitive.content)
        // The retired connection's close is not reported as the session ending.
        assertNull(events.poll(500, TimeUnit.MILLISECONDS))
        live.close()
    }

    @Test
    fun aReconnectedSocketMustAlsoAcknowledgeSetupBeforeTheDeadline() {
        val first = ServerSide()
        val second = ServerSide()
        server.enqueue(MockResponse().withWebSocketUpgrade(first))
        server.enqueue(MockResponse().withWebSocketUpgrade(second))
        val events = LinkedBlockingQueue<LiveEvent>()
        val live = LiveSession(hostedConfig(), client = client, setupTimeoutMillis = 2_000) { events.add(it) }
        live.connect()
        val firstSocket = first.awaitOpen()
        first.next()
        firstSocket.send("""{"setupComplete":{}}""")
        assertEquals(LiveEvent.Ready, events.next())
        firstSocket.send("""{"sessionResumptionUpdate":{"newHandle":"resume-7","resumable":true}}""")
        firstSocket.send("""{"goAway":{"timeLeft":"5s"}}""")
        second.awaitOpen()
        second.next()
        live.sendAudio(byteArrayOf(1, 2))
        val event = events.next() as LiveEvent.Closed
        assertEquals(LiveFailure.Network("setup_timeout"), event.failure)
        assertNull("Audio never crosses an unacknowledged resumed session", second.messages.poll(100, TimeUnit.MILLISECONDS))
        live.close()
    }

    @Test
    fun openAIWaitsForSessionUpdateAcknowledgementBeforeAudio() {
        val provider = ServerSide()
        server.enqueue(MockResponse().withWebSocketUpgrade(provider))
        val events = LinkedBlockingQueue<LiveEvent>()
        val config = LiveSessionConfig(
            provider = LiveProvider.OPENAI,
            model = "gpt-realtime-2.1-mini",
            voice = "marin",
            instructions = "Be brief.",
            apiKey = "sk-test"
        )
        val wire = object : OpenAIRealtimeWire() {
            override val endpoint: String = server.url("/v1/realtime").toString()
        }
        val live = LiveSession(config, wire, client) { events.add(it) }
        live.connect()
        live.sendAudio(byteArrayOf(1, 2))

        val request = server.takeRequest(5, TimeUnit.SECONDS)!!
        assertEquals("Bearer sk-test", request.getHeader("Authorization"))
        assertEquals("gpt-realtime-2.1-mini", request.requestUrl!!.queryParameter("model"))
        val socket = provider.awaitOpen()
        assertEquals("session.update", Json.parseToJsonElement(provider.next()).jsonObject["type"]!!.jsonPrimitive.content)
        assertEquals("session.update", Json.parseToJsonElement(provider.next()).jsonObject["type"]!!.jsonPrimitive.content)
        assertNull("Audio waits for the configuration to be accepted", provider.messages.poll(300, TimeUnit.MILLISECONDS))
        assertNull("Connecting is not yet a listening session", events.poll(300, TimeUnit.MILLISECONDS))
        socket.send("""{"type":"session.updated","session":{}}""")
        assertEquals(LiveEvent.Ready, events.next())
        assertEquals("input_audio_buffer.append", Json.parseToJsonElement(provider.next()).jsonObject["type"]!!.jsonPrimitive.content)
        socket.send("""{"type":"session.updated","session":{}}""")
        assertNull("A transcription-only update must not restart the session", events.poll(300, TimeUnit.MILLISECONDS))
        live.close()
    }

    @Test
    fun queuedAudioKeepsOnlyTheLatestSeconds() {
        val worker = ServerSide()
        server.enqueue(MockResponse().withWebSocketUpgrade(worker))
        val events = LinkedBlockingQueue<LiveEvent>()
        val live = session(events)
        live.connect()
        val chunk = ByteArray(LiveSession.MAX_QUEUED_AUDIO_BYTES / 4)
        repeat(10) { live.sendAudio(chunk) }
        live.sendText("[Fud AI app] note", respond = true)
        val socket = worker.awaitOpen()
        worker.next()
        socket.send("""{"setupComplete":{}}""")
        assertEquals(LiveEvent.Ready, events.next())
        val flushed = generateSequence { worker.messages.poll(500, TimeUnit.MILLISECONDS) }.toList()
        assertEquals(4, flushed.count { it.contains("realtimeInput") })
        assertNotNull("Non-audio messages are never dropped", flushed.firstOrNull { it.contains("clientContent") })
        live.close()
    }

    @Test
    fun relayClosesBecomeNotices() {
        assertEquals(VoiceNotice.OutOfMinutes, closeNotice(4402, "voice_quota_exceeded", hosted = true))
        assertEquals(VoiceNotice.OutOfMinutes, closeNotice(1000, "voice_quota_exceeded", hosted = true))
        assertEquals(VoiceNotice.SessionLimit, closeNotice(4408, null, hosted = true))
        assertEquals(VoiceNotice.RateLimited, closeNotice(1008, "rate_limited", hosted = true))
        assertEquals(VoiceNotice.VoiceUnavailable, closeNotice(1011, "upstream_error", hosted = true))
        assertEquals(VoiceNotice.VoiceUnavailable, closeNotice(1008, "invalid_setup", hosted = true))
        assertEquals(VoiceNotice.VoiceUnavailable, closeNotice(1008, "something_new", hosted = true))
        assertEquals(VoiceNotice.ConnectionLost, closeNotice(1000, null, hosted = true))
        // Own-key closes keep the provider's reason (handled by the caller).
        assertNull(closeNotice(1008, null, hosted = false))
    }

    @Test
    fun workerErrorCodeIsReadFromJsonBodies() {
        assertEquals("voice_quota_exceeded", LiveSession.errorCode("""{"error":"voice_quota_exceeded","quota":{}}"""))
        assertNull(LiveSession.errorCode("<html>busy</html>"))
    }
}
