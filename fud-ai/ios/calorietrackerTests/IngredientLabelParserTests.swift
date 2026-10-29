import Foundation
import Testing
@testable import calorietracker

/// Fixtures match Android `IngredientLabelParserTest`; keep both in sync.
struct IngredientLabelParserTests {
    @Test
    func splitsTopLevelEntriesAndTrimsTheFinalPeriod() {
        let items = IngredientLabelParser.items(
            from: "Sugar, palm oil, hazelnuts 13%, skimmed milk powder 8.7%, emulsifier: lecithins (soya), vanillin."
        )
        #expect(items.map(\.text) == [
            "Sugar", "palm oil", "hazelnuts 13%", "skimmed milk powder 8.7%",
            "emulsifier: lecithins (soya)", "vanillin"
        ])
    }

    @Test
    func keepsBracketedSubIngredientsTogether() {
        #expect(texts("Vegetable oil (palm, sunflower), salt") == ["Vegetable oil (palm, sunflower)", "salt"])
        #expect(texts("Chocolate (sugar, cocoa butter (from beans), milk), salt") == [
            "Chocolate (sugar, cocoa butter (from beans), milk)", "salt"
        ])
        #expect(texts("Water; sugar [cane, beet]; acid: citric acid") == [
            "Water", "sugar [cane, beet]", "acid: citric acid"
        ])
        #expect(texts("小麦粉（国内製造、米国産）、砂糖、食塩") == ["小麦粉（国内製造、米国産）", "砂糖", "食塩"])
    }

    @Test
    func splitsOnArabicCommasAndSemicolons() {
        #expect(texts("المكونات: سكر، ملح؛ حليب") == ["سكر", "ملح", "حليب"])
        let label = IngredientLabelParser.parse("سكر، ملح. قد يحتوي على مكسرات.")
        #expect(label.items.map(\.text) == ["سكر", "ملح"])
        #expect(label.notes.map(\.text) == ["قد يحتوي على مكسرات."])
    }

    @Test
    func keepsDecimalCommasInsidePercentages() {
        #expect(texts("Zucker, Magermilchpulver 8,7%, Salz") == ["Zucker", "Magermilchpulver 8,7%", "Salz"])
    }

    @Test
    func stripsIngredientHeadingsButNotOtherLeadingColons() {
        #expect(texts("Ingredients: oats, salt.") == ["oats", "salt"])
        #expect(texts("Zutaten: Zucker, Salz") == ["Zucker", "Salz"])
        #expect(texts("原材料名：小麦粉、砂糖") == ["小麦粉", "砂糖"])
        #expect(texts("İçindekiler: şeker, tuz") == ["şeker", "tuz"])
        #expect(texts("Składniki: cukier, sól") == ["cukier", "sól"])
        #expect(texts("Emulsifier: soy lecithin, sugar") == ["Emulsifier: soy lecithin", "sugar"])
    }

    @Test
    func collapsesWhitespaceAndDropsEmptyEntries() {
        #expect(texts("Sugar,\n  cocoa   butter ,, salt ;") == ["Sugar", "cocoa butter", "salt"])
        #expect(texts("Sugar,\u{00A0}\u{00A0}cocoa\u{00A0} butter, salt") == ["Sugar", "cocoa butter", "salt"])
    }

    @Test
    func labelsThatDoNotFormAListFallBackToAParagraph() {
        #expect(IngredientLabelParser.items(from: "Whole milk").isEmpty)
        #expect(IngredientLabelParser.items(from: "").isEmpty)
        #expect(IngredientLabelParser.items(from: "   ").isEmpty)

        let sixty = (1...60).map { "item \($0)" }.joined(separator: ", ")
        let sixtyOne = (1...61).map { "item \($0)" }.joined(separator: ", ")
        #expect(IngredientLabelParser.items(from: sixty).count == 60)
        #expect(IngredientLabelParser.items(from: sixtyOne).isEmpty)
    }

    @Test
    func paragraphFallbackKeepsTheSensitivityWarning() {
        let single = IngredientLabelParser.parse("Whole milk", sensitivities: ["milk"])
        #expect(single.items.isEmpty)
        #expect(single.paragraph?.text == "Whole milk")
        #expect(single.paragraph?.matchesSensitivity == true)
        #expect(IngredientLabelParser.parse("Whole milk").paragraph?.matchesSensitivity == false)

        let overLimit = IngredientLabelParser.parse(
            (1...61).map { "item \($0)" }.joined(separator: ", ") + ", skimmed _milk_ powder",
            sensitivities: ["milk"]
        )
        #expect(overLimit.items.isEmpty)
        #expect(overLimit.paragraph?.matchesSensitivity == true)
        #expect(overLimit.paragraph?.segments.filter(\.isAllergen).map(\.text) == ["milk"])

        #expect(IngredientLabelParser.parse("   ").paragraph == nil)
        #expect(IngredientLabelParser.parse("Sugar, salt").paragraph == nil)
    }

    @Test
    func openFoodFactsAllergenMarkersBecomeEmphasizedSegments() {
        #expect(IngredientLabelParser.segments(in: "skimmed _milk_ powder") == [
            .init(text: "skimmed ", isAllergen: false),
            .init(text: "milk", isAllergen: true),
            .init(text: " powder", isAllergen: false)
        ])
        #expect(IngredientLabelParser.segments(in: "sugar_ syrup") == [.init(text: "sugar syrup", isAllergen: false)])

        let items = IngredientLabelParser.items(from: "Ingrédients : farine de _blé_, sel")
        #expect(items.map(\.text) == ["farine de blé", "sel"])
        #expect(items.first?.segments == [
            .init(text: "farine de ", isAllergen: false),
            .init(text: "blé", isAllergen: true)
        ])
    }

    @Test
    func entriesMatchingSensitivitiesAreFlagged() {
        let items = IngredientLabelParser.items(
            from: "Sugar, skimmed _milk_ powder, whey, hazelnuts",
            sensitivities: ["milk", "nuts"]
        )
        #expect(items.map(\.matchesSensitivity) == [false, true, true, true])
        #expect(IngredientLabelParser.items(from: "Sugar, whey").map(\.matchesSensitivity) == [false, false])
    }

    @Test
    func entriesWithEitherKindOfAllergenEmphasisAreAnnounced() {
        let items = IngredientLabelParser.items(
            from: "Sugar, skimmed _milk_ powder, hazelnuts",
            sensitivities: ["nuts"]
        )
        #expect(items.map(\.matchesSensitivity) == [false, false, true])
        #expect(items.map(\.announcesAllergen) == [false, true, true])
        #expect(IngredientLabelParser.parse("_Milk_").paragraph?.announcesAllergen == true)
        #expect(IngredientLabelParser.parse("Water").paragraph?.announcesAllergen == false)
    }

    @Test
    func openFoodFactsAllergenSpansBecomeMarkers() throws {
        // Live Open Food Facts product 3017620422003: ingredients_text has no markers, the
        // allergens it flags are only in ingredients_text_with_allergens (with stray </span>s).
        let marked = IngredientLabelParser.markingAllergens(
            plain: "Sucre, huile de palme, NOISETTES 13%, cacao maigre 7,4%, LAIT écrémé en poudre 6,6%, "
                + "LACTOSERUM en poudre, émulsifiants: lécithines [SOJA), vanilline. Sans gluten.",
            markup: #"Sucre, huile de palme, <span class="allergen">NOISETTES</span> </span>13%, cacao maigre 7,4%, "#
                + #"<span class="allergen">LAIT</span> </span>écrémé en poudre 6,6%, "#
                + #"<span class="allergen">LACTOSERUM</span> </span>en poudre, émulsifiants: lécithines "#
                + #"[<span class="allergen">SOJA</span>), vanilline. Sans gluten."#
        )
        #expect(marked == "Sucre, huile de palme, _NOISETTES_ 13%, cacao maigre 7,4%, _LAIT_ écrémé en poudre 6,6%, "
            + "_LACTOSERUM_ en poudre, émulsifiants: lécithines [_SOJA_), vanilline. Sans gluten.")

        let label = IngredientLabelParser.parse(try #require(marked))
        #expect(label.items.map(\.text) == [
            "Sucre", "huile de palme", "NOISETTES 13%", "cacao maigre 7,4%", "LAIT écrémé en poudre 6,6%",
            "LACTOSERUM en poudre", "émulsifiants: lécithines [SOJA)", "vanilline"
        ])
        #expect(label.items.flatMap { $0.segments.filter(\.isAllergen).map(\.text) } == [
            "NOISETTES", "LAIT", "LACTOSERUM", "SOJA"
        ])
        #expect(label.notes.map(\.text) == ["Sans gluten."])

        // Live product 4008400402222, and spans around multi-word lowercase allergens (7622210449283).
        #expect(IngredientLabelParser.markingAllergens(
            plain: "Zucker, Palmöl, HASELNÜSSE (13%), MAGERMILCHPULVER (8,7 %), Emulgator Lecithine (SOJA), Vanillin.",
            markup: #"Zucker, Palmöl, <span class="allergen">HASELNÜSSE</span> (13%), "#
                + #"<span class="allergen">MAGERMILCHPULVER</span> (8,7 %), Emulgator Lecithine "#
                + #"(<span class="allergen">SOJA</span>), Vanillin."#
        ) == "Zucker, Palmöl, _HASELNÜSSE_ (13%), _MAGERMILCHPULVER_ (8,7 %), Emulgator Lecithine (_SOJA_), Vanillin.")
        // Live product 5000159484695 flags ": cacahuète"; the colon stays outside the marker.
        #expect(IngredientLabelParser.markingAllergens(
            plain: "vanille. (Peut contenir: cacahuète, noisette)",
            markup: #"vanille. (Peut contenir<span class="allergen">: cacahuète</span>, "#
                + #"<span class="allergen">noisette</span>)"#
        ) == "vanille. (Peut contenir: _cacahuète_, _noisette_)")
        #expect(IngredientLabelParser.markingAllergens(
            plain: "émulsifiant (lécithines de soja), sel, perméat de lactosérum (de lait)",
            markup: #"émulsifiant (<span class="allergen">lécithines de soja</span>), sel, "#
                + #"perméat de lactosérum (de <span class="allergen">lait</span>)"#
        ) == "émulsifiant (_lécithines de soja_), sel, perméat de lactosérum (de _lait_)")
    }

    @Test
    func allergenMarkupFallsBackToThePlainLabelWhenItDoesNotMatch() {
        // Open Food Facts turns contributor _markers_ into spans; keep them as markers.
        #expect(IngredientLabelParser.markingAllergens(
            plain: "Sucre, _lait_ écrémé",
            markup: #"Sucre, <span class="allergen">lait</span> écrémé"#
        ) == "Sucre, _lait_ écrémé")
        #expect(IngredientLabelParser.markingAllergens(
            plain: "Fish & chips, milk",
            markup: #"Fish &amp; chips, <span class="allergen">milk</span>"#
        ) == "Fish & chips, _milk_")
        #expect(IngredientLabelParser.markingAllergens(plain: " Oats, milk ", markup: nil) == "Oats, milk")
        #expect(IngredientLabelParser.markingAllergens(plain: "Oats, milk", markup: "  ") == "Oats, milk")
        #expect(IngredientLabelParser.markingAllergens(plain: "Oats, milk", markup: "Oats, <b>milk</b>") == "Oats, milk")
        #expect(IngredientLabelParser.markingAllergens(
            plain: "Oats, milk",
            markup: #"Avoine, <span class="allergen">lait</span>"#
        ) == "Oats, milk")
        #expect(IngredientLabelParser.markingAllergens(
            plain: nil,
            markup: #"<span class="allergen">Oats</span>, salt"#
        ) == "_Oats_, salt")
        #expect(IngredientLabelParser.markingAllergens(plain: nil, markup: nil) == nil)
    }

    @Test
    func entitiesLeftInThePlainLabelStillMatchTheMarkup() {
        #expect(IngredientLabelParser.markingAllergens(
            plain: "Fish &amp; chips, milk",
            markup: #"Fish &amp; chips, <span class="allergen">milk</span>"#
        ) == "Fish & chips, _milk_")
        #expect(IngredientLabelParser.markingAllergens(
            plain: "Fish &amp; chips, milk",
            markup: #"Fish &amp;amp; chips, <span class="allergen">milk</span>"#
        ) == "Fish &amp; chips, _milk_")
    }

    @Test
    func statementsAfterTheListBecomeNotesInsteadOfEntries() {
        // Live product 3228857000166: the precautionary statement must not read as ingredients.
        let label = IngredientLabelParser.parse(
            "Farine complète de BLÉ 36%, eau, farine de BLÉ 24%, huile de colza, sucre, arôme (contient alcool), "
                + "sel, vinaigre, farine de SEIGLE maltée, levure, gluten de BLÉ, extrait d'acérola. Peut contenir "
                + "des traces d'OEUFS, SOJA, LAIT, FRUITS À COQUE et GRAINES DE SÉSAME."
        )
        #expect(label.items.map(\.text) == [
            "Farine complète de BLÉ 36%", "eau", "farine de BLÉ 24%", "huile de colza", "sucre",
            "arôme (contient alcool)", "sel", "vinaigre", "farine de SEIGLE maltée", "levure",
            "gluten de BLÉ", "extrait d'acérola"
        ])
        #expect(label.notes.map(\.text) == [
            "Peut contenir des traces d'OEUFS, SOJA, LAIT, FRUITS À COQUE et GRAINES DE SÉSAME."
        ])

        let us = IngredientLabelParser.parse(
            "Ingredients: Enriched flour, sugar, soybean oil. CONTAINS: WHEAT, SOY.",
            sensitivities: ["soy"]
        )
        #expect(us.items.map(\.text) == ["Enriched flour", "sugar", "soybean oil"])
        #expect(us.items.map(\.matchesSensitivity) == [false, false, true])
        #expect(us.notes.map(\.text) == ["CONTAINS: WHEAT, SOY."])
        #expect(us.notes.map(\.matchesSensitivity) == [true])

        let footnote = IngredientLabelParser.parse("sugar, cocoa mass¹, salt.\n¹Rainforest Alliance Certified")
        #expect(footnote.items.map(\.text) == ["sugar", "cocoa mass¹", "salt"])
        #expect(footnote.notes.map(\.text) == ["¹Rainforest Alliance Certified"])
    }

    @Test
    func lowercaseStatementsAfterTheListStillBecomeNotes() {
        let label = IngredientLabelParser.parse(
            "Ingredients: sugar, salt. may contain nuts, soy.",
            sensitivities: ["nuts"]
        )
        #expect(label.items.map(\.text) == ["sugar", "salt"])
        #expect(label.notes.map(\.text) == ["may contain nuts, soy."])
        #expect(label.notes.map(\.matchesSensitivity) == [true])

        let french = IngredientLabelParser.parse("sucre, sel. peut contenir des traces de lait, soja.")
        #expect(french.items.map(\.text) == ["sucre", "sel"])
        #expect(french.notes.map(\.text) == ["peut contenir des traces de lait, soja."])

        // Matched without accents, as labels and OCR often drop them.
        let polish = IngredientLabelParser.parse("cukier, sól. moze zawierac orzechy, mleko.")
        #expect(polish.items.map(\.text) == ["cukier", "sól"])
        #expect(polish.notes.map(\.text) == ["moze zawierac orzechy, mleko."])

        // Other lowercase words after a full stop keep the list together.
        #expect(texts("Sugar, vit. c, salt") == ["Sugar", "vit. c", "salt"])
        #expect(texts("flavouring. containing milk, salt") == ["flavouring. containing milk", "salt"])
    }

    @Test
    func fullStopsInsideTheListDoNotEndIt() {
        #expect(IngredientLabelParser.parse(
            "Sugar, vit. C, skimmed milk powder 8.7%, acids (citric acid. Malic acid)."
        ) == IngredientLabel(
            items: ["Sugar", "vit. C", "skimmed milk powder 8.7%", "acids (citric acid. Malic acid)"].map {
                IngredientLabelItem(segments: [.init(text: $0, isAllergen: false)], matchesSensitivity: false)
            }
        ))
        // A single-entry first sentence still falls back to a paragraph.
        #expect(IngredientLabelParser.parse("Whole milk. May contain nuts, soy.").items.isEmpty)
    }

    private func texts(_ label: String) -> [String] {
        IngredientLabelParser.items(from: label).map(\.text)
    }
}
