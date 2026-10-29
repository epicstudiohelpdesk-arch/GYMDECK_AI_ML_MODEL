import StoreKit
import SwiftUI
import UIKit

/// A Rate button: the native review prompt, or the App Store review page when the
/// prompt was requested recently. iOS shows the native prompt only a few times a
/// year and otherwise does nothing, which would leave the tap without a response.
enum AppRating {
    static let lastNativeRequestKey = "lastNativeReviewRequestDate"
    static let writeReviewURL = URL(string: "https://apps.apple.com/app/id6758935726?action=write-review")!
    /// The automatic review prompt's own spacing.
    static let recentInterval: TimeInterval = 122 * 24 * 60 * 60

    static func shouldUseNativePrompt(now: Date = .now, defaults: UserDefaults = .standard) -> Bool {
        if let last = defaults.object(forKey: lastNativeRequestKey) as? Date {
            return now.timeIntervalSince(last) > recentInterval
        }
        // ReviewPrompter asked after the first food log before request dates were saved.
        return !defaults.bool(forKey: ReviewPrompter.promptedKey)
    }

    static func recordNativeRequest(now: Date = .now, defaults: UserDefaults = .standard) {
        defaults.set(now, forKey: lastNativeRequestKey)
    }

    static func rate(openURL: OpenURLAction) {
        if shouldUseNativePrompt(),
           let scene = UIApplication.shared.connectedScenes
               .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            recordNativeRequest()
            AppStore.requestReview(in: scene)
        } else {
            openURL(writeReviewURL)
        }
    }
}
