import Testing
import Foundation
import UIKit
@testable import calorietracker

@MainActor
struct ShareImportTests {

    @Test func testShareImportFlow() throws {
        // Keep the app-group location and other test runs' files untouched.
        let originalURL = ShareImportManager.sharedImportURL
        let testURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-import-\(UUID().uuidString).jpg")
        defer {
            ShareImportManager.sharedImportURL = originalURL
            try? FileManager.default.removeItem(at: testURL)
        }
        ShareImportManager.sharedImportURL = testURL

        // 1. Prepare dummy image data
        let dummyImage = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let dummyData = try #require(dummyImage.jpegData(compressionQuality: 0.8))

        // 2. Save it
        let success = ShareImportManager.saveSharedImage(dummyData)
        #expect(success, "Should save the image to the shared file URL")

        // 3. Verify it is detected
        #expect(ShareImportManager.hasSharedImage(), "Should detect shared image")

        // 4. Consume it
        let consumedImage = ShareImportManager.consumeSharedImage()
        #expect(consumedImage != nil, "Should retrieve the consumed image")

        // 5. Verify it is cleaned up
        #expect(!ShareImportManager.hasSharedImage(), "Should clean up/delete the image after consuming")
    }
}
