import CoreGraphics

/// Which part of the overlay panel's edge a point falls in.
public enum OverlayResizeEdge: String, CaseIterable, Sendable {
    case top
    case bottom
    case leading
    case trailing
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing
}

/// Hit-test geometry for resizing the subtitle overlay.
///
/// The panel is borderless, so AppKit gives it no resize frame of its own and the SwiftUI
/// hosting view would otherwise claim every point for its window-drag gesture. The AppKit
/// AppKit layer answers both the cursor and the hit test from `edge(at:in:)`, so the two can
/// never disagree about where the resize band is.
///
/// Coordinates are unflipped AppKit view coordinates: y grows upwards.
public enum OverlayResizeGeometry {
    /// Width of the band along each side, in points.
    public static let defaultMargin: CGFloat = 8

    /// The band width actually used for `bounds`. Clamped to just under half of the smaller
    /// dimension so opposite bands never overlap — otherwise a point could read as near both
    /// sides at once and the winner would depend on the order the branches are evaluated.
    public static func effectiveMargin(in bounds: CGRect, margin: CGFloat = defaultMargin) -> CGFloat {
        let limit = min(bounds.width, bounds.height) / 2
        return max(0, min(margin, limit))
    }

    /// The edge `point` belongs to, or `nil` when it is in the interior or outside `bounds`.
    public static func edge(
        at point: CGPoint,
        in bounds: CGRect,
        margin: CGFloat = defaultMargin
    ) -> OverlayResizeEdge? {
        guard bounds.contains(point) else { return nil }
        let margin = effectiveMargin(in: bounds, margin: margin)
        guard margin > 0 else { return nil }

        let leading = point.x - bounds.minX < margin
        let trailing = bounds.maxX - point.x < margin
        let bottom = point.y - bounds.minY < margin
        let top = bounds.maxY - point.y < margin

        switch (top, bottom, leading, trailing) {
        case (true, _, true, _): return .topLeading
        case (true, _, _, true): return .topTrailing
        case (_, true, true, _): return .bottomLeading
        case (_, true, _, true): return .bottomTrailing
        case (true, _, _, _): return .top
        case (_, true, _, _): return .bottom
        case (_, _, true, _): return .leading
        case (_, _, _, true): return .trailing
        default: return nil
        }
    }

    /// The frame a drag of `translation` on `edge` produces, clamped to `minimumSize`.
    ///
    /// `translation` is in AppKit screen deltas (y grows upwards). Dragging a leading or
    /// bottom edge moves the origin so the opposite edge stays where it is; clamping at the
    /// minimum therefore has to clamp the origin as well, or shrinking past the limit would
    /// walk the whole window sideways.
    public static func resizedFrame(
        _ frame: CGRect,
        edge: OverlayResizeEdge,
        translation: CGSize,
        minimumSize: CGSize
    ) -> CGRect {
        var result = frame

        switch edge {
        case .leading, .topLeading, .bottomLeading:
            let width = max(minimumSize.width, frame.width - translation.width)
            result.origin.x = frame.maxX - width
            result.size.width = width
        case .trailing, .topTrailing, .bottomTrailing:
            result.size.width = max(minimumSize.width, frame.width + translation.width)
        case .top, .bottom:
            break
        }

        switch edge {
        case .bottom, .bottomLeading, .bottomTrailing:
            let height = max(minimumSize.height, frame.height - translation.height)
            result.origin.y = frame.maxY - height
            result.size.height = height
        case .top, .topLeading, .topTrailing:
            result.size.height = max(minimumSize.height, frame.height + translation.height)
        case .leading, .trailing:
            break
        }

        return result
    }
}
