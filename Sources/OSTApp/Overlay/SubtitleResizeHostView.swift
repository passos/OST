import AppKit
import OSTCore

/// Gives the borderless overlay panel a resize band with a real cursor.
///
/// AppKit hands a borderless window no resize frame even when it is `.resizable`, and the
/// SwiftUI hosting view claims every point for its window-drag gesture — so both the cursor
/// and the drag itself have to be provided here. The geometry lives in `OverlayResizeGeometry`
/// so it stays testable without a window, and so the cursor rects and the hit test can never
/// disagree about where the band is.
final class SubtitleResizeHostView: NSView {
    private(set) var isLocked: Bool

    private var dragEdge: OverlayResizeEdge?
    private var dragStart: CGPoint = .zero
    private var dragFrame: CGRect = .zero

    init(contentView: NSView, isLocked: Bool) {
        self.isLocked = isLocked
        super.init(frame: contentView.bounds)
        contentView.frame = bounds
        contentView.autoresizingMask = [.width, .height]
        addSubview(contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SubtitleResizeHostView is not loaded from a nib") }

    func setLocked(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        if locked { dragEdge = nil }
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard !isLocked else { return }
        for (edge, rect) in OverlayResizeGeometry.rects(in: bounds) {
            addCursorRect(rect, cursor: Self.cursor(for: edge))
        }
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
