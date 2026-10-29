package com.apoorvdarshan.calorietracker.services.voice

import com.apoorvdarshan.calorietracker.AppContainer
import com.apoorvdarshan.calorietracker.data.VoiceAssistantPreferences
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/** Reads only routing preferences and credentials, never the assistant's profile/history/tools. */
fun createVoicePreviewController(container: AppContainer): VoicePreviewController = VoicePreviewController(
    scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
    prepare = { appLanguage ->
        val prefs = container.prefs.voiceAssistantPreferences.first()
        val selectedAi = container.prefs.selectedAIProvider.first()
        val entitlement = withTimeoutOrNull(2_000) {
            container.billing.entitlement.first { it.loaded }
        } ?: container.billing.entitlement.value
        val keys = withContext(Dispatchers.IO) {
            LiveProvider.ownKeyProviders.associateWith { provider ->
                provider.aiProvider?.let { container.keyStore.apiKey(it) }?.trim()?.takeIf { it.isNotEmpty() }
            }
        }
        val access = VoiceProviderResolver.resolve(prefs.choice, selectedAi, { keys[it] != null }, entitlement.isEntitled)
        val provider = (access as? VoiceAccess.Ready)?.provider ?: error("Voice access unavailable")
        val userId = if (provider == LiveProvider.HOSTED) {
            container.billing.appUserId()?.takeIf { it.isNotBlank() } ?: error("Voice access unavailable")
        } else null
        voicePreviewConfig(provider, prefs, appLanguage, keys[provider], userId)
    },
    conversationActive = { container.voiceAssistant.isActive },
    createAudio = { LiveAudioEngine(container.appContext) },
    createConnection = { config, onEvent ->
        val session = LiveSession(config, onEvent = onEvent)
        object : VoicePreviewConnection {
            override fun connect() = session.connect()
            override fun sendSample(text: String) = session.sendText(text)
            override fun close() = session.close()
        }
    }
)

internal fun voicePreviewConfig(
    provider: LiveProvider,
    prefs: VoiceAssistantPreferences,
    appLanguage: String,
    apiKey: String?,
    hostedUserId: String?
): LiveSessionConfig {
    val language = when (prefs.language) {
        VoiceAssistantPreferences.LANGUAGE_AUTOMATIC, VoiceAssistantPreferences.LANGUAGE_APP -> appLanguage
        else -> prefs.language
    }
    return LiveSessionConfig(
        provider = provider,
        model = provider.supportedModelOrDefault(prefs.model(provider)),
        voice = provider.supportedVoiceOrDefault(prefs.voice(provider)),
        instructions = "Read the user's sample aloud once, translating it into the language with tag $language. " +
            "Speak only that sample. Do not add an introduction, explanation or follow-up question.",
        tools = emptyList(),
        apiKey = if (provider.usesOwnKey) apiKey else null,
        hostedUserId = if (provider == LiveProvider.HOSTED) hostedUserId else null
    )
}
