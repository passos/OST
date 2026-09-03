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
/// layer reads these rects for both `resetCursorRects()` and `hitTest(_:)`, so the cursor and
/// the drag always agree about where the resize band is.
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

    /// One rect per edge, all inside `bounds`, for registering cursor rects.
    public static func rects(
        in bounds: CGRect,
        margin: CGFloat = defaultMargin
    ) -> [OverlayResizeEdge: CGRect] {
        let margin = effectiveMargin(in: bounds, margin: margin)
        guard margin > 0 else { return [:] }
        let innerWidth = max(0, bounds.width - margin * 2)
        let innerHeight = max(0, bounds.height - margin * 2)

        return [
            .bottomLeading: CGRect(x: bounds.minX, y: bounds.minY, width: margin, height: margin),
            .bottomTrailing: CGRect(x: bounds.maxX - margin, y: bounds.minY, width: margin, height: margin),
            .topLeading: CGRect(x: bounds.minX, y: bounds.maxY - margin, width: margin, height: margin),
            .topTrailing: CGRect(x: bounds.maxX - margin, y: bounds.maxY - margin, width: margin, height: margin),
            .bottom: CGRect(x: bounds.minX + margin, y: bounds.minY, width: innerWidth, height: margin),
            .top: CGRect(x: bounds.minX + margin, y: bounds.maxY - margin, width: innerWidth, height: margin),
            .leading: CGRect(x: bounds.minX, y: bounds.minY + margin, width: margin, height: innerHeight),
            .trailing: CGRect(x: bounds.maxX - margin, y: bounds.minY + margin, width: margin, height: innerHeight),
        ]
    }
}
