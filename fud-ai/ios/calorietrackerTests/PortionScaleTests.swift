import CoreGraphics
import Foundation
import simd
import Testing
import UIKit
@testable import calorietracker

struct PortionScaleTests {
    private let intrinsics = simd_float3x3(columns: (
        SIMD3<Float>(1500, 0, 0),
        SIMD3<Float>(0, 1500, 0),
        SIMD3<Float>(960, 720, 1)
    ))
    private let resolution = CGSize(width: 1920, height: 1440)

    /// A camera at `position` whose view direction is tilted `degrees` from straight down.
    private func camera(at position: SIMD3<Float>, tilt degrees: Float) -> simd_float4x4 {
        let radians = degrees * .pi / 180
        let back = SIMD3<Float>(0, cos(radians), sin(radians))
        let right = SIMD3<Float>(1, 0, 0)
        let up = simd_cross(back, right)
        return simd_float4x4(columns: (
            SIMD4<Float>(right, 0),
            SIMD4<Float>(up, 0),
            SIMD4<Float>(back, 0),
            SIMD4<Float>(position, 1)
        ))
    }

    private func measure(
        cameraAt position: SIMD3<Float>,
        tilt: Float = 0,
        planePoint: SIMD3<Float> = .zero,
        portrait: Bool = true
    ) -> PortionScale? {
        PortionScale.measure(
            cameraTransform: camera(at: position, tilt: tilt),
            planePoint: planePoint,
            planeNormal: SIMD3<Float>(0, 1, 0),
            intrinsics: intrinsics,
            imageResolution: resolution,
            portrait: portrait
        )
    }

    @Test func overheadPhotoGetsTheTableFootprint() throws {
        let scale = try #require(measure(cameraAt: SIMD3<Float>(0, 0.4, 0)))
        #expect(abs(scale.cameraHeightCm - 40) < 0.01)
        #expect(scale.tiltDegrees < 0.01)
        // 1440 / 1500 × 40 cm across the upright photo, 1920 / 1500 × 40 cm down it.
        #expect(abs(scale.photoWidthCm - 38.4) < 0.01)
        #expect(abs(scale.photoHeightCm - 51.2) < 0.01)
        #expect(scale.readiness == .ready)
    }

    @Test func landscapePhotoKeepsTheSensorAxes() throws {
        let scale = try #require(measure(cameraAt: SIMD3<Float>(0, 0.4, 0), portrait: false))
        #expect(abs(scale.photoWidthCm - 51.2) < 0.01)
        #expect(abs(scale.photoHeightCm - 38.4) < 0.01)
    }

    @Test func tiltedPhotoSpansTheTableItReallySees() throws {
        // 40 cm above the table, tilted 30° along the portrait width: the far
        // half of the frame reaches much further across the table than the near half.
        let scale = try #require(measure(cameraAt: SIMD3<Float>(0, 0.4, 0.4 * tan(.pi / 6)), tilt: 30))
        #expect(abs(scale.tiltDegrees - 30) < 0.01)
        #expect(abs(scale.cameraHeightCm - 40) < 0.01)
        // 40 × (tan(30° + atan 0.48) − tan(30° − atan 0.48)), and 40 / cos 30° × 1.28.
        #expect(abs(scale.photoWidthCm - 55.46) < 0.05)
        #expect(abs(scale.photoHeightCm - 59.12) < 0.05)
        #expect(scale.readiness == .ready)
    }

    @Test func tiltedPhotoIsMeasuredButNotReady() throws {
        let scale = try #require(measure(cameraAt: SIMD3<Float>(0, 0.3, 0.3), tilt: 45))
        #expect(abs(scale.tiltDegrees - 45) < 0.01)
        #expect(abs(scale.cameraHeightCm - 30) < 0.01)
        #expect(scale.readiness == .tooTilted)

        let slight = try #require(measure(cameraAt: SIMD3<Float>(0, 0.4, 0.4 * tan(.pi / 9)), tilt: 20))
        #expect(slight.readiness == .ready)
    }

    @Test func heightOutsideTheUsableRangeIsNotReady() throws {
        #expect(try #require(measure(cameraAt: SIMD3<Float>(0, 0.05, 0))).readiness == .tooClose)
        #expect(try #require(measure(cameraAt: SIMD3<Float>(0, 1.5, 0))).readiness == .tooFar)
    }

    @Test func impossibleGeometryHasNoMeasurement() {
        // Camera below the table.
        #expect(measure(cameraAt: SIMD3<Float>(0, -0.4, 0)) == nil)
        #expect(PortionScale.measure(
            cameraTransform: camera(at: SIMD3<Float>(0, 0.4, 0), tilt: 0),
            planePoint: .zero,
            planeNormal: SIMD3<Float>(0, 1, 0),
            intrinsics: simd_float3x3(),
            imageResolution: resolution
        ) == nil)
        #expect(PortionScale.measure(
            cameraTransform: camera(at: SIMD3<Float>(0, 0.4, 0), tilt: 0),
            planePoint: .zero,
            planeNormal: .zero,
            intrinsics: intrinsics,
            imageResolution: resolution
        ) == nil)
    }

    @Test func promptSectionListsOnlyUsableMeasurements() throws {
        let ready = PortionScale(cameraHeightCm: 39.6, tiltDegrees: 4, photoWidthCm: 38.4, photoHeightCm: 51.2)
        let tilted = PortionScale(cameraHeightCm: 30, tiltDegrees: 45, photoWidthCm: 30, photoHeightCm: 40)
        let section = try #require(PortionScale.promptSection(for: [nil, ready, tilted]))
        #expect(section.hasPrefix("REAL-WORLD SCALE"))
        #expect(section.contains("- Photo 2: taken from about 40 cm above the table, looking straight down."))
        #expect(section.contains("the photo spans about 38 cm of table across and 51 cm top to bottom"))
        #expect(!section.contains("Photo 1:"))
        #expect(!section.contains("Photo 3:"))

        #expect(PortionScale.promptSection(for: [nil, tilted]) == nil)
        #expect(PortionScale.promptSection(for: []) == nil)
    }

    @Test @MainActor
    func analysisPromptAddsTheScaleSectionLast() throws {
        let section = try #require(PortionScale.promptSection(for: [
            PortionScale(cameraHeightCm: 40, tiltDegrees: 12, photoWidthCm: 38, photoHeightCm: 51),
        ]))
        let base = GeminiService.multiPhotoAnalysisPrompt(progressiveMeal: false, description: "no sauce")
        let measured = GeminiService.multiPhotoAnalysisPrompt(
            progressiveMeal: false,
            description: "no sauce",
            portionScaleSection: section
        )
        #expect(measured == base + "\n\n" + section)
        #expect(section.contains("looking nearly straight down"))
    }

    @Test @MainActor
    func registryKeepsTheMeasurementWithItsPhoto() {
        let size = CGSize(width: 4, height: 4)
        let measured = UIGraphicsImageRenderer(size: size).image { _ in }
        let plain = UIGraphicsImageRenderer(size: size).image { _ in }
        let scale = PortionScale(cameraHeightCm: 40, tiltDegrees: 0, photoWidthCm: 38, photoHeightCm: 51)
        PortionScaleRegistry.attach(scale, to: measured)
        #expect(PortionScaleRegistry.scale(for: measured) == scale)
        #expect(PortionScaleRegistry.scale(for: plain) == nil)
    }
}
