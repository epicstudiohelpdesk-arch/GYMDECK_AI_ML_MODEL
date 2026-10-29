import XCTest

final class calorietrackerUITestsLaunchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsMainNavigationAndHome() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--ui-testing-reset", "--ui-testing-onboarded",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-WorkoutVectorsBaseURL", "none",
        ]
        app.launch()

        XCTAssertTrue(app.buttons["home.add"].waitForExistence(timeout: 15))
        for tab in ["Home", "Progress", "Coach", "Settings", "Workouts"] {
            XCTAssertTrue(app.tabBars.buttons[tab].exists, "Missing main tab: \(tab)")
        }
        XCTAssertTrue(app.tabBars.buttons["Home"].isSelected)
        XCTAssertFalse(app.buttons["Get Started"].exists)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Home navigation"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
