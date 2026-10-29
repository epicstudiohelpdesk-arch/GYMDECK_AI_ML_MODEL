package com.apoorvdarshan.calorietracker.services.ai

import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Headers
import okhttp3.Response
import org.json.JSONObject
import java.io.IOException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Retries 503/429/529 with exponential backoff (same as iOS).
 * On final failure, throws [AiError.Api] with a user-friendly message.
 * The caller supplies a factory that builds a fresh [Call] per attempt
 * because OkHttp [Call] instances can only be executed once.
 */
object RetryPolicy {
    /** Default 1s/2s/4s backoff: up to four attempts. Used by the coach and background jobs. */
    val defaultDelays = longArrayOf(1_000, 2_000, 4_000)

    /**
     * Interactive food logging keeps the user staring at the analyzing overlay, so it only gets
     * one quick retry before surfacing the overload/rate-limit error and letting them decide.
     */
    val interactiveDelays = longArrayOf(1_500)

    suspend fun execute(delays: LongArray = defaultDelays, callFactory: () -> Call): String {
        var lastKind = AiErrorKind.GENERIC
        for (attempt in 0..delays.size) {
            // The body is read on OkHttp's thread: the coach calls this from the main dispatcher.
            val response = try {
                callFactory().awaitBody()
            } catch (io: IOException) {
                throw AiError.Network(io)
            }

            val bodyStr = response.body
            val code = response.code

            if (response.isSuccessful) return bodyStr

            val raw = parseErrorMessage(bodyStr)?.takeIf { it.isNotEmpty() } ?: "HTTP $code"
            lastKind = AiErrorKind.fromResponse(code, raw + "\n" + bodyStr)

            val retryable = code == 503 || code == 529 || code == 429
            if (retryable && attempt < delays.size) {
                delay(delays[attempt])
                continue
            }
            throw AiError.Failure(lastKind)
        }
        throw AiError.Failure(lastKind)
    }

    private fun parseErrorMessage(body: String): String? {
        if (body.isBlank()) return null
        return runCatching {
            val json = JSONObject(body)
            when (val errorNode = json.opt("error")) {
                is JSONObject -> errorNode.optString("message").takeIf { it.isNotEmpty() }
                is String -> errorNode.takeIf { it.isNotEmpty() }
                else -> null
            }
        }.getOrNull()
    }
}

/**
 * Cooperative cancellation: cancelling the coroutine (e.g. the analyzing overlay's Cancel button)
 * also cancels the underlying OkHttp call instead of letting it run to completion in the background.
 * The body is still unread when this returns, so only call it off the main thread; [awaitBody]
 * is main-safe.
 */
internal suspend fun Call.await(): Response = suspendCancellableCoroutine { cont ->
    enqueue(object : okhttp3.Callback {
        override fun onFailure(call: Call, e: IOException) {
            if (cont.isActive) cont.resumeWithException(e)
        }

        override fun onResponse(call: Call, response: Response) {
            if (cont.isActive) cont.resume(response) else response.close()
        }
    })
    cont.invokeOnCancellation { cancel() }
}

/** A response whose body [awaitBody] has already read to the end and closed. */
internal class BufferedResponse(val code: Int, val headers: Headers, val body: String) {
    val isSuccessful: Boolean get() = code in 200..299

    fun header(name: String): String? = headers[name]
}

/**
 * A body read that failed after the status line and headers had arrived. Callers that act on
 * response headers (the hosted quota) can still read them from here.
 */
internal class BodyReadException(
    val code: Int,
    val headers: Headers,
    cause: IOException
) : IOException(cause.message, cause)

/**
 * Like [await], but reads the whole body on OkHttp's callback thread before resuming, so a caller
 * on the main dispatcher never touches the socket (Android throws NetworkOnMainThreadException
 * when a body read has to wait on the network). The coroutine stays suspended until the body is
 * read, so cancelling it during a slow body still cancels the call.
 */
internal suspend fun Call.awaitBody(): BufferedResponse = suspendCancellableCoroutine { cont ->
    enqueue(object : okhttp3.Callback {
        override fun onFailure(call: Call, e: IOException) {
            if (cont.isActive) cont.resumeWithException(e)
        }

        override fun onResponse(call: Call, response: Response) {
            if (!cont.isActive) {
                response.close()
                return
            }
            // Anything thrown out of this callback would crash OkHttp's thread instead of
            // reaching the caller, so failures are handed to the continuation.
            val result = runCatching {
                response.use {
                    val body = try {
                        it.body.string()
                    } catch (e: IOException) {
                        throw BodyReadException(it.code, it.headers, e)
                    }
                    BufferedResponse(it.code, it.headers, body)
                }
            }
            if (cont.isActive) cont.resumeWith(result)
        }
    })
    cont.invokeOnCancellation { cancel() }
}
