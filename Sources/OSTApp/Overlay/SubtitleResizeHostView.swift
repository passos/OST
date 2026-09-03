import AppKit
import OSTCore

/// Gives the borderless overlay panel a resize band with a real cursor.
///
/// AppKit hands a borderless window no resize frame even when it is `.resizable`, and the
/// SwiftUI hosting view claims every point for its window-drag gesture — so both the cursor
/// and the drag itself have to be provided here. The geometry lives in `OverlayResizeGeometry`
/// so it stays testable without a window, and so the cursor and the hit test can never
/// disagree about where the band is.
///
/// The cursor deliberately does not go through `resetCursorRects`. Cursor rects are the
/// key-window mechanism, and this panel is never key -- `SubtitlePanel.canBecomeKey` is
/// false, the style mask carries `.nonactivatingPanel`, and the app runs as `.accessory`.
/// An `.activeAlways` tracking area is the only route that still delivers pointer movement
/// while OST sits behind whatever the user is actually watching.
final class SubtitleResizeHostView: NSView {
    private(set) var isLocked: Bool

    /// The edge the cursor currently advertises, or nil when it is showing the plain arrow.
    /// Kept so a pointer crossing the band does not re-set the same cursor on every event.
    private(set) var activeCursorEdge: OverlayResizeEdge?

    private var dragEdge: OverlayResizeEdge?
    private var dragStart: CGPoint = .zero
    private var dragFrame: CGRect = .zero

    init(contentView: NSView, isLocked: Bool) {
        self.isLocked = isLocked
        super.init(frame: contentView.bounds)
        contentView.frame = bounds
        contentView.autoresizingMask = [.width, .height]
        addSubview(contentView)
        updateTrackingAreas()
    }

    /// Background-drag propagation would otherwise reach the band's own clicks.
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self
            )
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SubtitleResizeHostView is not loaded from a nib") }

    func setLocked(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        if locked { dragEdge = nil }
        applyCursor(for: nil)
    }

    /// Selects the cursor for a pointer sitting at `point` in this view's coordinates.
    /// Exposed so the band's cursor can be tested without a key window to host it.
    func updateResizeCursor(at point: CGPoint) {
        applyCursor(for: isLocked ? nil : OverlayResizeGeometry.edge(at: point, in: bounds))
    }

    private func applyCursor(for edge: OverlayResizeEdge?) {
        guard edge != activeCursorEdge else { return }
        activeCursorEdge = edge
        (edge.map(Self.cursor(for:)) ?? .arrow).set()
    }

    override func mouseMoved(with event: NSEvent) {
        updateResizeCursor(at: convert(event.locationInWindow, from: nil))
        super.mouseMoved(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        updateResizeCursor(at: convert(event.locationInWindow, from: nil))
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        applyCursor(for: nil)
        super.mouseExited(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isLocked else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        guard OverlayResizeGeometry.edge(at: local, in: bounds) != nil else {
            return super.hitTest(point)
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard !isLocked,
              let window,
              let edge = OverlayResizeGeometry.edge(at: local, in: bounds) else {
            super.mouseDown(with: event)
            return
        }
        dragEdge = edge
        dragStart = NSEvent.mouseLocation
        dragFrame = window.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragEdge, let window else {
            super.mouseDragged(with: event)
            return
        }
        let current = NSEvent.mouseLocation
        window.setFrame(
            OverlayResizeGeometry.resizedFrame(
                dragFrame,
                edge: dragEdge,
                translation: CGSize(
                    width: current.x - dragStart.x,
                    height: current.y - dragStart.y
                ),
                minimumSize: window.minSize
            ),
            display: true
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard dragEdge != nil else {
            super.mouseUp(with: event)
            return
        }
        dragEdge = nil
    }

    /// macOS publishes no diagonal resize cursor. Rather than reach for a private one, corners
    /// show the crosshair: it reads as "this point is grabbable" without claiming an axis.
    private static func cursor(for edge: OverlayResizeEdge) -> NSCursor {
        switch edge {
        case .top, .bottom: .resizeUpDown
        case .leading, .trailing: .resizeLeftRight
        case .topLeading, .topTrailing, .bottomLeading, .bottomTrailing: .crosshair
        }
    }
}
