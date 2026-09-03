import AppKit
import OSTCore
import SwiftUI
import Translation

private final class OverlayObserverBag: @unchecked Sendable {
    private var observers: [NSObjectProtocol] = []

    func append(_ observer: NSObjectProtocol) {
        observers.append(observer)
    }

    func invalidate() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    deinit {
        invalidate()
    }
}

@MainActor
final class OverlayCoordinator {
    private struct SizingSignature: Codable, Equatable {
        let lineCount: Int
        let sourceFontSize: Double
        let translationFontSize: Double
        let previewFontSize: Double
    }

    private let state: OverlayState
    private let preferences: PreferencesStore
    private let translationPackCoordinator: TranslationPackCoordinator
    private var panels: [OverlayPanelKind: SubtitlePanel] = [:]
    private let observerBag = OverlayObserverBag()
    private var sizingSignature: SizingSignature
    private var appliedSizingSignatures: [OverlayPanelKind: SizingSignature] = [:]
    private(set) var isVisible = true
    private var appliedScreenCaptureHiding: Bool?
    private(set) var isTemporarilyRepositioning = false
    private let temporaryRepositionTimeout: Duration
    private var temporaryRepositionTask: Task<Void, Never>?

    private var effectiveLocked: Bool {
        preferences.overlayLocked && !isTemporarilyRepositioning
    }

    init(
        state: OverlayState,
        preferences: PreferencesStore,
        translationPackCoordinator: TranslationPackCoordinator,
        temporaryRepositionTimeout: Duration = .seconds(30)
    ) {
        self.state = state
        self.preferences = preferences
        self.translationPackCoordinator = translationPackCoordinator
        self.temporaryRepositionTimeout = temporaryRepositionTimeout
        sizingSignature = SizingSignature(
            lineCount: preferences.overlayLineCount,
            sourceFontSize: preferences.sourceFontSize,
            translationFontSize: preferences.translationFontSize,
            previewFontSize: preferences.previewFontSize
        )
        for kind in [OverlayPanelKind.combined, .source, .translation] {
            if let data = UserDefaults.standard.data(forKey: sizingDefaultsKey(for: kind)),
               let signature = try? JSONDecoder().decode(SizingSignature.self, from: data) {
                appliedSizingSignatures[kind] = signature
            }
        }
        observerBag.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restorePanelsToVisibleScreens() }
        })
    }

    deinit {
        temporaryRepositionTask?.cancel()
        observerBag.invalidate()
    }

    func show() {
        isVisible = true
        applyPreferences()
    }

    func hide() {
        isVisible = false
        temporaryRepositionTask?.cancel()
        temporaryRepositionTask = nil
        isTemporarilyRepositioning = false
        state.isRepositioning = false
        panels.values.forEach { $0.orderOut(nil) }
    }

    func toggleVisibility() {
        isVisible ? hide() : show()
    }

    func applyPreferences() {
        guard isVisible else { return }
        // A temporary unlock only means anything on top of a real lock. Turning the lock
        // off during one would leave the accent border and the "finish" entry sitting on
        // an overlay that is already unlocked, waiting out a timer for nothing. Cleared
        // inline rather than through endTemporaryReposition(), which calls back into here.
        if isTemporarilyRepositioning, !preferences.overlayLocked {
            temporaryRepositionTask?.cancel()
            temporaryRepositionTask = nil
            isTemporarilyRepositioning = false
            state.isRepositioning = false
        }
        // NSWindow.sharingType cannot be moved back off .none once it is set, so the
        // panels have to be rebuilt when the preference changes. Frame autosave restores
        // each panel's position and size, so the rebuild is invisible to the user.
        if let applied = appliedScreenCaptureHiding,
           applied != preferences.hideOverlayInScreenCapture {
            panels.values.forEach { $0.orderOut(nil) }
            panels.removeAll()
        }
        appliedScreenCaptureHiding = preferences.hideOverlayInScreenCapture
        let newSizingSignature = SizingSignature(
            lineCount: preferences.overlayLineCount,
            sourceFontSize: preferences.sourceFontSize,
            translationFontSize: preferences.translationFontSize,
            previewFontSize: preferences.previewFontSize
        )
        sizingSignature = newSizingSignature
        switch preferences.overlayLayout {
        case .combined:
            panel(for: .source).orderOut(nil)
            panel(for: .translation).orderOut(nil)
            configure(
                panel(for: .combined),
                kind: .combined,
                name: "OSTCombinedOverlay"
            )
            panel(for: .combined).orderFrontRegardless()
        case .split:
            panel(for: .combined).orderOut(nil)
            configure(
                panel(for: .source),
                kind: .source,
                name: "OSTSourceOverlay"
            )
            configure(
                panel(for: .translation),
                kind: .translation,
                name: "OSTTranslationOverlay"
            )
            panel(for: .source).orderFrontRegardless()
            panel(for: .translation).orderFrontRegardless()
        }
    }

    func resetFrames() {
        for name in ["OSTCombinedOverlay", "OSTSourceOverlay", "OSTTranslationOverlay"] {
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)")
        }
        panels.values.forEach { $0.orderOut(nil) }
        panels.removeAll()
        applyPreferences()
    }

    func beginTemporaryReposition() {
        guard preferences.overlayLocked, isVisible else { return }
        temporaryRepositionTask?.cancel()
        isTemporarilyRepositioning = true
        state.isRepositioning = true
        applyPreferences()
        temporaryRepositionTask = Task { [weak self, temporaryRepositionTimeout] in
            do {
                try await Task.sleep(for: temporaryRepositionTimeout)
            } catch {
                return
            }
            // Cancellation between the sleep returning and this line running would
            // otherwise let a finished session's timer end the one the user just started.
            guard !Task.isCancelled else { return }
            self?.endTemporaryReposition()
        }
    }

    func endTemporaryReposition() {
        temporaryRepositionTask?.cancel()
        temporaryRepositionTask = nil
        guard isTemporarilyRepositioning || state.isRepositioning else { return }
        isTemporarilyRepositioning = false
        state.isRepositioning = false
        applyPreferences()
    }

    private func panel(for kind: OverlayPanelKind) -> SubtitlePanel {
        if let panel = panels[kind] { return panel }
        var style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        if !effectiveLocked { style.insert(.resizable) }
        let panel = SubtitlePanel(
            contentRect: defaultFrame(for: kind),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        panel.title = title(for: kind)
        panel.level = .floating
        if preferences.hideOverlayInScreenCapture { panel.sharingType = .none }
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.minSize = minimumSize(for: kind)
        // The tracking area should deliver movement on its own, but this panel is never
        // key, so widening delivery costs nothing and the resize cursor depends on it.
        panel.acceptsMouseMovedEvents = true
        // Wrapped rather than installed directly: a borderless panel has no resize frame of
        // its own, and the hosting view would claim every point for its drag gesture.
        panel.contentView = SubtitleResizeHostView(
            contentView: NSHostingView(rootView: TranslationTaskOverlayRoot(
                kind: kind,
                state: state,
                preferences: preferences,
                translationPackCoordinator: translationPackCoordinator
            )),
            isLocked: effectiveLocked
        )
        panels[kind] = panel
        return panel
    }

    private func configure(
        _ panel: SubtitlePanel,
        kind: OverlayPanelKind,
        name: String
    ) {
        let resizeToPreferred = appliedSizingSignatures[kind] != sizingSignature
        let minimumSize = minimumSize(for: kind)
        panel.minSize = minimumSize
        panel.ignoresMouseEvents = effectiveLocked
        (panel.contentView as? SubtitleResizeHostView)?.setLocked(effectiveLocked)
        panel.isMovableByWindowBackground = !effectiveLocked
        if effectiveLocked {
            panel.styleMask.remove(.resizable)
        } else {
            panel.styleMask.insert(.resizable)
        }
        if panel.frameAutosaveName != name {
            panel.setFrameAutosaveName(name)
            _ = panel.setFrameUsingName(name)
        }
        if resizeToPreferred
            || panel.frame.width < minimumSize.width
            || panel.frame.height < minimumSize.height {
            var frame = panel.frame
            frame.size.width = max(frame.width, minimumSize.width)
            frame.size.height = resizeToPreferred
                ? minimumSize.height
                : max(frame.height, minimumSize.height)
            panel.setFrame(frame, display: true)
        }
        clamp(panel)
        appliedSizingSignatures[kind] = sizingSignature
        if let data = try? JSONEncoder().encode(sizingSignature) {
            UserDefaults.standard.set(data, forKey: sizingDefaultsKey(for: kind))
        }
    }

    private func restorePanelsToVisibleScreens() {
        panels.values.forEach(clamp)
    }

    private func clamp(_ panel: NSPanel) {
        guard let primary = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame else { return }
        let frame = OverlayFrameRestorer.restoredFrame(
            stored: panel.frame,
            visibleFrames: NSScreen.screens.map(\.visibleFrame),
            primaryVisibleFrame: primary,
            defaultSize: panel.frame.size
        )
        panel.setFrame(frame, display: true)
    }

    private func defaultFrame(for kind: OverlayPanelKind) -> NSRect {
        guard let visible = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame else {
            return NSRect(x: 100, y: 100, width: 720, height: 180)
        }
        switch kind {
        case .combined:
            return OverlayFrameRestorer.restoredFrame(
                stored: nil,
                visibleFrames: [visible],
                primaryVisibleFrame: visible,
                defaultSize: preferredSize(for: .combined)
            )
        case .translation:
            let size = preferredSize(for: .translation)
            return NSRect(x: visible.midX - 360, y: visible.minY + 48, width: size.width, height: size.height)
        case .source:
            let sourceSize = preferredSize(for: .source)
            let translationHeight = preferredSize(for: .translation).height
            return NSRect(
                x: visible.midX - 360,
                y: visible.minY + 60 + translationHeight,
                width: sourceSize.width,
                height: sourceSize.height
            )
        }
    }

    private func preferredSize(for kind: OverlayPanelKind) -> NSSize {
        let maximumHeight = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 900
        switch kind {
        case .combined:
            return OverlaySizing.combinedSize(
                lineCount: preferences.overlayLineCount,
                sourceFontSize: preferences.sourceFontSize,
                translationFontSize: preferences.translationFontSize,
                previewFontSize: preferences.previewFontSize,
                maximumHeight: maximumHeight
            )
        case .source:
            return OverlaySizing.sourceSize(
                lineCount: preferences.overlayLineCount,
                fontSize: preferences.sourceFontSize,
                maximumHeight: maximumHeight
            )
        case .translation:
            return OverlaySizing.translationSize(
                lineCount: preferences.overlayLineCount,
                fontSize: preferences.translationFontSize,
                previewFontSize: preferences.previewFontSize,
                maximumHeight: maximumHeight
            )
        }
    }

    private func minimumSize(for kind: OverlayPanelKind) -> NSSize {
        let preferred = preferredSize(for: kind)
        return NSSize(width: 320, height: preferred.height)
    }

    private func title(for kind: OverlayPanelKind) -> String {
        switch kind {
        case .combined: "OST Subtitles"
        case .source: "OST Transcript"
        case .translation: "OST Translation"
        }
    }

    private func sizingDefaultsKey(for kind: OverlayPanelKind) -> String {
        switch kind {
        case .combined: "OSTCombinedOverlay.sizing.v3"
        case .source: "OSTSourceOverlay.sizing.v3"
        case .translation: "OSTTranslationOverlay.sizing.v3"
        }
    }
}

private struct TranslationTaskOverlayRoot: View {
    let kind: OverlayPanelKind
    @ObservedObject var state: OverlayState
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var translationPackCoordinator: TranslationPackCoordinator

    var body: some View {
        OverlayContentView(
            kind: kind,
            state: state,
            preferences: preferences
        )
        .translationTask(hostedConfiguration) { session in
            await translationPackCoordinator.prepare(using: session)
        }
    }

    private var hostedConfiguration: TranslationSession.Configuration? {
        switch (preferences.overlayLayout, kind) {
        case (.combined, .combined), (.split, .source):
            translationPackCoordinator.configuration
        default:
            nil
        }
    }
}
