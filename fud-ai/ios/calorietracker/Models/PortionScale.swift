import CoreGraphics
import Foundation
import simd
import UIKit

/// Real-world scale for a food photo, measured with the AR camera from the table
/// the food sits on (#601). The AI gets the table area the photo covers, so it can
/// size plates, bowls and portions from real dimensions instead of guessing.
nonisolated struct PortionScale: Equatable, Sendable {
    /// Camera height above the table plane.
    let cameraHeightCm: Double
    /// Angle between the camera's view direction and straight down.
    let tiltDegrees: Double
    /// Table distance the upright photo spans through its centre, across and top to bottom.
    let photoWidthCm: Double
    let photoHeightCm: Double

    static let maxTiltDegrees: Double = 30
    static let minHeightCm: Double = 10
    static let maxHeightCm: Double = 100

    enum Readiness: Equatable, Sendable {
        case tooClose
        case tooFar
        case tooTilted
        case ready
    }

    /// Only a near-overhead photo has an even scale across the frame, so steeper
    /// angles and out-of-range heights are not sent to the AI.
    var readiness: Readiness {
        if cameraHeightCm < Self.minHeightCm { return .tooClose }
        if cameraHeightCm > Self.maxHeightCm { return .tooFar }
        if tiltDegrees > Self.maxTiltDegrees { return .tooTilted }
        return .ready
    }

    /// - Parameters:
    ///   - cameraTransform: `ARCamera.transform`; the camera looks down its -Z axis.
    ///   - planePoint: any point on the table, e.g. where the centre ray meets it.
    ///   - planeNormal: the table's up direction.
    ///   - intrinsics: `ARCamera.intrinsics`, in pixels of `imageResolution`.
    ///   - imageResolution: the landscape sensor image the intrinsics describe.
    ///   - portrait: whether the saved photo is upright portrait, which swaps the
    ///     sensor's width and height.
    static func measure(
        cameraTransform: simd_float4x4,
        planePoint: SIMD3<Float>,
        planeNormal: SIMD3<Float>,
        intrinsics: simd_float3x3,
        imageResolution: CGSize,
        portrait: Bool = true
    ) -> PortionScale? {
        let camera = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        let right = SIMD3<Float>(cameraTransform.columns.0.x, cameraTransform.columns.0.y, cameraTransform.columns.0.z)
        let upward = SIMD3<Float>(cameraTransform.columns.1.x, cameraTransform.columns.1.y, cameraTransform.columns.1.z)
        let back = SIMD3<Float>(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
        guard simd_length(back) > 0, simd_length(planeNormal) > 0 else { return nil }
        let up = simd_normalize(planeNormal)

        let height = simd_dot(camera - planePoint, up)
        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y
        let width = Float(imageResolution.width)
        let rows = Float(imageResolution.height)
        guard height > 0, fx > 0, fy > 0, width > 0, rows > 0 else { return nil }

        /// Where the ray through sensor pixel (u, v) meets the table.
        func tablePoint(u: Float, v: Float) -> SIMD3<Float>? {
            let ray = right * ((u - cx) / fx) + upward * (-(v - cy) / fy) - back
            let toward = simd_dot(ray, up)
            guard toward < 0 else { return nil }
            let t = -height / toward
            return t > 0 ? camera + ray * t : nil
        }
        // A tilted view sees more table on its far side, so span the table along
        // the image's centre lines instead of assuming it faces the camera.
        guard let left = tablePoint(u: 0, v: cy),
              let rightEdge = tablePoint(u: width, v: cy),
              let top = tablePoint(u: cx, v: 0),
              let bottom = tablePoint(u: cx, v: rows) else { return nil }
        let sensorWidthCm = Double(simd_distance(left, rightEdge)) * 100
        let sensorHeightCm = Double(simd_distance(top, bottom)) * 100

        let forward = -simd_normalize(back)
        let cosine = min(1, max(-1, Double(simd_dot(forward, -up))))
        return PortionScale(
            cameraHeightCm: Double(height) * 100,
            tiltDegrees: acos(cosine) * 180 / .pi,
            photoWidthCm: portrait ? sensorHeightCm : sensorWidthCm,
            photoHeightCm: portrait ? sensorWidthCm : sensorHeightCm
        )
    }

    /// AI-facing English, like the rest of the analysis prompt. Photos without a
    /// usable measurement are skipped; nil when none has one.
    static func promptSection(for scales: [PortionScale?]) -> String? {
        let lines = scales.enumerated().compactMap { index, scale -> String? in
            guard let scale, scale.readiness == .ready else { return nil }
            let angle = scale.tiltDegrees < 10 ? "straight down" : "nearly straight down"
            return "- Photo \(index + 1): taken from about \(Self.wholeCm(scale.cameraHeightCm)) cm above the table, looking \(angle). "
                + "Through its centre, the photo spans about \(Self.wholeCm(scale.photoWidthCm)) cm of table across and \(Self.wholeCm(scale.photoHeightCm)) cm top to bottom."
        }
        guard !lines.isEmpty else { return nil }
        return """
        REAL-WORLD SCALE (measured with the phone's AR camera)
        \(lines.joined(separator: "\n"))
        Use these measurements to judge the real size of plates, bowls, cutlery and food instead of assuming typical sizes. Estimate each food's volume from its real footprint and visible height, then its weight from typical density. Visible kitchen-scale readings and nutrition labels still take priority.
        """
    }

    private static func wholeCm(_ value: Double) -> String {
        String(Int(value.rounded()))
    }
}

/// Keeps each AR photo's measurement with the image until analysis, so capture,
/// multi-photo and retry paths need no extra plumbing. Entries go with the image.
enum PortionScaleRegistry {
    private final class Box {
        let scale: PortionScale
        init(_ scale: PortionScale) { self.scale = scale }
    }

    private static let table = NSMapTable<UIImage, Box>.weakToStrongObjects()

    static func attach(_ scale: PortionScale, to image: UIImage) {
        table.setObject(Box(scale), forKey: image)
    }

    static func scale(for image: UIImage) -> PortionScale? {
        table.object(forKey: image)?.scale
    }
}
