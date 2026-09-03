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

// MARK: - Resize drag arithmetic

private let start = CGRect(x: 100, y: 100, width: 400, height: 200)
private let minimum = CGSize(width: 320, height: 96)

/// Dragging the trailing edge moves only that edge; the origin must stay put.
@Test func resizingTrailingEdgeKeepsTheOrigin() {
    let frame = OverlayResizeGeometry.resizedFrame(
        start, edge: .trailing, translation: CGSize(width: 50, height: 0), minimumSize: minimum
    )
    #expect(frame.origin == start.origin)
    #expect(frame.width == 450)
    #expect(frame.height == start.height)
}

/// Dragging the leading edge has to move the origin, or the window would jump.
@Test func resizingLeadingEdgeMovesTheOrigin() {
    let frame = OverlayResizeGeometry.resizedFrame(
        start, edge: .leading, translation: CGSize(width: -50, height: 0), minimumSize: minimum
    )
    #expect(frame.minX == 50)
    #expect(frame.width == 450)
    #expect(frame.maxX == start.maxX)
}

@Test func resizingBottomEdgeMovesTheOrigin() {
    let frame = OverlayResizeGeometry.resizedFrame(
        start, edge: .bottom, translation: CGSize(width: 0, height: -30), minimumSize: minimum
    )
    #expect(frame.minY == 70)
    #expect(frame.height == 230)
    #expect(frame.maxY == start.maxY)
}

@Test func resizingACornerMovesBothAxes() {
    let frame = OverlayResizeGeometry.resizedFrame(
        start, edge: .bottomLeading, translation: CGSize(width: -20, height: -10), minimumSize: minimum
    )
    #expect(frame.minX == 80)
    #expect(frame.minY == 90)
    #expect(frame.width == 420)
    #expect(frame.height == 210)
}

/// The minimum must clamp the size AND stop the far edge from walking, otherwise shrinking
/// past the limit drags the whole window across the screen.
@Test func resizingStopsAtTheMinimumWithoutMovingTheOppositeEdge() {
    let frame = OverlayResizeGeometry.resizedFrame(
        start, edge: .leading, translation: CGSize(width: 500, height: 0), minimumSize: minimum
    )
    #expect(frame.width == minimum.width)
    #expect(frame.maxX == start.maxX, "the trailing edge must not move while dragging the leading one")
}

@Test func resizingStopsAtTheMinimumHeight() {
    let frame = OverlayResizeGeometry.resizedFrame(
        start, edge: .bottom, translation: CGSize(width: 0, height: 500), minimumSize: minimum
    )
    #expect(frame.height == minimum.height)
    #expect(frame.maxY == start.maxY)
}

/// An edge drag must not change the other axis at all.
@Test func resizingAnEdgeLeavesTheOtherAxisUntouched() {
    let horizontal = OverlayResizeGeometry.resizedFrame(
        start, edge: .trailing, translation: CGSize(width: 40, height: 999), minimumSize: minimum
    )
    #expect(horizontal.minY == start.minY)
    #expect(horizontal.height == start.height)

    let vertical = OverlayResizeGeometry.resizedFrame(
        start, edge: .top, translation: CGSize(width: 999, height: 40), minimumSize: minimum
    )
    #expect(vertical.minX == start.minX)
    #expect(vertical.width == start.width)
}
