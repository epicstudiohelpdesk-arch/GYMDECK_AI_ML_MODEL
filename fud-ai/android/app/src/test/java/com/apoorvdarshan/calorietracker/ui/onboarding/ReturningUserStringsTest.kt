package com.apoorvdarshan.calorietracker.ui.onboarding

import com.apoorvdarshan.calorietracker.services.voice.RepoFiles
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/** The Welcome back screen ships in English plus all 18 app languages. */
class ReturningUserStringsTest {
    private val languageFolders = listOf(
        "values-ar", "values-az", "values-cs", "values-de", "values-es", "values-fr", "values-hi",
        "values-it", "values-ja", "values-ko", "values-nl", "values-pl", "values-pt-rBR", "values-ro",
        "values-ru", "values-tr", "values-uk", "values-zh-rCN"
    )

    /** Strings by name, and plurals as one entry per quantity ("name[other]"). */
    private fun entries(file: File): Map<String, String> {
        val root = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file).documentElement
        val result = mutableMapOf<String, String>()
        val children = root.childNodes
        for (index in 0 until children.length) {
            val element = children.item(index) as? Element ?: continue
            val name = element.getAttribute("name")
            when (element.tagName) {
                "string" -> result[name] = element.textContent
                "plurals" -> {
                    val items = element.getElementsByTagName("item")
                    for (item in 0 until items.length) {
                        val quantity = (items.item(item) as Element).getAttribute("quantity")
                        result["$name[$quantity]"] = items.item(item).textContent
                    }
                }
            }
        }
        return result
    }

    private fun placeholders(text: String): List<String> =
        Regex("%\\d\\$[sd]").findAll(text).map { it.value }.toList()

    @Test
    fun everyLanguageTranslatesEveryStringWithTheSamePlaceholders() {
        val res = RepoFiles.find("src/main/res")
        val english = entries(File(res, "values/returning_user.xml"))
        val englishStrings = english.filterKeys { '[' !in it }
        val englishPlurals = english.keys.filter { '[' in it }.map { it.substringBefore('[') }.toSet()
        assertTrue(englishStrings.size > 20)
        for (folder in languageFolders) {
            val translated = entries(File(res, "$folder/returning_user.xml"))
            assertEquals("$folder strings", englishStrings.keys, translated.keys.filter { '[' !in it }.toSet())
            for ((key, text) in englishStrings) {
                val value = translated.getValue(key)
                assertTrue("$folder $key is empty", value.isNotBlank())
                assertEquals("$folder $key placeholders", placeholders(text), placeholders(value))
            }
            for (plural in englishPlurals) {
                val forms = translated.filterKeys { it.startsWith("$plural[") }
                assertTrue("$folder $plural has no other form", "$plural[other]" in forms)
                for ((key, value) in forms) {
                    assertEquals("$folder $key placeholders", listOf("%1\$d"), placeholders(value))
                }
            }
            // The brand name is never translated.
            assertTrue("$folder keeps Fud AI", translated.getValue("returning_entry").contains("Fud AI"))
        }
    }

    @Test
    fun noUnescapedApostrophesOrQuotes() {
        val res = RepoFiles.find("src/main/res")
        for (folder in listOf("values") + languageFolders) {
            val raw = File(res, "$folder/returning_user.xml").readText()
            for (match in Regex(">([^<]*)</").findAll(raw)) {
                val value = match.groupValues[1]
                // An unescaped apostrophe or quote breaks or silently changes Android strings.
                assertTrue("$folder: $value", !Regex("(?<!\\\\)['\"]").containsMatchIn(value))
            }
        }
    }
}
