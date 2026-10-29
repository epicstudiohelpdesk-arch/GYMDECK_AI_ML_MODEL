import Foundation
import Testing
@testable import calorietracker

/// kcal / kJ display preference (#520): storage stays kcal, display and input convert.
@MainActor
struct EnergyUnitTests {
    private static let english = Locale(identifier: "en_US")
    private static let german = Locale(identifier: "de_DE")

    @Test func preferenceDefaultsToKilocalories() throws {
        let suite = "EnergyUnitTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(EnergyUnit.defaultUnit == .kcal)
        #expect(EnergyUnit.current(in: defaults) == .kcal)
        defaults.set("calories", forKey: EnergyUnit.storageKey)
        #expect(EnergyUnit.current(in: defaults) == .kcal)
        defaults.set("kj", forKey: EnergyUnit.storageKey)
        #expect(EnergyUnit.current(in: defaults) == .kj)
    }

    @Test func kilocaloriesDisplayUnchanged() {
        #expect(EnergyUnit.kcal.displayValue(kcal: 1_234) == 1_234)
        #expect(EnergyUnit.kcal.kcal(fromDisplayed: 1_234) == 1_234)
        #expect(EnergyUnit.kcal.format(kcal: 1_234, locale: Self.english) == "1,234 kcal")
    }

    @Test func kilojoulesConvertAndRoundToWholeNumbers() {
        #expect(EnergyUnit.kj.displayValue(kcal: 0) == 0)
        #expect(EnergyUnit.kj.displayValue(kcal: 1) == 4)
        #expect(EnergyUnit.kj.displayValue(kcal: 100) == 418)
        #expect(EnergyUnit.kj.displayValue(kcal: 2_000) == 8_368)
        #expect(abs(EnergyUnit.kj.displayAmount(kcal: 250) - 1_046) < 0.000_1)
        #expect(EnergyUnit.kj.format(kcal: 2_000, locale: Self.english) == "8,368 kJ")
        #expect(EnergyUnit.kj.format(displayed: 3_151, locale: Self.english) == "3,151 kJ")
        #expect(EnergyUnit.kj.number(kcal: 2_000, locale: Self.german) == "8.368")
    }

    @Test func kilojouleInputIsStoredAsKilocalories() {
        #expect(EnergyUnit.kj.kcal(fromDisplayed: 8_368) == 2_000)
        #expect(EnergyUnit.kj.kcal(fromDisplayed: 418) == 100)
        #expect(EnergyUnit.kj.kcalAmount(fromDisplayed: 4.184) == 1)
        // Showing a stored kcal amount in kJ and saving it untouched never changes it.
        for kcal in 0...10_000 {
            #expect(EnergyUnit.kj.kcal(fromDisplayed: Double(EnergyUnit.kj.displayValue(kcal: kcal))) == kcal)
        }
    }

    @Test func typedAmountsParseInTheUserLocale() {
        #expect(EnergyUnit.kj.kcal(fromInput: "8368", locale: Self.english) == 2_000)
        #expect(EnergyUnit.kj.kcal(fromInput: "8,368", locale: Self.english) == 2_000)
        #expect(EnergyUnit.kj.kcal(fromInput: " 8368.4 ", locale: Self.english) == 2_000)
        #expect(EnergyUnit.kj.kcal(fromInput: "8.368", locale: Self.german) == 2_000)
        #expect(EnergyUnit.kj.kcal(fromInput: "418,4", locale: Self.german) == 100)
        #expect(EnergyUnit.kcal.kcal(fromInput: "1200", locale: Self.english) == 1_200)
        #expect(EnergyUnit.kj.kcal(fromInput: "", locale: Self.english) == nil)
        #expect(EnergyUnit.kj.kcal(fromInput: "abc", locale: Self.english) == nil)
        #expect(EnergyUnit.kj.kcal(fromInput: "-50", locale: Self.english) == nil)
    }

    @Test func goalWheelCoversTheSameSpanInEitherUnit() {
        let kcal = EnergyUnit.kcal
        #expect(kcal.goalPickerRange == 800...6_000)
        #expect(kcal.goalPickerStep == 50)
        // Kilocalories keep the existing snap-to-step behaviour.
        #expect(kcal.goalKcal(fromPicked: 2_000, currentKcal: 2_037) == 2_000)

        let kj = EnergyUnit.kj
        #expect(kj.kcal(fromDisplayed: Double(kj.goalPickerRange.lowerBound)) >= 800)
        #expect(kj.kcal(fromDisplayed: Double(kj.goalPickerRange.upperBound)) <= 6_000)
        #expect(kj.goalPickerRange.lowerBound.isMultiple(of: kj.goalPickerStep))
        #expect(kj.goalPickerStart(currentKcal: 2_000) == 8_300)
        // Saving the untouched kJ wheel keeps the exact kcal goal...
        #expect(kj.goalKcal(fromPicked: 8_300, currentKcal: 2_000) == 2_000)
        // ...and a new pick is converted back to kcal.
        #expect(kj.goalKcal(fromPicked: 8_400, currentKcal: 2_000) == 2_008)
        #expect(kj.goalPickerStart(currentKcal: 100) == kj.goalPickerRange.lowerBound)
    }

    @Test func aiPromptsOnlyChangeForKilojouleUsers() throws {
        #expect(EnergyUnit.kcal.aiReplyInstruction() == nil)
        #expect(EnergyUnit.kcal.aiReplyInstruction(toolArguments: true) == nil)
        let hint = try #require(EnergyUnit.kj.aiReplyInstruction())
        #expect(hint.contains("4.184"))
        #expect(!hint.contains("tool argument"))
        #expect(EnergyUnit.kj.aiReplyInstruction(toolArguments: true)?.contains("tool argument") == true)
    }

    @Test func dailySummaryUsesTheChosenUnit() {
        let kcal = NotificationManager.dailySummaryBody(todayCalories: 900, calorieGoal: 2_000, energyUnit: .kcal)
        #expect(kcal.contains("kcal"))
        #expect(!kcal.contains("kJ"))
        let kj = NotificationManager.dailySummaryBody(todayCalories: 900, calorieGoal: 2_000, energyUnit: .kj)
        #expect(kj.contains("kJ"))
        #expect(!kj.contains("kcal"))
        #expect(kj.contains("8") && kj.contains("3"))
    }

    @Test func widgetSnapshotCarriesTheUnitAndConverts() throws {
        var snapshot = WidgetSnapshot(
            date: .now,
            dayStart: Calendar.current.startOfDay(for: .now),
            calories: 1_247,
            calorieGoal: 2_000,
            protein: 0, proteinGoal: 150,
            carbs: 0, carbsGoal: 220,
            fat: 0, fatGoal: 70,
            homeNutrients: nil
        )
        // Snapshots from builds before #520 have no unit and stay kcal.
        #expect(!snapshot.usesKilojoules)
        #expect(snapshot.displayCalories == 1_247)
        #expect(snapshot.displayCaloriesRemaining == snapshot.caloriesRemaining)

        snapshot.energyUnitRaw = EnergyUnit.kj.rawValue
        let payload = try #require(snapshot.payloadData)
        let decoded = try #require(WidgetSnapshot.decodePayload(payload))
        #expect(decoded.usesKilojoules)
        #expect(decoded.calories == 1_247)
        #expect(decoded.displayCalories == 5_217)
        #expect(decoded.displayCalorieGoal == 8_368)
        #expect(decoded.displayCaloriesRemaining == 8_368 - 5_217)
        #expect(decoded.emptyForToday().energyUnitRaw == EnergyUnit.kj.rawValue)
    }
}
