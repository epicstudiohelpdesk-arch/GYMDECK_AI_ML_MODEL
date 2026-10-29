import Foundation
import Testing
@testable import calorietracker

struct WhatsNewTests {
    @Test func everyoneGetsTheVideoSupportAndDeveloperPages() {
        let everyone: [WhatsNewPage] = [.liveVoice, .support, .developer]
        #expect(WhatsNewPages.pages(access: nil) == everyone)
        #expect(WhatsNewPages.pages(access: WhatsNewAccess(canBuyPlans: false, needsLiveVoiceSetup: false)) == everyone)
    }

    @Test func gettingLiveVoiceFollowsTheVideo() {
        let expected: [WhatsNewPage] = [.liveVoice, .access, .support, .developer]
        #expect(WhatsNewPages.pages(access: WhatsNewAccess(canBuyPlans: true, needsLiveVoiceSetup: false)) == expected)
        #expect(WhatsNewPages.pages(access: WhatsNewAccess(canBuyPlans: false, needsLiveVoiceSetup: true)) == expected)
        #expect(WhatsNewPages.pages(access: WhatsNewAccess(canBuyPlans: true, needsLiveVoiceSetup: true)) == expected)
    }

    @Test @MainActor
    func rateUsesTheNativePromptOnlyWhenNotAskedRecently() throws {
        let suite = "WhatsNewTests.rate.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        #expect(AppRating.shouldUseNativePrompt(now: now, defaults: defaults))
        AppRating.recordNativeRequest(now: now, defaults: defaults)
        #expect(!AppRating.shouldUseNativePrompt(now: now.addingTimeInterval(30 * 86_400), defaults: defaults))
        #expect(AppRating.shouldUseNativePrompt(now: now.addingTimeInterval(123 * 86_400), defaults: defaults))
    }

    @Test @MainActor
    func theUndatedFirstLogPromptCountsAsRecent() throws {
        let suite = "WhatsNewTests.firstLog.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: ReviewPrompter.promptedKey)

        #expect(!AppRating.shouldUseNativePrompt(now: .now, defaults: defaults))
    }
}
