package com.apoorvdarshan.calorietracker.data

import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.core.preferencesOf
import androidx.datastore.preferences.core.stringPreferencesKey
import com.apoorvdarshan.calorietracker.models.AppLanguage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VoiceAssistantPreferencesTest {
    private val language = stringPreferencesKey("voiceAssistantLanguage")
    private val autoCapture = booleanPreferencesKey("voiceAssistantAutoCapture")

    @Test
    fun nothingSavedRepliesInTheAppLanguageWithAutoCaptureOn() {
        val prefs = PreferencesStore.readVoiceAssistantPreferences(emptyPreferences())
        assertEquals(VoiceAssistantPreferences.LANGUAGE_APP, prefs.language)
        assertTrue(prefs.autoCapture)
        assertEquals(VoiceAssistantPreferences(), prefs)
    }

    @Test
    fun savedChoicesAreKept() {
        val automatic = PreferencesStore.readVoiceAssistantPreferences(
            preferencesOf(language to VoiceAssistantPreferences.LANGUAGE_AUTOMATIC, autoCapture to false)
        )
        assertEquals(VoiceAssistantPreferences.LANGUAGE_AUTOMATIC, automatic.language)
        assertFalse(automatic.autoCapture)
        assertEquals("es", PreferencesStore.readVoiceAssistantPreferences(preferencesOf(language to "es")).language)
    }

    @Test
    fun appLanguageIsTheLanguageTheAppShows() {
        // Finnish has no translation, so the app shows English.
        assertEquals("en", AppLanguage.shownTag(null, listOf("fi-FI")))
        assertEquals("de", AppLanguage.shownTag(null, listOf("fi-FI", "de-DE")))
        assertEquals("tr", AppLanguage.shownTag(null, listOf("tr-TR")))
        assertEquals("pt-BR", AppLanguage.shownTag(null, listOf("pt-BR")))
        assertEquals("zh-CN", AppLanguage.shownTag(null, listOf("zh-CN")))
        assertEquals("ja", AppLanguage.shownTag("ja", listOf("fi-FI")))
        assertEquals("en", AppLanguage.shownTag(null, emptyList()))
    }
}
