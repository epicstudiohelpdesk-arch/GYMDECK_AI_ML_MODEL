import Foundation
import Testing
@testable import calorietracker

@MainActor
struct SiriWeightParsingTests {
    static let poundsPerKilogram = 2.20462

    @Test func latinUnitWordsPickTheUnit() throws {
        let kilograms = try SiriLoggingService.parseWeight("75 kilograms", defaultUnit: .lbs)
        #expect(kilograms.kg == 75)
        #expect(kilograms.unitName == "kilograms")

        let pounds = try SiriLoggingService.parseWeight("165 lb", defaultUnit: .kg)
        #expect(abs(pounds.kg - 165 / Self.poundsPerKilogram) < 0.0001)
        #expect(pounds.unitName == "pounds")
    }

    @Test func cyrillicUnitWordsFromTheRussianAndUkrainianHintsAreRecognised() throws {
        #expect(try SiriLoggingService.parseWeight("75 кг", defaultUnit: .lbs).unitName == "kilograms")
        #expect(try SiriLoggingService.parseWeight("75 килограммов", defaultUnit: .lbs).unitName == "kilograms")
        #expect(try SiriLoggingService.parseWeight("75 кілограмів", defaultUnit: .lbs).unitName == "kilograms")

        let russianPounds = try SiriLoggingService.parseWeight("165 фунтов", defaultUnit: .kg)
        #expect(russianPounds.unitName == "pounds")
        #expect(abs(russianPounds.kg - 165 / Self.poundsPerKilogram) < 0.0001)
        #expect(try SiriLoggingService.parseWeight("165 фунтів", defaultUnit: .kg).unitName == "pounds")
    }

    /// How a weight in pounds is said in each app language. A metric user who says
    /// one of these must not get the number saved as kilograms.
    nonisolated static let poundPhrases = [
        "165 pounds", "165 lbs", "165 Pfund", "165 pond", "165 libras", "165 libbre",
        "165 livres", "165 de livre", "165 liber", "165 libry", "165 funtów", "165 funt",
        "165 pound", "165 libre", "165 фунтов", "165 磅", "165ポンド", "165파운드",
        "165 رطل", "165 أرطال", "165 باوند", "165 पाउंड", "165 पौंड",
    ]

    /// How a weight in kilograms is said in each app language. An imperial user who
    /// says one of these must not get the number saved as pounds.
    nonisolated static let kilogramPhrases = [
        "75 KG", "75 kilos", "75 Kilogramm", "75 kilogramos", "75 chili", "75 chilogrammi",
        "75 kilogrammes", "75 de kilograme", "75 kil", "75 kilogramů", "75 kilogramów",
        "75 kiloqram", "75 kq", "75 кило", "75 кг", "75公斤", "75千克", "75キロ",
        "75 キログラム", "75킬로그램", "75키로", "75 كيلو", "75 كغ", "75 किलो", "75 किलोग्राम",
    ]

    @Test(arguments: poundPhrases)
    func poundWordsInEveryLanguageLogPounds(_ phrase: String) throws {
        let parsed = try SiriLoggingService.parseWeight(phrase, defaultUnit: .kg)
        #expect(parsed.unitName == "pounds", "\(phrase)")
        #expect(abs(parsed.kg - 165 / Self.poundsPerKilogram) < 0.0001, "\(phrase)")
        #expect(parsed.displayValue == 165)
    }

    @Test(arguments: kilogramPhrases)
    func kilogramWordsInEveryLanguageLogKilograms(_ phrase: String) throws {
        let parsed = try SiriLoggingService.parseWeight(phrase, defaultUnit: .lbs)
        #expect(parsed.unitName == "kilograms", "\(phrase)")
        #expect(parsed.kg == 75, "\(phrase)")
    }

    @Test func chineseJinIsHalfAKilogram() throws {
        let parsed = try SiriLoggingService.parseWeight("120斤", defaultUnit: .lbs)
        #expect(parsed.kg == 60)
        #expect(parsed.displayValue == 60)
        #expect(parsed.unitName == "kilograms")
    }

    @Test func digitsFromOtherScriptsAreRead() throws {
        #expect(try SiriLoggingService.parseWeight("٧٥ كيلو", defaultUnit: .lbs).kg == 75)
        #expect(try SiriLoggingService.parseWeight("٧٥٫٥ كغ", defaultUnit: .lbs).kg == 75.5)
        #expect(try SiriLoggingService.parseWeight("७५ किलो", defaultUnit: .lbs).kg == 75)
        #expect(try SiriLoggingService.parseWeight("７５キロ", defaultUnit: .lbs).kg == 75)
        #expect(try SiriLoggingService.parseWeight("75,5 kg", defaultUnit: .lbs).kg == 75.5)
    }

    @Test func aWeightWithoutAUnitUsesTheUnitSetting() throws {
        #expect(try SiriLoggingService.parseWeight("75", defaultUnit: .kg).unitName == "kilograms")
        #expect(try SiriLoggingService.parseWeight("165", defaultUnit: .lbs).unitName == "pounds")
        #expect(try SiriLoggingService.parseWeight("my weight is 165", defaultUnit: .lbs).unitName == "pounds")
        // Turkish "kilo" also means weight: "kilom 165" is "my weight is 165", not 165 kg.
        #expect(try SiriLoggingService.parseWeight("kilom 165", defaultUnit: .lbs).unitName == "pounds")
        #expect(try SiriLoggingService.parseWeight("kilomu 165 olarak kaydet", defaultUnit: .lbs).unitName == "pounds")
    }

    @Test func aUnitSaidBeforeTheNumberStillCounts() throws {
        let kilograms = try SiriLoggingService.parseWeight("my weight in kilograms is 75", defaultUnit: .lbs)
        #expect(kilograms.unitName == "kilograms")
        #expect(kilograms.kg == 75)
        #expect(try SiriLoggingService.parseWeight("in pounds 165", defaultUnit: .kg).unitName == "pounds")
        #expect(try SiriLoggingService.parseWeight("kilos: 75", defaultUnit: .lbs).unitName == "kilograms")
        // A unit after the number wins over one before it.
        #expect(try SiriLoggingService.parseWeight("not in kilograms, 165 pounds", defaultUnit: .kg).unitName == "pounds")
    }

    @Test func unitWordsAreMatchedAsWordsNotInsideOtherWords() throws {
        // "halb" contains "lb", but "75 einhalb Kilo" is in kilograms.
        let parsed = try SiriLoggingService.parseWeight("75 einhalb Kilo", defaultUnit: .lbs)
        #expect(parsed.unitName == "kilograms")
        #expect(parsed.kg == 75)
    }

    @Test func missingOrImplausibleWeightsAreRejected() {
        #expect(throws: SiriLoggingService.WeightInputError.self) {
            try SiriLoggingService.parseWeight("seventy kilos", defaultUnit: .kg)
        }
        #expect(throws: SiriLoggingService.WeightInputError.self) {
            try SiriLoggingService.parseWeight("600 kg", defaultUnit: .kg)
        }
    }
}
