import Foundation
import Testing
@testable import calorietracker

/// The settings the app re-reads when it becomes active to re-add the daily meal and
/// water reminders in the current language.
@MainActor
struct RepeatingReminderSettingsTests {
    private typealias Settings = NotificationManager.RepeatingReminderSettings

    private func makeDefaults() -> UserDefaults {
        let suite = "RepeatingReminderSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func untouchedSettingsMatchTheRemindersOnboardingAdds() {
        // Onboarding adds breakfast 8:00, lunch 12:00 and dinner 19:00 without saving
        // them, so a refresh must not move those reminders.
        let settings = Settings(defaults: makeDefaults())
        #expect(settings.breakfast == .init(enabled: true, hour: 8, minute: 0))
        #expect(settings.lunch == .init(enabled: true, hour: 12, minute: 0))
        #expect(settings.dinner == .init(enabled: true, hour: 19, minute: 0))
        #expect(settings.water == .init(enabled: false, hour: 14, minute: 0))
    }

    @Test func savedMealTimesAndSwitchesAreKept() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "breakfastReminderEnabled")
        defaults.set(13, forKey: "lunchReminderHour")
        defaults.set(30, forKey: "lunchReminderMinute")
        defaults.set(20, forKey: "dinnerReminderHour")
        defaults.set(15, forKey: "dinnerReminderMinute")

        let settings = Settings(defaults: defaults)
        #expect(settings.breakfast == .init(enabled: false, hour: 8, minute: 0))
        #expect(settings.lunch == .init(enabled: true, hour: 13, minute: 30))
        #expect(settings.dinner == .init(enabled: true, hour: 20, minute: 15))
    }

    @Test func waterReminderNeedsWaterTrackingAndItsSwitch() {
        let defaults = makeDefaults()
        defaults.set(16, forKey: WaterSettings.reminderHourKey)
        defaults.set(45, forKey: WaterSettings.reminderMinuteKey)

        defaults.set(true, forKey: WaterSettings.reminderEnabledKey)
        #expect(Settings(defaults: defaults).water.enabled == false)

        defaults.set(true, forKey: WaterSettings.enabledKey)
        #expect(Settings(defaults: defaults).water == .init(enabled: true, hour: 16, minute: 45))

        defaults.set(false, forKey: WaterSettings.reminderEnabledKey)
        #expect(Settings(defaults: defaults).water.enabled == false)
    }
}
