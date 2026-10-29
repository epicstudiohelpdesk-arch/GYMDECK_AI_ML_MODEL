package com.apoorvdarshan.calorietracker.services.voice

import android.util.Log

/**
 * Logcat for the voice assistant. Messages never carry keys, transcripts or tool data.
 * The JVM unit tests run against the stub android.jar, where `Log` throws; logging must
 * never change what the engine does, so failures to log are ignored.
 */
internal object VoiceLog {
    fun info(tag: String, message: String) {
        runCatching { Log.i(tag, message) }
    }

    fun warn(tag: String, message: String, error: Throwable? = null) {
        // Provider/HTTP exceptions can include a request, transcript or credential in
        // their message/cause. Only the exception type is useful diagnostic metadata.
        runCatching { Log.w(tag, message + (error?.let { " (${it.javaClass.simpleName})" } ?: "")) }
    }
}
