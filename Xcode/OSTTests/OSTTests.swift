import Carbon
import OSTCore
@testable import OST
import Foundation
import SwiftUI
import XCTest

final class OSTTests: XCTestCase {
    func testBundledCatalogIsValid() throws {
        let catalog = try ModelCatalog.bundled()
        XCTAssertEqual(catalog.models.count, 4)
        XCTAssertNoThrow(try catalog.validate())
    }

    func testMLXMetalLibraryIsColocatedWithExecutable() throws {
        let executable = try XCTUnwrap(Bundle.main.executableURL)
        let metalLibrary = executable.deletingLastPathComponent().appending(path: "mlx.metallib")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metalLibrary.path))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: metalLibrary.path),
            "../Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
        )
    }

    func testMainPrivacyDefaults() {
        let snapshot = PreferencesSnapshot()
        XCTAssertFalse(snapshot.overlayLocked)
        XCTAssertEqual(snapshot.backgroundOpacity, 0.65)
        XCTAssertEqual(snapshot.sourceFontSize, 20)
        XCTAssertEqual(snapshot.translationFontSize, 28)
        XCTAssertEqual(snapshot.appDisplayLanguage, .english)
        XCTAssertFalse(snapshot.sessionLoggingEnabled)
        XCTAssertNil(snapshot.sessionLogDirectoryBookmark)
    }

    @MainActor
    func testFirstLaunchOverlayIsUnlockedAndSavedChoicePersists() {
        let suiteName = "OSTTests.first-launch-overlay.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstLaunch = PreferencesStore(userDefaults: defaults)
        XCTAssertFalse(firstLaunch.overlayLocked)
        firstLaunch.overlayLocked = true

        let restored = PreferencesStore(userDefaults: defaults)
        XCTAssertTrue(restored.overlayLocked)
    }

    @MainActor
    func testSavedAutomaticInputIsRepairedWhenAppleSpeechIsSelected() throws {
        let suiteName = "OSTTests.apple-speech-input.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshot = PreferencesSnapshot(
            sourceMode: .automatic,
            transcriptionProvider: .appleSpeech
        )
        defaults.set(try JSONEncoder().encode(snapshot), forKey: "OST.preferences.v1")

        let restored = PreferencesStore(userDefaults: defaults)

        guard case .fixed = restored.sourceMode else {
            return XCTFail("Apple Speech must not retain the unsupported automatic input mode")
        }
        XCTAssertEqual(restored.transcriptionProvider, .appleSpeech)

        restored.sourceMode = .automatic
        restored.selectTranscriptionProvider(.appleSpeech)
        guard case .fixed = restored.sourceMode else {
            return XCTFail("Selecting Apple Speech must repair automatic input immediately")
        }
    }

    func testAppleTranslationDisclosureIsLocalized() {
        let key = "When Apple Translation is used, macOS may send Apple non-content technical information such as the app identifier and selected language pair. Your audio, transcript, and translation text are not included."
        XCTAssertEqual(AppCopy.text(key, language: .english), key)
        XCTAssertNotEqual(AppCopy.text(key, language: .chinese), key)
        XCTAssertNotEqual(AppCopy.text(key, language: .japanese), key)
        XCTAssertNotEqual(AppCopy.text(key, language: .korean), key)
    }

    func testOverlayWindowPreviewCopyIsLocalized() {
        let keys = [
            "Overlay window preview",
            "Transcript window",
            "Translation window",
            "The current transcription preview appears here.",
            "This example follows the selected window arrangement, confirmed line count, alignment, text styles, background color, and opacity.",
        ]
        for key in keys {
            XCTAssertNotEqual(AppCopy.text(key, language: .chinese), key)
            XCTAssertNotEqual(AppCopy.text(key, language: .japanese), key)
            XCTAssertNotEqual(AppCopy.text(key, language: .korean), key)
        }
    }

    @MainActor
    func testOverlayWindowPreviewRendersCombinedAndSplitLayouts() {
        let suiteName = "OSTTests.overlay-preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(userDefaults: defaults)

        for layout in [OverlayLayout.combined, .split] {
            preferences.overlayLayout = layout
            preferences.overlayLineCount = layout == .combined ? 3 : 10
            let renderer = ImageRenderer(content:
                OverlaySettingsPreview(preferences: preferences)
                    .frame(width: 580)
                    .padding(16)
            )
            renderer.scale = 1
            XCTAssertNotNil(renderer.nsImage, "Could not render \(layout.rawValue) preview")
        }
    }

    func testMemoryPressureStatusCopyIsLocalized() {
        let key = "Memory pressure — using Apple Translation"
        XCTAssertNotEqual(AppCopy.text(key, language: .chinese), key)
        XCTAssertNotEqual(AppCopy.text(key, language: .japanese), key)
        XCTAssertNotEqual(AppCopy.text(key, language: .korean), key)
    }

    func testAllLiteralAppCopyKeysAreLocalized() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = projectRoot.appendingPathComponent("Sources/OSTApp", isDirectory: true)
        let files = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        )
        let pattern = try NSRegularExpression(
            pattern: #"\b(?:t|text)\("((?:\\.|[^"\\])*)""#
        )
        var keys: Set<String> = []

        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in pattern.matches(in: source, range: range) {
                guard let captureRange = Range(match.range(at: 1), in: source) else { continue }
                let escaped = String(source[captureRange])
                guard !escaped.contains(#"\("#) else { continue }
                let jsonString = "\"" + escaped + "\""
                keys.insert(try JSONDecoder().decode(String.self, from: Data(jsonString.utf8)))
            }
        }

        XCTAssertGreaterThan(keys.count, 100, "Localization source scan did not find the expected UI copy")
        for language in [AppDisplayLanguage.chinese, .japanese, .korean] {
            for key in keys.sorted() {
                XCTAssertNotEqual(
                    AppCopy.text(key, language: language),
                    key,
                    "Missing \(language.rawValue) translation for: \(key)"
                )
            }
        }
    }

    @MainActor
    func testSettingsRequestOpensVisibleWindow() async throws {
        let model = AppModel()
        model.openSettings(tab: .overlay)

        var settingsWindow: NSWindow?
        for _ in 0..<40 {
            settingsWindow = NSApp.windows.first {
                $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window"
            }
            if settingsWindow?.isVisible == true {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertEqual(model.selectedSettingsTab, .overlay)
        XCTAssertNotNil(settingsWindow)
        XCTAssertTrue(settingsWindow?.isVisible == true)
        settingsWindow?.orderOut(nil)
    }

    @MainActor
    func testRepeatedTranslationPackRequestsKeepTheActiveConfiguration() {
        let coordinator = TranslationPackCoordinator()
        coordinator.request(source: .english, target: .korean) {}
        let first = coordinator.configuration

        coordinator.request(source: .english, target: .korean) {}

        XCTAssertEqual(coordinator.configuration, first)
    }

    @MainActor
    func testOverlayPanelIsExcludedFromScreenCaptureUntilThePreferenceIsTurnedOff() {
        let suiteName = "OSTTests.overlay-screen-capture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = PreferencesStore(userDefaults: defaults)
        preferences.overlayLayout = .combined
        let coordinator = OverlayCoordinator(
            state: OverlayState(),
            preferences: preferences,
            translationPackCoordinator: TranslationPackCoordinator()
        )
        defer { coordinator.hide() }

        // Other tests in this file also create overlay panels, so a title lookup across
        // NSApp.windows is ambiguous; match only on windows this coordinator just added.
        func combinedPanel(addedOver existing: Set<ObjectIdentifier>) -> SubtitlePanel? {
            NSApp.windows
                .filter { !existing.contains(ObjectIdentifier($0)) }
                .compactMap { $0 as? SubtitlePanel }
                .first { $0.title == "OST Subtitles" }
        }

        let beforeShow = Set(NSApp.windows.map(ObjectIdentifier.init))
        coordinator.show()
        guard let hidden = combinedPanel(addedOver: beforeShow) else {
            return XCTFail("show() did not create the combined overlay panel.")
        }
        XCTAssertTrue(preferences.hideOverlayInScreenCapture, "the preference should default to on")
        XCTAssertEqual(hidden.sharingType, .none, "the overlay must be excluded from screen capture by default")

        // sharingType cannot be moved back off .none, so turning the preference off has to
        // rebuild the panel. Look the panel up again rather than reusing the old object.
        let beforeRebuild = Set(NSApp.windows.map(ObjectIdentifier.init))
        preferences.hideOverlayInScreenCapture = false
        coordinator.applyPreferences()
        guard let shared = combinedPanel(addedOver: beforeRebuild) else {
            return XCTFail("turning the preference off did not rebuild the combined overlay panel.")
        }
        XCTAssertNotIdentical(shared, hidden, "the panel must be rebuilt, not mutated in place")
        XCTAssertEqual(shared.sharingType, .readOnly, "turning the preference off must restore the default sharing type")
    }

    // MARK: - Menu invalidation scope (#1)

    /// AppModel.init() builds a PreferencesStore on UserDefaults.standard, so any test that
    /// mutates preferences would overwrite the developer's real settings. Snapshot and restore.
    @MainActor
    private func withPreservedStandardPreferences(_ body: () throws -> Void) rethrows {
        let key = "OST.preferences.v1"
        let saved = UserDefaults.standard.data(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try body()
    }

    @MainActor
    func testDownloadProgressDoesNotInvalidateTheMenu() {
        withPreservedStandardPreferences {
            let model = AppModel()
            var republished = 0
            let token = model.objectWillChange.sink { _ in republished += 1 }
            defer { token.cancel() }

            model.modelDownloader.statusByModelID["mlx-community/model"] = ModelDownloadStatus(
                requestID: UUID(),
                modelID: "mlx-community/model",
                revision: String(repeating: "a", count: 40),
                phase: .downloading,
                completedBytes: 1,
                totalBytes: 100
            )

            XCTAssertEqual(
                republished, 0,
                "download progress arrives every 500ms and the menu shows none of it, so it must not invalidate AppModel"
            )
        }
    }

    @MainActor
    func testTranscriptSegmentChurnDoesNotInvalidateTheMenu() {
        withPreservedStandardPreferences {
            let model = AppModel()
            var republished = 0
            let token = model.objectWillChange.sink { _ in republished += 1 }
            defer { token.cancel() }

            model.overlayState.segments = []
            model.overlayState.segments = []

            XCTAssertEqual(
                republished, 0,
                "segments change at speech rate and the menu never reads them, so they must not invalidate AppModel"
            )
        }
    }

    /// Guards against "fix" the flicker by deleting every forward: the menu really does read
    /// preferences, so that one must keep invalidating AppModel.
    @MainActor
    func testPreferenceChangesStillInvalidateTheMenu() {
        withPreservedStandardPreferences {
            let model = AppModel()
            var republished = 0
            let token = model.objectWillChange.sink { _ in republished += 1 }
            defer { token.cancel() }

            model.preferences.targetLanguage =
                model.preferences.targetLanguage == .korean ? .english : .korean

            XCTAssertGreaterThan(
                republished, 0,
                "the menu renders preference-derived labels, so preference changes must still invalidate it"
            )
        }
    }

    @MainActor
    func testRepeatedIdenticalCaptureStatusDoesNotInvalidateTheMenu() {
        withPreservedStandardPreferences {
            let model = AppModel()
            model.overlayState.statusText = "Capturing"
            model.overlayState.detectedLanguage = .english

            var republished = 0
            let token = model.objectWillChange.sink { _ in republished += 1 }
            defer { token.cancel() }

            // handleTranscript reassigns both of these on every transcript event, almost always
            // to the value they already hold. The menu must not rebuild for a no-op assignment.
            for _ in 0..<5 {
                model.overlayState.statusText = "Capturing"
                model.overlayState.detectedLanguage = .english
            }

            XCTAssertEqual(
                republished, 0,
                "re-assigning the same status and language must not invalidate the menu"
            )

            // Forward direction: de-duplicating must not mean the menu stops seeing values.
            // Deleting the mirror sinks entirely would otherwise leave every assertion above
            // satisfied while the menu froze at its initial text.
            XCTAssertEqual(model.menuStatusText, "Capturing")
            XCTAssertEqual(model.menuDetectedLanguage, .english)

            model.overlayState.statusText = "Silence"
            XCTAssertEqual(model.menuStatusText, "Silence", "a real status change must reach the menu")
            XCTAssertEqual(republished, 1, "and it must invalidate the menu exactly once")
        }
    }

    /// AppModel no longer forwards the downloader's changes, so SettingsView has to observe it
    /// itself or the download rows silently stop updating — with no compiler error. Assert the
    /// property wrapper structurally, since the rows themselves need a GUI to exercise.
    @MainActor
    func testSettingsViewObservesTheDownloaderItself() {
        withPreservedStandardPreferences {
            let model = AppModel()
            let view = SettingsView(model: model, downloader: model.modelDownloader)
            let wrapper = Mirror(reflecting: view).children
                .first { $0.label == "_downloader" }
            XCTAssertNotNil(wrapper, "SettingsView must hold the downloader in a property wrapper")
            XCTAssertTrue(
                wrapper?.value is ObservedObject<ModelDownloaderClient>,
                "SettingsView must observe ModelDownloaderClient directly, not through AppModel"
            )
        }
    }

    // MARK: - Overlay resize band (#2)

    @MainActor
    private func makeOverlayCoordinator(
        _ defaults: UserDefaults,
        locked: Bool = false
    ) -> (OverlayCoordinator, PreferencesStore) {
        let preferences = PreferencesStore(userDefaults: defaults)
        preferences.overlayLayout = .combined
        preferences.overlayLocked = locked
        return (
            OverlayCoordinator(
                state: OverlayState(),
                preferences: preferences,
                translationPackCoordinator: TranslationPackCoordinator()
            ),
            preferences
        )
    }

    @MainActor
    private func combinedPanel(addedOver existing: Set<ObjectIdentifier>) -> SubtitlePanel? {
        NSApp.windows
            .filter { !existing.contains(ObjectIdentifier($0)) }
            .compactMap { $0 as? SubtitlePanel }
            .first { $0.title == "OST Subtitles" }
    }

    /// A borderless panel has no resize frame of its own, so the band has to come from the
    /// content view. If the hosting view is installed directly the edges are unreachable.
    @MainActor
    func testOverlayPanelInstallsTheResizeHostView() {
        let suiteName = "OSTTests.resize-host.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let (coordinator, _) = makeOverlayCoordinator(defaults)
        defer { coordinator.hide() }
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        coordinator.show()
        guard let panel = combinedPanel(addedOver: before) else {
            return XCTFail("show() did not create the combined overlay panel.")
        }
        XCTAssertTrue(
            panel.contentView is SubtitleResizeHostView,
            "the panel's content view must provide the resize band"
        )
    }

    /// The band must claim its own points, or the SwiftUI drag gesture swallows them and the
    /// user can only ever move the window, never resize it.
    @MainActor
    func testResizeBandClaimsEdgePointsButNotTheInterior() {
        let suiteName = "OSTTests.resize-hit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let (coordinator, _) = makeOverlayCoordinator(defaults)
        defer { coordinator.hide() }
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        coordinator.show()
        guard let host = combinedPanel(addedOver: before)?.contentView as? SubtitleResizeHostView else {
            return XCTFail("the panel did not install a SubtitleResizeHostView.")
        }

        let bounds = host.bounds
        XCTAssertIdentical(
            host.hitTest(host.convert(CGPoint(x: bounds.midX, y: 2), to: host.superview)), host,
            "a point on the bottom edge must belong to the resize band"
        )
        XCTAssertFalse(
            host.hitTest(host.convert(CGPoint(x: bounds.midX, y: bounds.midY), to: host.superview)) === host,
            "the interior must fall through to the SwiftUI content"
        )
    }

    /// Locking the overlay passes clicks through, so it must also stop offering a resize band.
    @MainActor
    func testLockedOverlayOffersNoResizeBand() {
        let suiteName = "OSTTests.resize-locked.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let (coordinator, _) = makeOverlayCoordinator(defaults, locked: true)
        defer { coordinator.hide() }
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        coordinator.show()
        guard let host = combinedPanel(addedOver: before)?.contentView as? SubtitleResizeHostView else {
            return XCTFail("the panel did not install a SubtitleResizeHostView.")
        }

        XCTAssertTrue(host.isLocked, "the host view must be told the overlay is locked")
        let bounds = host.bounds
        XCTAssertFalse(
            host.hitTest(host.convert(CGPoint(x: bounds.midX, y: 2), to: host.superview)) === host,
            "a locked overlay must not claim its edges for resizing"
        )
    }

    /// The construction path already reads the preference, so a test that only locks before
    /// show() passes even with the update path removed. Toggling on a live panel is what
    /// actually needs covering — the same shape of gap that let a broken "off" branch ship
    /// for the screen-capture preference.
    @MainActor
    func testTogglingTheLockOnALivePanelReachesTheResizeBand() {
        let suiteName = "OSTTests.resize-toggle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let (coordinator, preferences) = makeOverlayCoordinator(defaults, locked: false)
        defer { coordinator.hide() }
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        coordinator.show()
        guard let host = combinedPanel(addedOver: before)?.contentView as? SubtitleResizeHostView else {
            return XCTFail("the panel did not install a SubtitleResizeHostView.")
        }
        XCTAssertFalse(host.isLocked)

        preferences.overlayLocked = true
        coordinator.applyPreferences()
        XCTAssertTrue(host.isLocked, "locking a visible overlay must reach the resize band")

        preferences.overlayLocked = false
        coordinator.applyPreferences()
        XCTAssertFalse(host.isLocked, "unlocking it again must restore the band")
    }

    /// Cursor rects are the key-window mechanism, and this panel can never be key
    /// (`SubtitlePanel.canBecomeKey` is false, the style mask is `.nonactivatingPanel`, and the
    /// app runs as `.accessory`). So the band has to carry an `.activeAlways` tracking area —
    /// the only route that delivers pointer events to a background app's floating window.
    @MainActor
    func testResizeBandInstallsAnActiveAlwaysTrackingArea() {
        let suiteName = "OSTTests.resize-tracking.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let (coordinator, _) = makeOverlayCoordinator(defaults)
        defer { coordinator.hide() }
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        coordinator.show()
        guard let panel = combinedPanel(addedOver: before),
              let host = panel.contentView as? SubtitleResizeHostView else {
            return XCTFail("the panel did not install a SubtitleResizeHostView.")
        }

        XCTAssertFalse(panel.canBecomeKey, "the premise of this test is that the panel is never key")
        guard let area = host.trackingAreas.first(where: { $0.owner === host }) else {
            return XCTFail("the resize band installed no tracking area, so it can never see the pointer")
        }
        XCTAssertTrue(
            area.options.contains(.activeAlways),
            "anything narrower than .activeAlways is scoped to the key window or the active app"
        )
        XCTAssertTrue(area.options.contains(.mouseMoved), "the band needs per-point pointer updates")
        XCTAssertFalse(
            area.options.contains(.cursorUpdate),
            ".cursorUpdate is documented as unsupported together with .activeAlways"
        )
    }

    /// The forward direction: a pointer sitting on the band must actually select a resize
    /// cursor. Without this, deleting the whole cursor path leaves every other test green.
    @MainActor
    func testPointerOnTheBandSelectsAResizeCursor() {
        let suiteName = "OSTTests.resize-cursor.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let (coordinator, _) = makeOverlayCoordinator(defaults)
        defer { coordinator.hide() }
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        coordinator.show()
        guard let host = combinedPanel(addedOver: before)?.contentView as? SubtitleResizeHostView else {
            return XCTFail("the panel did not install a SubtitleResizeHostView.")
        }

        let bounds = host.bounds
        host.updateResizeCursor(at: CGPoint(x: bounds.midX, y: 2))
        XCTAssertEqual(host.activeCursorEdge, .bottom, "the bottom edge must offer a vertical resize")

        host.updateResizeCursor(at: CGPoint(x: 2, y: 2))
        XCTAssertEqual(host.activeCursorEdge, .bottomLeading, "corners win over the edges they touch")

        host.updateResizeCursor(at: CGPoint(x: bounds.midX, y: bounds.midY))
        XCTAssertNil(host.activeCursorEdge, "the interior must hand the cursor back")
    }

    /// Locking passes clicks through, so the cursor must stop advertising a grab it will refuse.
    @MainActor
    func testLockedOverlayShowsNoResizeCursor() {
        let suiteName = "OSTTests.resize-cursor-locked.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let (coordinator, preferences) = makeOverlayCoordinator(defaults, locked: false)
        defer { coordinator.hide() }
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        coordinator.show()
        guard let host = combinedPanel(addedOver: before)?.contentView as? SubtitleResizeHostView else {
            return XCTFail("the panel did not install a SubtitleResizeHostView.")
        }

        let edgePoint = CGPoint(x: host.bounds.midX, y: 2)
        host.updateResizeCursor(at: edgePoint)
        XCTAssertEqual(host.activeCursorEdge, .bottom)

        preferences.overlayLocked = true
        coordinator.applyPreferences()
        XCTAssertNil(host.activeCursorEdge, "locking must drop the resize cursor already on screen")
        host.updateResizeCursor(at: edgePoint)
        XCTAssertNil(host.activeCursorEdge, "a locked overlay must never re-arm it")
    }

    // MARK: - Global capture hot key (#5)

    @MainActor
    func testCaptureShortcutRoundTripsThroughPreferencesStore() {
        let suiteName = "OSTTests.capture-shortcut.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstStore = PreferencesStore(userDefaults: defaults)
        firstStore.captureShortcut = CaptureShortcut(keyCode: 0x0B, modifiers: hotKeyModifiers)

        let secondStore = PreferencesStore(userDefaults: defaults)
        XCTAssertEqual(
            secondStore.captureShortcut,
            CaptureShortcut(keyCode: 0x0B, modifiers: hotKeyModifiers)
        )
    }

    @MainActor
    func testClearingCaptureShortcutReturnsPreferencesStoreToUnbound() {
        let suiteName = "OSTTests.capture-shortcut-cleared.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstStore = PreferencesStore(userDefaults: defaults)
        firstStore.captureShortcut = CaptureShortcut(keyCode: 0x0B, modifiers: hotKeyModifiers)
        firstStore.captureShortcut = nil

        let secondStore = PreferencesStore(userDefaults: defaults)
        XCTAssertNil(secondStore.captureShortcut)
    }

    @MainActor
    func testMenuBarStartStopButtonUsesAppModelToggleCapture() throws {
        let _: (AppModel) -> () async -> Void = AppModel.toggleCapture
        let menuBarViewSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/OSTApp/MenuBarView.swift"),
            encoding: .utf8
        )

        // SwiftUI Button actions are hard to invoke without rebuilding the menu in a GUI
        // session, so this source assertion guards the dispatch shape directly.
        XCTAssertTrue(menuBarViewSource.contains("await model.toggleCapture()"))
        XCTAssertFalse(
            menuBarViewSource.contains("await model.start()")
                || menuBarViewSource.contains("await model.stop()"),
            "the action must not re-derive start/stop next to toggleCapture()"
        )
        // The label has to be read off the same decision the action takes. Branching on
        // `== .running` made the button read "Start" while it was about to cancel a start
        // that was still coming up.
        XCTAssertTrue(menuBarViewSource.contains("toggleIntent == .stop"))
        XCTAssertFalse(menuBarViewSource.contains("model.captureState == .running"))
    }

    /// OSTCore restates Carbon's modifier bits so it need not import Carbon. If Apple ever
    /// moved them, every stored shortcut would silently rebind to something else.
    func testShortcutModifierConstantsStillMatchCarbon() {
        XCTAssertEqual(CaptureShortcut.commandModifier, UInt32(cmdKey))
        XCTAssertEqual(CaptureShortcut.shiftModifier, UInt32(shiftKey))
        XCTAssertEqual(CaptureShortcut.optionModifier, UInt32(optionKey))
        XCTAssertEqual(CaptureShortcut.controlModifier, UInt32(controlKey))
        XCTAssertEqual(CaptureShortcut.escapeKeyCode, UInt32(kVK_Escape))
    }

    @MainActor
    func testRegistrarRefusesACommandOnlyCombination() {
        let registrar = GlobalHotKey()
        defer { registrar.unregister() }

        XCTAssertFalse(registrar.register(keyCode: 0x0C, modifiers: UInt32(cmdKey)))
    }

    @MainActor
    func testRegisteringCaptureShortcutReportsSuccess() {
        let registrar = GlobalHotKey()
        defer { registrar.unregister() }

        XCTAssertTrue(registrar.register(keyCode: 0x0B, modifiers: hotKeyModifiers))
    }

    /// Two `register` calls returning true would also be true of a registrar that leaked the
    /// first hot key, so the assertion has to be that the first combination came free: a
    /// second registrar can only claim it if the first one really let go.
    @MainActor
    func testRebindingReleasesThePreviousCaptureShortcut() {
        let registrar = GlobalHotKey()
        defer { registrar.unregister() }
        XCTAssertTrue(registrar.register(keyCode: 0x0B, modifiers: hotKeyModifiers))
        XCTAssertTrue(registrar.register(keyCode: 0x0C, modifiers: hotKeyModifiers))

        let other = GlobalHotKey()
        defer { other.unregister() }
        XCTAssertTrue(
            other.register(keyCode: 0x0B, modifiers: hotKeyModifiers),
            "rebinding must free the old combination, not hold both"
        )
    }

    @MainActor
    func testUnregisteringWithoutARegisteredCaptureShortcutIsANoOp() {
        let registrar = GlobalHotKey()

        registrar.unregister()
    }

    /// Carbon itself would happily grab a bare key system-wide, which would swallow that
    /// letter in every other app. Refusing a modifier-less combination is this registrar's
    /// own policy, and the caller has to be able to see the refusal.
    @MainActor
    func testCaptureShortcutWithoutModifiersIsRefused() {
        let registrar = GlobalHotKey()
        defer { registrar.unregister() }

        XCTAssertFalse(registrar.register(keyCode: 0x0B, modifiers: 0))
    }

    @MainActor
    func testCarbonEventHandlerIsInstalledOnlyOnceForMultipleRegistrars() {
        let first = GlobalHotKey()
        let second = GlobalHotKey()
        defer {
            first.unregister()
            second.unregister()
        }

        XCTAssertTrue(first.register(keyCode: 0x0B, modifiers: hotKeyModifiers))
        XCTAssertTrue(second.register(keyCode: 0x0C, modifiers: hotKeyModifiers))
        XCTAssertEqual(GlobalHotKey.installedEventHandlerCountForTesting, 1)
    }

    private var hotKeyModifiers: UInt32 {
        UInt32(controlKey | optionKey | shiftKey)
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // MARK: - Temporary reposition of a locked overlay (#6)

    /// Locking is implemented as ignoresMouseEvents, which is the only way to get real
    /// click-through -- a contentView returning nil from hitTest still swallows the click.
    /// So no modifier-drag can exist: the events never reach this process. A temporary
    /// unlock is the mechanism, and it has to move every part of the lock, not just one.
    @MainActor
    func testTemporaryRepositionMakesALockedOverlayDraggable() {
        let suiteName = "OSTTests.reposition.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let (coordinator, _) = makeOverlayCoordinator(defaults, locked: true)
        defer { coordinator.hide() }
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        coordinator.show()
        guard let panel = combinedPanel(addedOver: before),
              let host = panel.contentView as? SubtitleResizeHostView else {
            return XCTFail("the panel did not install a SubtitleResizeHostView.")
        }
        XCTAssertTrue(panel.ignoresMouseEvents)

        coordinator.beginTemporaryReposition()
        XCTAssertFalse(panel.ignoresMouseEvents, "a repositioning overlay has to receive clicks")
        XCTAssertTrue(panel.isMovableByWindowBackground, "and its background has to drag it")
        XCTAssertFalse(host.isLocked, "and its resize band has to come back")

        coordinator.endTemporaryReposition()
        XCTAssertTrue(panel.ignoresMouseEvents, "click-through must come back on its own")
        XCTAssertTrue(host.isLocked)
    }

    /// The failure that matters is the overlay stuck opaque to clicks with no sign of why,
    /// so the way out cannot depend on the user remembering the way out.
    @MainActor
    func testTemporaryRepositionEndsByItself() async throws {
        let suiteName = "OSTTests.reposition-timeout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = PreferencesStore(userDefaults: defaults)
        preferences.overlayLayout = .combined
        preferences.overlayLocked = true
        let coordinator = OverlayCoordinator(
            state: OverlayState(),
            preferences: preferences,
            translationPackCoordinator: TranslationPackCoordinator(),
            temporaryRepositionTimeout: .milliseconds(200)
        )
        defer { coordinator.hide() }
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        coordinator.show()
        guard let panel = combinedPanel(addedOver: before) else {
            return XCTFail("the panel did not appear.")
        }

        coordinator.beginTemporaryReposition()
        XCTAssertFalse(panel.ignoresMouseEvents)

        let deadline = Date().addingTimeInterval(5)
        while coordinator.isTemporarilyRepositioning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(
            panel.ignoresMouseEvents,
            "an untouched reposition must expire rather than leave the overlay solid"
        )
        XCTAssertFalse(coordinator.isTemporarilyRepositioning)
    }

    /// The mode borrows against the lock, so it cannot outlive it. Unlocking during a
    /// reposition otherwise left the accent border and the "finish" entry on an overlay
    /// that was already unlocked, waiting out a timer for nothing.
    @MainActor
    func testUnlockingDuringARepositionEndsTheMode() {
        let suiteName = "OSTTests.reposition-unlock.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = PreferencesStore(userDefaults: defaults)
        preferences.overlayLayout = .combined
        preferences.overlayLocked = true
        let state = OverlayState()
        let coordinator = OverlayCoordinator(
            state: state,
            preferences: preferences,
            translationPackCoordinator: TranslationPackCoordinator()
        )
        defer { coordinator.hide() }
        coordinator.show()
        coordinator.beginTemporaryReposition()
        XCTAssertTrue(coordinator.isTemporarilyRepositioning)

        preferences.overlayLocked = false
        coordinator.applyPreferences()
        XCTAssertFalse(coordinator.isTemporarilyRepositioning)
        XCTAssertFalse(state.isRepositioning, "the overlay must stop advertising the mode")
    }

    /// The mode is invisible unless the overlay says so, and a mode the user cannot see is
    /// the same bug as one they cannot leave.
    @MainActor
    func testTemporaryRepositionTellsTheOverlayToShowIt() {
        let suiteName = "OSTTests.reposition-visible.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = PreferencesStore(userDefaults: defaults)
        preferences.overlayLayout = .combined
        preferences.overlayLocked = true
        let state = OverlayState()
        let coordinator = OverlayCoordinator(
            state: state,
            preferences: preferences,
            translationPackCoordinator: TranslationPackCoordinator()
        )
        defer { coordinator.hide() }
        coordinator.show()

        XCTAssertFalse(state.isRepositioning)
        coordinator.beginTemporaryReposition()
        XCTAssertTrue(state.isRepositioning)
        coordinator.endTemporaryReposition()
        XCTAssertFalse(state.isRepositioning)
    }

    /// An unlocked overlay is already draggable, so the mode would only add a mystery
    /// border and a timer.
    @MainActor
    func testTemporaryRepositionDoesNothingWhenTheOverlayIsAlreadyUnlocked() {
        let suiteName = "OSTTests.reposition-unlocked.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let (coordinator, _) = makeOverlayCoordinator(defaults, locked: false)
        defer { coordinator.hide() }
        coordinator.show()

        coordinator.beginTemporaryReposition()
        XCTAssertFalse(coordinator.isTemporarilyRepositioning)
    }

    @MainActor
    func testRepositionShortcutRoundTripsThroughPreferencesStore() {
        let suiteName = "OSTTests.reposition-shortcut.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = PreferencesStore(userDefaults: defaults)
        first.repositionShortcut = CaptureShortcut(keyCode: 0x0B, modifiers: hotKeyModifiers)

        let second = PreferencesStore(userDefaults: defaults)
        XCTAssertEqual(
            second.repositionShortcut,
            CaptureShortcut(keyCode: 0x0B, modifiers: hotKeyModifiers)
        )
    }

    /// Not everyone binds a shortcut, and the feature must not be reachable only through
    /// one the user has to discover and configure first.
    @MainActor
    func testMenuOffersTheRepositionEntry() throws {
        let source = try String(
            contentsOf: projectRoot.appending(path: "Sources/OSTApp/MenuBarView.swift"),
            encoding: .utf8
        )
        // One entry that both enters and leaves the mode: entering from the menu and then
        // having to wait out the timeout to leave is the same trap as no exit at all.
        XCTAssertTrue(source.contains("model.toggleTemporaryReposition()"))
        XCTAssertTrue(source.contains("Finish Repositioning"))
    }
}
