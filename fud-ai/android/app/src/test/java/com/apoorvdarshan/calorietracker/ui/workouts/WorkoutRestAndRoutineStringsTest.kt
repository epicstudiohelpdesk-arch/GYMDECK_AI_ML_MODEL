package com.apoorvdarshan.calorietracker.ui.workouts

import com.apoorvdarshan.calorietracker.services.voice.RepoFiles
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The rest timer and routines (#433) ship in English plus all 18 app languages. */
class WorkoutRestAndRoutineStringsTest {
    private val files = listOf("workout_rest_timer.xml", "workout_routines.xml")
    private val languageFolders = listOf(
        "values-ar", "values-az", "values-cs", "values-de", "values-es", "values-fr", "values-hi",
        "values-it", "values-ja", "values-ko", "values-nl", "values-pl", "values-pt-rBR", "values-ro",
        "values-ru", "values-tr", "values-uk", "values-zh-rCN"
    )

    private fun strings(file: File): Map<String, String> =
        Regex("<string name=\"([a-z0-9_]+)\">(.*?)</string>")
            .findAll(file.readText())
            .associate { it.groupValues[1] to it.groupValues[2] }

    private fun placeholders(text: String): List<String> =
        Regex("%\\d\\$[sd]").findAll(text).map { it.value }.toList()

    @Test
    fun everyLanguageTranslatesEveryStringWithTheSamePlaceholders() {
        val res = RepoFiles.find("src/main/res")
        for (name in files) {
            val english = strings(File(res, "values/$name"))
            assertTrue(name, english.isNotEmpty())
            for (folder in languageFolders) {
                val translated = strings(File(res, "$folder/$name"))
                assertEquals("$folder/$name keys", english.keys, translated.keys)
                for ((key, text) in english) {
                    val value = translated.getValue(key)
                    assertTrue("$folder/$name $key is empty", value.isNotBlank())
                    assertEquals("$folder/$name $key placeholders", placeholders(text), placeholders(value))
                    // An unescaped apostrophe or quote breaks or silently changes Android strings.
                    assertTrue("$folder/$name $key: $value", !Regex("(?<!\\\\)['\"]").containsMatchIn(value))
                }
            }
        }
    }
}
