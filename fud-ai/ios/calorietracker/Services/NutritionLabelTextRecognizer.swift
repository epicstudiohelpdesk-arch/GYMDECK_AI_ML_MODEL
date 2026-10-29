import CoreGraphics
import ImageIO
import UIKit
import Vision

/// Reads nutrition label text on this iPhone with Vision so the on-device
/// photo models can use the printed numbers (#486). The text never leaves the
/// device: only Apple Intelligence and Gemma prompts include it.
enum NutritionLabelTextRecognizer {
    /// Label rows for each photo that looks like a nutrition label, in photo
    /// order. Empty when no photo does or recognition fails. Throws
    /// `CancellationError` when the scan is cancelled, after stopping the
    /// Vision request in progress.
    static func labelText(in images: [UIImage]) async throws -> [NutritionLabelPhotoText] {
        var photos: [NutritionLabelPhotoText] = []
        for (index, image) in images.prefix(NutritionLabelText.maxPhotos).enumerated() {
            try Task.checkCancellation()
            guard let upright = uprightImage(for: image) else { continue }
            let request = TextRequest()
            // A detached task does not inherit cancellation, so stop Vision
            // directly when the scan is cancelled.
            let lines = await withTaskCancellationHandler {
                await Task.detached(priority: .userInitiated) {
                    NutritionLabelText.lines(from: request.recognize(in: upright.image, orientation: upright.orientation))
                }.value
            } onCancel: {
                request.cancel()
            }
            try Task.checkCancellation()
            if NutritionLabelText.isLikelyNutritionLabel(lines) {
                photos.append(NutritionLabelPhotoText(photoNumber: index + 1, lines: lines))
            }
        }
        return photos
    }

    /// The bitmap plus its EXIF orientation, so Vision's boxes are relative to
    /// the photo as the user sees it.
    private static func uprightImage(for image: UIImage) -> (image: CGImage, orientation: CGImagePropertyOrientation)? {
        if let cgImage = image.cgImage {
            return (cgImage, CGImagePropertyOrientation(image.imageOrientation))
        }
        guard image.size.width > 0, image.size.height > 0,
              let rendered = UIGraphicsImageRenderer(size: image.size).image(actions: { _ in
                  image.draw(at: .zero)
              }).cgImage else {
            return nil
        }
        return (rendered, .up)
    }
}

/// One Vision text request. `cancel()` may run on another thread while
/// `recognize` blocks: Vision's `VNRequest.cancel()` is meant for that.
nonisolated private final class TextRequest: @unchecked Sendable {
    private let request: VNRecognizeTextRequest

    init() {
        request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Language correction rewrites digits and units into dictionary words.
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
    }

    func cancel() {
        request.cancel()
    }

    /// Blocks until Vision finishes or is cancelled, so callers keep it off
    /// the main thread. Empty when recognition fails or is cancelled.
    func recognize(in image: CGImage, orientation: CGImagePropertyOrientation) -> [NutritionLabelText.Fragment] {
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map {
                NutritionLabelText.Fragment(
                    text: $0.string,
                    box: observation.boundingBox,
                    slope: NutritionLabelText.lineSlope(
                        topLeft: observation.topLeft,
                        topRight: observation.topRight,
                        bottomLeft: observation.bottomLeft,
                        bottomRight: observation.bottomRight
                    )
                )
            }
        }
    }
}

/// The nutrition label section for one photo request (#486). Vision reads the
/// photos at most once, and only when a model that runs on this iPhone is
/// about to get the request: the selected provider, or an on-device image
/// fallback after a cloud provider fails. Cloud and hosted requests never
/// wait for it.
final class OnDeviceLabelText {
    private let read: () async throws -> String?
    private var cached: String??

    convenience init(images: [UIImage]) {
        self.init {
            NutritionLabelText.promptSection(for: try await NutritionLabelTextRecognizer.labelText(in: images))
        }
    }

    /// - Parameter read: returns the label section, or nil when no photo has
    ///   label text.
    init(read: @escaping () async throws -> String?) {
        self.read = read
    }

    /// The label section, or nil when no photo looks like a nutrition label.
    func section() async throws -> String? {
        if let cached { return cached }
        let section = try await read()
        cached = .some(section)
        return section
    }

    /// `prompt` plus the label section for a provider that runs on this
    /// iPhone. Any other provider gets `prompt` unchanged, without reading
    /// the photos.
    func prompt(_ prompt: String, for provider: AIProvider) async throws -> String {
        guard provider.runsOnDevice else { return prompt }
        return NutritionLabelText.prompt(prompt, adding: try await section())
    }
}

extension CGImagePropertyOrientation {
    /// The EXIF orientation that shows `orientation`'s bitmap upright.
    nonisolated init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
