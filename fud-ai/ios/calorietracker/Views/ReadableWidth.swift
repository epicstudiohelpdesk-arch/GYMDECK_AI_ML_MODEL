import SwiftUI

extension View {
    /// Keeps a screen's content in a centered column on iPad, so cards and rows don't
    /// stretch edge to edge. Narrower screens, phones included, are unchanged.
    func readableWidth(_ maxWidth: CGFloat = 760) -> some View {
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}
