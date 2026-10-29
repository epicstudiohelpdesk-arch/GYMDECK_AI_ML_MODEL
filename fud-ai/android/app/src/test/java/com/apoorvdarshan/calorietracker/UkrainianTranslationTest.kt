package com.apoorvdarshan.calorietracker

import com.apoorvdarshan.calorietracker.services.voice.RepoFiles
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import javax.xml.parsers.DocumentBuilderFactory

/** Ukrainian resources must not contain text copied from the Russian translation (#507). */
class UkrainianTranslationTest {
    @Test
    fun ukrainianStringsContainNoRussian() {
        val files = RepoFiles.find("src/main/res/values-uk").listFiles { file -> file.extension == "xml" }.orEmpty()
        val problems = mutableListOf<String>()
        var checked = 0
        for (file in files) {
            val document = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file)
            // <string> values, plus <item>s of plurals and string arrays.
            for (tag in listOf("string", "item")) {
                val nodes = document.getElementsByTagName(tag)
                for (index in 0 until nodes.length) {
                    val text = nodes.item(index).textContent
                    checked++
                    val lowered = text.lowercase()
                    val words = lowered.split(Regex("[^\\p{L}]+")).filter { it in RUSSIAN_ONLY_WORDS }
                    if (lowered.any { it in "ыэъё" } || words.isNotEmpty()) {
                        problems += "${file.name}: $text $words"
                    }
                }
            }
        }
        assertTrue("only $checked uk strings found", checked > 1_500)
        assertEquals(emptyList<String>(), problems)
    }

    private companion object {
        /** Russian words that are never Ukrainian; same list as LocalizationCatalogTests on iOS. */
        val RUSSIAN_ONLY_WORDS = setOf(
            "ошибка", "ошибки", "пропустить", "будет", "будут", "добавить", "добавлено", "изменить",
            "изменения", "спасибо", "отправить", "поздравляем", "разрешить", "запретить", "дней", "цель",
            "цели", "еда", "еду", "вес", "веса", "что", "это", "чтобы", "сейчас", "нет", "или", "тоже",
            "также", "только", "можно", "нужно", "сначала", "затем", "осталось", "начнём", "записать",
            "сбросить", "получить", "пользователя", "уведомления", "язык", "медленно", "привет",
            "понятно", "проверить", "всего", "единица", "вручную", "минимум", "анализ",
        )
    }
}
