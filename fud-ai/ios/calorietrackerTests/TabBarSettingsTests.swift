import Foundation
import Testing
@testable import calorietracker

struct TabBarSettingsTests {
    @Test func missingOrEmptyStorageShowsEveryTab() {
        #expect(TabBarSettings.decode(nil).isEmpty)
        #expect(TabBarSettings.decode("").isEmpty)
    }

    @Test func hiddenTabsRoundTripInTabOrder() {
        let encoded = TabBarSettings.encode([.workouts, .coach])
        #expect(encoded == "coach,workouts")
        #expect(TabBarSettings.decode(encoded) == [.coach, .workouts])
    }

    @Test func homeSettingsAndUnknownValuesAreNeverHidden() {
        #expect(TabBarSettings.decode("home, settings,kitchen , progress") == [.progress])
        for screen in [VoiceAssistantScreen.home, .settings] {
            #expect(TabBarSettings.hiddenTab(for: screen, in: Set(HideableTab.allCases)) == nil)
        }
        #expect(TabBarSettings.hiddenTab(for: .coach, in: [.coach]) == .coach)
        #expect(TabBarSettings.hiddenTab(for: .coach, in: [.progress]) == nil)
    }

    @Test func hiddenTabsReadFromTheGivenDefaults() {
        let suiteName = "TabBarSettingsTests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suiteName)!
        defer { store.removePersistentDomain(forName: suiteName) }

        #expect(TabBarSettings.hiddenTabs(in: store).isEmpty)
        store.set("workouts", forKey: TabBarSettings.hiddenTabsKey)
        #expect(TabBarSettings.hiddenTabs(in: store) == [.workouts])
    }
}
