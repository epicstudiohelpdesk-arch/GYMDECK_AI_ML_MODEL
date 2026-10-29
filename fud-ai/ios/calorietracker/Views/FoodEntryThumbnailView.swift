import SwiftUI
import UIKit

/// Downsampled food photo for list rows — mirrors Android `loadThumbnail`.
struct FoodEntryThumbnailView: View {
    let photos: [FoodEntryPhoto]
    var additionalCount: Int = 0
    var size: CGFloat = 56
    var maxPixelSize: Int = FoodImageStore.thumbnailMaxDimension
    var showsAdditionalBadge = true
    var onPhotoLoaded: ((FoodEntryPhoto.ID?) -> Void)? = nil

    @State private var image: UIImage?

    private var hasPhoto: Bool {
        !photos.isEmpty
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(AppColors.calorie.opacity(0.15), lineWidth: 1)
                    )
                    .overlay(alignment: .bottomTrailing) {
                        if showsAdditionalBadge, additionalCount > 0 {
                            Text("+\(additionalCount)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.65), in: Capsule())
                                .padding(4)
                        }
                    }
            } else if hasPhoto {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .frame(width: size, height: size)
            }
        }
        .task(id: loadTaskID) {
            image = nil
            onPhotoLoaded?(nil)
            let loaded = await FoodEntryPhotoLoader.thumbnail(from: photos, maxPixelSize: maxPixelSize)
            guard !Task.isCancelled else { return }
            image = loaded?.image
            onPhotoLoaded?(loaded?.id)
        }
    }

    private struct LoadTaskID: Equatable {
        let photos: [FoodEntryPhoto]
        let maxPixelSize: Int
    }

    private var loadTaskID: LoadTaskID {
        LoadTaskID(photos: photos, maxPixelSize: maxPixelSize)
    }
}

enum FoodEntryPhotoLoader {
    struct LoadedPhoto {
        let id: FoodEntryPhoto.ID
        let image: UIImage
    }

    static func thumbnail(from photos: [FoodEntryPhoto], maxPixelSize: Int) async -> LoadedPhoto? {
        await Task.detached(priority: .utility) { () -> LoadedPhoto? in
            for photo in photos {
                if case let .filename(filename) = photo.id,
                   let image = FoodImageStore.shared.loadThumbnail(filename: filename, maxPixelSize: maxPixelSize) {
                    return LoadedPhoto(id: photo.id, image: image)
                }
                if let data = photo.data, let image = UIImage(data: data) {
                    return LoadedPhoto(id: photo.id, image: image)
                }
            }
            return nil
        }.value
    }

    static func viewerPreview(for entry: FoodEntry, matching thumbnailID: FoodEntryPhoto.ID?) async -> FullScreenImagePreview? {
        let photos = entry.photoSources
        let preferredID = thumbnailID ?? entry.thumbnailPhotoCandidates.first?.id
        let loaded = await Task.detached(priority: .userInitiated) {
            photos.compactMap { photo -> LoadedPhoto? in
                if case let .filename(filename) = photo.id,
                   let image = FoodImageStore.shared.loadForViewer(filename: filename) {
                    return LoadedPhoto(id: photo.id, image: image)
                }
                return photo.data.flatMap(UIImage.init(data:)).map { LoadedPhoto(id: photo.id, image: $0) }
            }
        }.value
        guard !loaded.isEmpty else { return nil }
        return FullScreenImagePreview(
            images: loaded.map(\.image),
            initialIndex: loaded.firstIndex { $0.id == preferredID } ?? 0
        )
    }
}
