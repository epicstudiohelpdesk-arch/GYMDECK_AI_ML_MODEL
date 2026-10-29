package com.apoorvdarshan.calorietracker.models

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Fixtures match iOS IngredientLabelParserTests; keep both in sync. */
class IngredientLabelParserTest {
    @Test
    fun splitsTopLevelEntriesAndTrimsTheFinalPeriod() {
        assertEquals(
            listOf(
                "Sugar", "palm oil", "hazelnuts 13%", "skimmed milk powder 8.7%",
                "emulsifier: lecithins (soya)", "vanillin"
            ),
            texts("Sugar, palm oil, hazelnuts 13%, skimmed milk powder 8.7%, emulsifier: lecithins (soya), vanillin.")
        )
    }

    @Test
    fun keepsBracketedSubIngredientsTogether() {
        assertEquals(listOf("Vegetable oil (palm, sunflower)", "salt"), texts("Vegetable oil (palm, sunflower), salt"))
        assertEquals(
            listOf("Chocolate (sugar, cocoa butter (from beans), milk)", "salt"),
            texts("Chocolate (sugar, cocoa butter (from beans), milk), salt")
        )
        assertEquals(
            listOf("Water", "sugar [cane, beet]", "acid: citric acid"),
            texts("Water; sugar [cane, beet]; acid: citric acid")
        )
        assertEquals(listOf("小麦粉（国内製造、米国産）", "砂糖", "食塩"), texts("小麦粉（国内製造、米国産）、砂糖、食塩"))
    }

    @Test
    fun splitsOnArabicCommasAndSemicolons() {
        assertEquals(listOf("سكر", "ملح", "حليب"), texts("المكونات: سكر، ملح؛ حليب"))
        val label = IngredientLabelParser.parse("سكر، ملح. قد يحتوي على مكسرات.")
        assertEquals(listOf("سكر", "ملح"), label.items.map { it.text })
        assertEquals(listOf("قد يحتوي على مكسرات."), label.notes.map { it.text })
    }

    @Test
    fun keepsDecimalCommasInsidePercentages() {
        assertEquals(listOf("Zucker", "Magermilchpulver 8,7%", "Salz"), texts("Zucker, Magermilchpulver 8,7%, Salz"))
    }

    @Test
    fun stripsIngredientHeadingsButNotOtherLeadingColons() {
        assertEquals(listOf("oats", "salt"), texts("Ingredients: oats, salt."))
        assertEquals(listOf("Zucker", "Salz"), texts("Zutaten: Zucker, Salz"))
        assertEquals(listOf("小麦粉", "砂糖"), texts("原材料名：小麦粉、砂糖"))
        assertEquals(listOf("şeker", "tuz"), texts("İçindekiler: şeker, tuz"))
        assertEquals(listOf("cukier", "sól"), texts("Składniki: cukier, sól"))
        assertEquals(listOf("Emulsifier: soy lecithin", "sugar"), texts("Emulsifier: soy lecithin, sugar"))
    }

    @Test
    fun collapsesWhitespaceAndDropsEmptyEntries() {
        assertEquals(listOf("Sugar", "cocoa butter", "salt"), texts("Sugar,\n  cocoa   butter ,, salt ;"))
        assertEquals(listOf("Sugar", "cocoa butter", "salt"), texts("Sugar,\u00A0\u00A0cocoa\u00A0 butter, salt"))
    }

    @Test
    fun labelsThatDoNotFormAListFallBackToAParagraph() {
        assertTrue(IngredientLabelParser.items("Whole milk").isEmpty())
        assertTrue(IngredientLabelParser.items("").isEmpty())
        assertTrue(IngredientLabelParser.items("   ").isEmpty())

        val sixty = (1..60).joinToString(", ") { "item $it" }
        val sixtyOne = (1..61).joinToString(", ") { "item $it" }
        assertEquals(60, IngredientLabelParser.items(sixty).size)
        assertTrue(IngredientLabelParser.items(sixtyOne).isEmpty())
    }

    @Test
    fun paragraphFallbackKeepsTheSensitivityWarning() {
        val single = IngredientLabelParser.parse("Whole milk", sensitivities = listOf("milk"))
        assertTrue(single.items.isEmpty())
        assertEquals("Whole milk", single.paragraph?.text)
        assertEquals(true, single.paragraph?.matchesSensitivity)
        assertEquals(false, IngredientLabelParser.parse("Whole milk").paragraph?.matchesSensitivity)

        val overLimit = IngredientLabelParser.parse(
            (1..61).joinToString(", ") { "item $it" } + ", skimmed _milk_ powder",
            sensitivities = listOf("milk")
        )
        assertTrue(overLimit.items.isEmpty())
        assertEquals(true, overLimit.paragraph?.matchesSensitivity)
        assertEquals(listOf("milk"), overLimit.paragraph?.segments?.filter { it.isAllergen }?.map { it.text })

        assertNull(IngredientLabelParser.parse("   ").paragraph)
        assertNull(IngredientLabelParser.parse("Sugar, salt").paragraph)
    }

    @Test
    fun openFoodFactsAllergenMarkersBecomeEmphasizedSegments() {
        assertEquals(
            listOf(
                IngredientLabelItem.Segment("skimmed ", isAllergen = false),
                IngredientLabelItem.Segment("milk", isAllergen = true),
                IngredientLabelItem.Segment(" powder", isAllergen = false)
            ),
            IngredientLabelParser.segments("skimmed _milk_ powder")
        )
        assertEquals(
            listOf(IngredientLabelItem.Segment("sugar syrup", isAllergen = false)),
            IngredientLabelParser.segments("sugar_ syrup")
        )

        val items = IngredientLabelParser.items("Ingrédients : farine de _blé_, sel")
        assertEquals(listOf("farine de blé", "sel"), items.map { it.text })
        assertEquals(
            listOf(
                IngredientLabelItem.Segment("farine de ", isAllergen = false),
                IngredientLabelItem.Segment("blé", isAllergen = true)
            ),
            items.first().segments
        )
    }

    @Test
    fun entriesMatchingSensitivitiesAreFlagged() {
        val items = IngredientLabelParser.items(
            "Sugar, skimmed _milk_ powder, whey, hazelnuts",
            sensitivities = listOf("milk", "nuts")
        )
        assertEquals(listOf(false, true, true, true), items.map { it.matchesSensitivity })
        assertEquals(listOf(false, false), IngredientLabelParser.items("Sugar, whey").map { it.matchesSensitivity })
    }

    @Test
    fun entriesWithEitherKindOfAllergenEmphasisAreAnnounced() {
        val items = IngredientLabelParser.items(
            "Sugar, skimmed _milk_ powder, hazelnuts",
            sensitivities = listOf("nuts")
        )
        assertEquals(listOf(false, false, true), items.map { it.matchesSensitivity })
        assertEquals(listOf(false, true, true), items.map { it.announcesAllergen })
        assertEquals(true, IngredientLabelParser.parse("_Milk_").paragraph?.announcesAllergen)
        assertEquals(false, IngredientLabelParser.parse("Water").paragraph?.announcesAllergen)
    }

    @Test
    fun openFoodFactsAllergenSpansBecomeMarkers() {
        // Live Open Food Facts product 3017620422003: ingredients_text has no markers, the
        // allergens it flags are only in ingredients_text_with_allergens (with stray </span>s).
        val marked = IngredientLabelParser.markingAllergens(
            plain = "Sucre, huile de palme, NOISETTES 13%, cacao maigre 7,4%, LAIT écrémé en poudre 6,6%, " +
                "LACTOSERUM en poudre, émulsifiants: lécithines [SOJA), vanilline. Sans gluten.",
            markup = "Sucre, huile de palme, <span class=\"allergen\">NOISETTES</span> </span>13%, cacao maigre 7,4%, " +
                "<span class=\"allergen\">LAIT</span> </span>écrémé en poudre 6,6%, " +
                "<span class=\"allergen\">LACTOSERUM</span> </span>en poudre, émulsifiants: lécithines " +
                "[<span class=\"allergen\">SOJA</span>), vanilline. Sans gluten."
        )
        assertEquals(
            "Sucre, huile de palme, _NOISETTES_ 13%, cacao maigre 7,4%, _LAIT_ écrémé en poudre 6,6%, " +
                "_LACTOSERUM_ en poudre, émulsifiants: lécithines [_SOJA_), vanilline. Sans gluten.",
            marked
        )

        val label = IngredientLabelParser.parse(marked!!)
        assertEquals(
            listOf(
                "Sucre", "huile de palme", "NOISETTES 13%", "cacao maigre 7,4%", "LAIT écrémé en poudre 6,6%",
                "LACTOSERUM en poudre", "émulsifiants: lécithines [SOJA)", "vanilline"
            ),
            label.items.map { it.text }
        )
        assertEquals(
            listOf("NOISETTES", "LAIT", "LACTOSERUM", "SOJA"),
            label.items.flatMap { item -> item.segments.filter { it.isAllergen }.map { it.text } }
        )
        assertEquals(listOf("Sans gluten."), label.notes.map { it.text })

        // Live product 4008400402222, and spans around multi-word lowercase allergens (7622210449283).
        assertEquals(
            "Zucker, Palmöl, _HASELNÜSSE_ (13%), _MAGERMILCHPULVER_ (8,7 %), Emulgator Lecithine (_SOJA_), Vanillin.",
            IngredientLabelParser.markingAllergens(
                plain = "Zucker, Palmöl, HASELNÜSSE (13%), MAGERMILCHPULVER (8,7 %), Emulgator Lecithine (SOJA), Vanillin.",
                markup = "Zucker, Palmöl, <span class=\"allergen\">HASELNÜSSE</span> (13%), " +
                    "<span class=\"allergen\">MAGERMILCHPULVER</span> (8,7 %), Emulgator Lecithine " +
                    "(<span class=\"allergen\">SOJA</span>), Vanillin."
            )
        )
        // Live product 5000159484695 flags ": cacahuète"; the colon stays outside the marker.
        assertEquals(
            "vanille. (Peut contenir: _cacahuète_, _noisette_)",
            IngredientLabelParser.markingAllergens(
                plain = "vanille. (Peut contenir: cacahuète, noisette)",
                markup = "vanille. (Peut contenir<span class=\"allergen\">: cacahuète</span>, " +
                    "<span class=\"allergen\">noisette</span>)"
            )
        )
        assertEquals(
            "émulsifiant (_lécithines de soja_), sel, perméat de lactosérum (de _lait_)",
            IngredientLabelParser.markingAllergens(
                plain = "émulsifiant (lécithines de soja), sel, perméat de lactosérum (de lait)",
                markup = "émulsifiant (<span class=\"allergen\">lécithines de soja</span>), sel, " +
                    "perméat de lactosérum (de <span class=\"allergen\">lait</span>)"
            )
        )
    }

    @Test
    fun allergenMarkupFallsBackToThePlainLabelWhenItDoesNotMatch() {
        // Open Food Facts turns contributor _markers_ into spans; keep them as markers.
        assertEquals(
            "Sucre, _lait_ écrémé",
            IngredientLabelParser.markingAllergens(
                plain = "Sucre, _lait_ écrémé",
                markup = "Sucre, <span class=\"allergen\">lait</span> écrémé"
            )
        )
        assertEquals(
            "Fish & chips, _milk_",
            IngredientLabelParser.markingAllergens(
                plain = "Fish & chips, milk",
                markup = "Fish &amp; chips, <span class=\"allergen\">milk</span>"
            )
        )
        assertEquals("Oats, milk", IngredientLabelParser.markingAllergens(plain = " Oats, milk ", markup = null))
        assertEquals("Oats, milk", IngredientLabelParser.markingAllergens(plain = "Oats, milk", markup = "  "))
        assertEquals(
            "Oats, milk",
            IngredientLabelParser.markingAllergens(plain = "Oats, milk", markup = "Oats, <b>milk</b>")
        )
        assertEquals(
            "Oats, milk",
            IngredientLabelParser.markingAllergens(
                plain = "Oats, milk",
                markup = "Avoine, <span class=\"allergen\">lait</span>"
            )
        )
        assertEquals(
            "_Oats_, salt",
            IngredientLabelParser.markingAllergens(plain = null, markup = "<span class=\"allergen\">Oats</span>, salt")
        )
        assertEquals(null, IngredientLabelParser.markingAllergens(plain = null, markup = null))
    }

    @Test
    fun entitiesLeftInThePlainLabelStillMatchTheMarkup() {
        assertEquals(
            "Fish & chips, _milk_",
            IngredientLabelParser.markingAllergens(
                plain = "Fish &amp; chips, milk",
                markup = "Fish &amp; chips, <span class=\"allergen\">milk</span>"
            )
        )
        assertEquals(
            "Fish &amp; chips, _milk_",
            IngredientLabelParser.markingAllergens(
                plain = "Fish &amp; chips, milk",
                markup = "Fish &amp;amp; chips, <span class=\"allergen\">milk</span>"
            )
        )
    }

    @Test
    fun statementsAfterTheListBecomeNotesInsteadOfEntries() {
        // Live product 3228857000166: the precautionary statement must not read as ingredients.
        val label = IngredientLabelParser.parse(
            "Farine complète de BLÉ 36%, eau, farine de BLÉ 24%, huile de colza, sucre, arôme (contient alcool), " +
                "sel, vinaigre, farine de SEIGLE maltée, levure, gluten de BLÉ, extrait d'acérola. Peut contenir " +
                "des traces d'OEUFS, SOJA, LAIT, FRUITS À COQUE et GRAINES DE SÉSAME."
        )
        assertEquals(
            listOf(
                "Farine complète de BLÉ 36%", "eau", "farine de BLÉ 24%", "huile de colza", "sucre",
                "arôme (contient alcool)", "sel", "vinaigre", "farine de SEIGLE maltée", "levure",
                "gluten de BLÉ", "extrait d'acérola"
            ),
            label.items.map { it.text }
        )
        assertEquals(
            listOf("Peut contenir des traces d'OEUFS, SOJA, LAIT, FRUITS À COQUE et GRAINES DE SÉSAME."),
            label.notes.map { it.text }
        )

        val us = IngredientLabelParser.parse(
            "Ingredients: Enriched flour, sugar, soybean oil. CONTAINS: WHEAT, SOY.",
            sensitivities = listOf("soy")
        )
        assertEquals(listOf("Enriched flour", "sugar", "soybean oil"), us.items.map { it.text })
        assertEquals(listOf(false, false, true), us.items.map { it.matchesSensitivity })
        assertEquals(listOf("CONTAINS: WHEAT, SOY."), us.notes.map { it.text })
        assertEquals(listOf(true), us.notes.map { it.matchesSensitivity })

        val footnote = IngredientLabelParser.parse("sugar, cocoa mass¹, salt.\n¹Rainforest Alliance Certified")
        assertEquals(listOf("sugar", "cocoa mass¹", "salt"), footnote.items.map { it.text })
        assertEquals(listOf("¹Rainforest Alliance Certified"), footnote.notes.map { it.text })
    }

    @Test
    fun lowercaseStatementsAfterTheListStillBecomeNotes() {
        val label = IngredientLabelParser.parse(
            "Ingredients: sugar, salt. may contain nuts, soy.",
            sensitivities = listOf("nuts")
        )
        assertEquals(listOf("sugar", "salt"), label.items.map { it.text })
        assertEquals(listOf("may contain nuts, soy."), label.notes.map { it.text })
        assertEquals(listOf(true), label.notes.map { it.matchesSensitivity })

        val french = IngredientLabelParser.parse("sucre, sel. peut contenir des traces de lait, soja.")
        assertEquals(listOf("sucre", "sel"), french.items.map { it.text })
        assertEquals(listOf("peut contenir des traces de lait, soja."), french.notes.map { it.text })

        // Matched without accents, as labels and OCR often drop them.
        val polish = IngredientLabelParser.parse("cukier, sól. moze zawierac orzechy, mleko.")
        assertEquals(listOf("cukier", "sól"), polish.items.map { it.text })
        assertEquals(listOf("moze zawierac orzechy, mleko."), polish.notes.map { it.text })

        // Other lowercase words after a full stop keep the list together.
        assertEquals(listOf("Sugar", "vit. c", "salt"), texts("Sugar, vit. c, salt"))
        assertEquals(listOf("flavouring. containing milk", "salt"), texts("flavouring. containing milk, salt"))
    }

    @Test
    fun fullStopsInsideTheListDoNotEndIt() {
        assertEquals(
            IngredientLabel(
                items = listOf("Sugar", "vit. C", "skimmed milk powder 8.7%", "acids (citric acid. Malic acid)")
                    .map { IngredientLabelItem(listOf(IngredientLabelItem.Segment(it, isAllergen = false))) }
            ),
            IngredientLabelParser.parse("Sugar, vit. C, skimmed milk powder 8.7%, acids (citric acid. Malic acid).")
        )
        // A single-entry first sentence still falls back to a paragraph.
        assertTrue(IngredientLabelParser.parse("Whole milk. May contain nuts, soy.").items.isEmpty())
    }

    private fun texts(label: String): List<String> = IngredientLabelParser.items(label).map { it.text }
}
