package com.apoorvdarshan.calorietracker.services.hosted

import com.apoorvdarshan.calorietracker.services.SecureHttpClient
import com.apoorvdarshan.calorietracker.services.ai.AiError
import com.apoorvdarshan.calorietracker.services.ai.AiErrorKind
import com.apoorvdarshan.calorietracker.services.ai.BodyReadException
import com.apoorvdarshan.calorietracker.services.ai.awaitBody
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import java.io.File
import java.io.IOException
import java.util.Base64
import java.util.concurrent.TimeUnit

/**
 * Live voice time from `GET /quota` (`voice: {month, secondsUsed, secondsLimit, creditBank}`).
 * Sessions are metered in 15-second blocks: the monthly allowance first, then one credit
 * per block.
 */
data class HostedVoiceQuota(
    val month: String?,
    val secondsUsed: Int,
    val secondsLimit: Int,
    val creditBank: Int
) {
    val allowanceSecondsLeft: Int get() = (secondsLimit - secondsUsed).coerceAtLeast(0)
    val creditSeconds: Int get() = creditBank.coerceAtLeast(0) * SECONDS_PER_CREDIT
    val totalSecondsLeft: Int get() = allowanceSecondsLeft + creditSeconds

    companion object {
        const val SECONDS_PER_CREDIT = 15

        /** Reads `voice` from the top level or from inside `quota`; null when absent or malformed. */
        fun fromQuotaResponse(raw: String): HostedVoiceQuota? {
            val root = runCatching { Json.parseToJsonElement(raw).jsonObject }.getOrNull() ?: return null
            val voice = (root["voice"] as? JsonObject)
                ?: ((root["quota"] as? JsonObject)?.get("voice") as? JsonObject)
                ?: return null
            fun int(name: String): Int? = (voice[name] as? JsonPrimitive)?.content?.toDoubleOrNull()?.toInt()
            val limit = int("secondsLimit") ?: return null
            return HostedVoiceQuota(
                month = (voice["month"] as? JsonPrimitive)?.takeIf { it.isString }?.content,
                secondsUsed = (int("secondsUsed") ?: 0).coerceAtLeast(0),
                secondsLimit = limit.coerceAtLeast(0),
                creditBank = (int("creditBank") ?: 0).coerceAtLeast(0)
            )
        }
    }
}

/**
 * Client for the Fud AI hosted proxy (`web/hosted-ai-api.ts`). The only identity
 * sent is the RevenueCat anonymous app user id; the Worker verifies the plan with
 * RevenueCat and meters every call against its ledger. Each response's
 * `X-Fud-Quota-*` headers (and an error body's `quota`) refresh [quota].
 */
class HostedAiClient(
    private val userId: () -> String?,
    private val quota: HostedQuotaStore,
    private val client: OkHttpClient = defaultClient,
    private val baseUrl: String = HostedAiConstants.BASE_URL,
    private val retryDelayMillis: Long = 1_500
) {

    /** Single-shot prompt (food, label, workout, goals, …); returns the model text. */
    suspend fun generate(
        prompt: String,
        jpegImages: List<ByteArray>,
        systemInstruction: String?,
        jsonResponse: Boolean
    ): String {
        if (jpegImages.size > HostedAiConstants.MAX_IMAGES) {
            throw AiError.Hosted(AiErrorKind.HOSTED_TOO_MANY_IMAGES, "too_many_images")
        }
        val body = buildJsonObject {
            put("prompt", prompt)
            putJsonArray("images") { jpegImages.forEach { add(base64(it)) } }
            systemInstruction?.takeIf { it.isNotBlank() }?.let { put("systemInstruction", it) }
            if (jsonResponse) put("responseMimeType", "application/json")
        }
        val response = post("generate", body.toString())
        return stringField(response, "text")?.takeIf { it.isNotBlank() } ?: throw AiError.InvalidResponse
    }

    /** Coach tool-calling round: forwards a Gemini `generateContent` body (JSON), returns raw Gemini JSON. */
    suspend fun gemini(requestBodyJson: String): String =
        post("gemini", """{"requestBody":$requestBodyJson}""")

    /** Deepgram transcription of a recorded clip (Android records 16 kHz mono WAV). */
    suspend fun transcribe(audio: File, mimeType: String, language: String?): String {
        val bytes = withContext(Dispatchers.IO) { audio.readBytes() }
        val body = buildJsonObject {
            put("audio", base64(bytes))
            put("mimeType", mimeType)
            language?.takeIf { LANGUAGE_PATTERN.matches(it) }?.let { put("language", it) }
        }
        val response = post("transcribe", body.toString())
        return stringField(response, "text").orEmpty().trim()
    }

    /** Current ledger state; `refresh` makes the Worker re-check the plan with RevenueCat. */
    suspend fun fetchQuota(refresh: Boolean): HostedQuotaSnapshot {
        val path = if (refresh) "quota?refresh=1" else "quota"
        val response = execute(applyQuota = false) { builder(path).get().build() }
        return objectField(response, "quota")?.let { HostedQuotaSnapshot.decode(it.toString()) }
            ?: throw AiError.InvalidResponse
    }

    /**
     * Voice minutes for the live assistant: `GET /quota` also reports `voice`. Null when the
     * Worker does not send it yet. The action quota in the same response is applied too.
     */
    suspend fun fetchVoiceQuota(): HostedVoiceQuota? {
        val sequence = quota.nextRequestSequence()
        val response = execute(applyQuota = false) { builder("quota").get().build() }
        objectField(response, "quota")?.let { HostedQuotaSnapshot.decode(it.toString()) }?.let { quota.apply(it, sequence) }
        return HostedVoiceQuota.fromQuotaResponse(response)
    }

    private suspend fun post(path: String, payload: String): String =
        execute(applyQuota = true) { builder(path).post(payload.toRequestBody(JSON_MEDIA)).build() }

    private fun builder(path: String): Request.Builder {
        val id = userId()?.takeIf { it.isNotBlank() }
            // Billing unavailable (no SDK key): there can be no verified plan.
            ?: throw AiError.Hosted(AiErrorKind.HOSTED_SUBSCRIPTION_REQUIRED, "billing_unavailable")
        return Request.Builder()
            .url("$baseUrl/$path")
            .header(HostedAiConstants.USER_ID_HEADER, id)
            .header("Accept", "application/json")
    }

    private sealed interface Attempt {
        data class Success(val body: String) : Attempt
        data class Failure(val error: AiError.Hosted, val retryable: Boolean) : Attempt
    }

    private suspend fun execute(applyQuota: Boolean, request: () -> Request): String {
        var attempt = 0
        while (true) {
            val sequence = quota.nextRequestSequence()
            // Read on OkHttp's thread: the hosted Coach, food and speech calls start on the main dispatcher.
            val response = try {
                client.newCall(request()).awaitBody()
            } catch (io: IOException) {
                // The Worker charges once it sends the headers, so keep the quota they report
                // even when the body was cut off afterwards.
                if (applyQuota && io is BodyReadException) {
                    HostedQuotaSnapshot.fromHeaders { name -> io.headers[name] }?.let { s -> quota.apply(s, sequence) }
                }
                throw AiError.Network(io)
            }
            val outcome = response.let {
                if (applyQuota) {
                    HostedQuotaSnapshot.fromHeaders { name -> it.header(name) }?.let { s -> quota.apply(s, sequence) }
                }
                val body = it.body
                if (it.isSuccessful) {
                    Attempt.Success(body)
                } else {
                    objectField(body, "quota")
                        ?.let { q -> HostedQuotaSnapshot.decode(q.toString()) }
                        ?.let { s -> quota.apply(s, sequence) }
                    val code = stringField(body, "error")?.takeIf { c -> c.isNotEmpty() }
                    // These 503s never reach the ledger (or are refunded), so one retry is free.
                    val retryable = it.code == 503 && code in RETRYABLE_CODES
                    Attempt.Failure(errorFor(it.code, code), retryable)
                }
            }
            when (outcome) {
                is Attempt.Success -> return outcome.body
                is Attempt.Failure -> {
                    if (!outcome.retryable || attempt > 0) throw outcome.error
                    attempt += 1
                    delay(retryDelayMillis)
                }
            }
        }
    }

    companion object {
        private val JSON_MEDIA = "application/json; charset=utf-8".toMediaType()
        private val LANGUAGE_PATTERN = Regex("^[a-z]{2,3}(-[A-Za-z0-9]{2,8})?$")
        private val RETRYABLE_CODES = setOf("upstream_unavailable", "entitlement_unavailable")
        private val TOO_LARGE_CODES = setOf(
            "image_too_large", "audio_too_large", "body_too_large", "prompt_too_long", "system_instruction_too_long"
        )

        internal fun errorFor(status: Int, code: String?): AiError.Hosted {
            val kind = when {
                status == 401 -> AiErrorKind.HOSTED_UNAUTHORIZED
                status == 402 -> AiErrorKind.HOSTED_QUOTA_EXCEEDED
                status == 403 && code == "subscription_required" -> AiErrorKind.HOSTED_SUBSCRIPTION_REQUIRED
                status == 429 -> AiErrorKind.HOSTED_RATE_LIMITED
                code == "too_many_images" -> AiErrorKind.HOSTED_TOO_MANY_IMAGES
                code == "audio_too_long" -> AiErrorKind.HOSTED_AUDIO_TOO_LONG
                status == 413 || code in TOO_LARGE_CODES -> AiErrorKind.HOSTED_TOO_LARGE
                status in 500..599 -> AiErrorKind.HOSTED_UNAVAILABLE
                status == 400 -> AiErrorKind.HOSTED_REJECTED
                else -> AiErrorKind.HOSTED_FAILED
            }
            return AiError.Hosted(kind, code, status)
        }

        private fun base64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)

        private fun parseObject(raw: String): JsonObject? =
            runCatching { Json.parseToJsonElement(raw).jsonObject }.getOrNull()

        private fun stringField(raw: String, name: String): String? =
            (parseObject(raw)?.get(name) as? JsonPrimitive)?.takeIf { it.isString }?.content

        private fun objectField(raw: String, name: String): JsonObject? =
            runCatching { parseObject(raw)?.get(name)?.jsonObject }.getOrNull()

        val defaultClient: OkHttpClient by lazy {
            SecureHttpClient.builder()
                .connectTimeout(15, TimeUnit.SECONDS)
                // Worker: ≤8 s RevenueCat check + 30 s upstream, plus photo/audio upload.
                .callTimeout(90, TimeUnit.SECONDS)
                .readTimeout(60, TimeUnit.SECONDS)
                .writeTimeout(60, TimeUnit.SECONDS)
                .build()
        }
    }
}
