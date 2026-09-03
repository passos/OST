import CoreGraphics
import Foundation
import OSTCore
import Testing

private let bounds = CGRect(x: 0, y: 0, width: 400, height: 200)

@Test func overlayResizeEdgeIsNilInTheInterior() {
    #expect(OverlayResizeGeometry.edge(at: CGPoint(x: 200, y: 100), in: bounds) == nil)
}

@Test func overlayResizeEdgeIsDetectedOnEachSide() {
    #expect(OverlayResizeGeometry.edge(at: CGPoint(x: 200, y: 2), in: bounds) == .bottom)
    #expect(OverlayResizeGeometry.edge(at: CGPoint(x: 200, y: 198), in: bounds) == .top)
    #expect(OverlayResizeGeometry.edge(at: CGPoint(x: 2, y: 100), in: bounds) == .leading)
    #expect(OverlayResizeGeometry.edge(at: CGPoint(x: 398, y: 100), in: bounds) == .trailing)
}

/// A corner is in two edge bands at once; it must resolve to the corner, otherwise the
/// diagonal resize handle is unreachable.
@Test func overlayResizeCornersWinOverEdges() {
    #expect(OverlayResizeGeometry.edge(at: CGPoint(x: 2, y: 2), in: bounds) == .bottomLeading)
    #expect(OverlayResizeGeometry.edge(at: CGPoint(x: 398, y: 2), in: bounds) == .bottomTrailing)
    #expect(OverlayResizeGeometry.edge(at: CGPoint(x: 2, y: 198), in: bounds) == .topLeading)
    #expect(OverlayResizeGeometry.edge(at: CGPoint(x: 398, y: 198), in: bounds) == .topTrailing)
}

@Test func overlayResizeEdgeIsNilOutsideTheBounds() {
    #expect(OverlayResizeGeometry.edge(at: CGPoint(x: -1, y: 100), in: bounds) == nil)
    #expect(OverlayResizeGeometry.edge(at: CGPoint(x: 401, y: 100), in: bounds) == nil)
    #expect(OverlayResizeGeometry.edge(at: CGPoint(x: 200, y: -1), in: bounds) == nil)
    #expect(OverlayResizeGeometry.edge(at: CGPoint(x: 200, y: 201), in: bounds) == nil)
}

@Test func overlayResizeMarginIsHonoured() {
    // Just inside the margin, and just outside it.
    #expect(OverlayResizeGeometry.edge(at: CGPoint(x: 200, y: 7.9), in: bounds, margin: 8) == .bottom)
    #expect(OverlayResizeGeometry.edge(at: CGPoint(x: 200, y: 8.1), in: bounds, margin: 8) == nil)
}

/// The panel has a minimum size but nothing stops a caller passing something smaller. The
/// margin has to be clamped so opposite bands stay disjoint, otherwise a point near one side
/// would also read as being near the other and the winner would depend on branch order.
@Test func overlayResizeClampsTheMarginOnUndersizedBounds() {
    let tiny = CGRect(x: 0, y: 0, width: 10, height: 10)
    // A margin wider than half the box would make every point a corner; clamped, the middle
    // is still interior.
    #expect(OverlayResizeGeometry.edge(at: CGPoint(x: 5, y: 5), in: tiny, margin: 8) == nil)
    // ...and the actual corner still resolves to a corner.
    #expect(OverlayResizeGeometry.edge(at: CGPoint(x: 0.5, y: 0.5), in: tiny, margin: 8) == .bottomLeading)
    // Repeated calls must agree; the result cannot depend on evaluation order.
    let first = OverlayResizeGeometry.edge(at: CGPoint(x: 5, y: 1), in: tiny, margin: 8)
    #expect(OverlayResizeGeometry.edge(at: CGPoint(x: 5, y: 1), in: tiny, margin: 8) == first)
}

@Test func overlayResizeRectsCoverEveryEdgeExactlyOnce() {
    let rects = OverlayResizeGeometry.rects(in: bounds)
    #expect(rects.count == OverlayResizeEdge.allCases.count)
    for edge in OverlayResizeEdge.allCases {
        #expect(rects[edge] != nil)
        #expect(rects[edge]?.isEmpty == false)
    }
}

/// Every rect must sit inside the view, or AppKit would register cursor rects off-view.
@Test func overlayResizeRectsStayInsideTheBounds() {
    for (_, rect) in OverlayResizeGeometry.rects(in: bounds) {
        #expect(bounds.contains(rect))
    }
}
