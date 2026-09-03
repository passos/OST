import CoreGraphics
import Foundation
import OSTCore
import Testing

private actor LimitedTranscriptionProvider: TranscriptionProvider {
    nonisolated let id = ProviderID.appleSpeech
    nonisolated let capabilities = TranscriptionCapabilities(
        supportedLanguages: [.english],
        supportsAutomaticLanguageDetection: false,
        supportsVolatileResults: true
    )

    func prepare(configuration: TranscriptionConfiguration) {}

    func transcribe(
        _ audio: AsyncStream<PCMChunk>
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func stop() {}
}

@Test func languageLocaleMapping() {
    #expect(SupportedLanguage.english.localeIdentifier == "en")
    #expect(SupportedLanguage.chineseSimplified.localeIdentifier == "zh-Hans")
    #expect(SupportedLanguage.chineseTraditional.localeIdentifier == "zh-Hant")
    #expect(SupportedLanguage.japanese.localeIdentifier == "ja")
    #expect(SupportedLanguage.korean.localeIdentifier == "ko")
}

@Test func productLanguagePickerGroupsChineseLocales() {
    #expect(SupportedLanguage.productPickerCases.count == 4)
    #expect(SupportedLanguage.productPickerCases.filter(\.isChinese).count == 1)
    #expect(SupportedLanguage.chineseSimplified.productDisplayName == "중국어")
    #expect(SupportedLanguage.chineseTraditional.applyingChinesePreference(.simplified)
        == .chineseSimplified)
    #expect(SupportedLanguage.chineseSimplified.applyingChinesePreference(.traditional)
        == .chineseTraditional)
}

@Test func silenceDetectorReportsOnceUntilSpeechResetsIt() {
    var detector = SilenceDetector(requiredSilentSamples: 8)
    let first = detector.observe([0, 0, 0, 0])
    let thresholdReached = detector.observe([0, 0, 0, 0])
    let repeated = detector.observe([0, 0, 0, 0])
    let speech = detector.observe([0.5])
    let afterReset = detector.observe([0, 0, 0, 0, 0, 0, 0, 0])
    #expect(first == false)
    #expect(thresholdReached)
    #expect(repeated == false)
    #expect(speech == false)
    #expect(afterReset)
}

@Test func captureStateTransitions() async throws {
    let machine = CaptureStateMachine()
    #expect(try await machine.transition(to: .requestingPermission) == .requestingPermission)
    #expect(try await machine.transition(to: .preparingModels) == .preparingModels)
    #expect(try await machine.transition(to: .running) == .running)
    #expect(try await machine.transition(to: .stopping) == .stopping)
    #expect(try await machine.transition(to: .idle) == .idle)
}

@Test func invalidCaptureTransitionIsRejected() async {
    let machine = CaptureStateMachine()
    await #expect(throws: CaptureTransitionError.self) {
        try await machine.transition(to: .running)
    }
}

@Test func sleepAndDeviceRecoveryOnlyRestartsPriorRunningCapture() async {
    let recovery = CaptureRecoveryCoordinator()
    #expect(await recovery.prepareForSleep(state: .idle) == false)
    #expect(await recovery.shouldRestartAfterWake(permissionAvailable: true, outputDeviceAvailable: true) == false)
    #expect(await recovery.prepareForSleep(state: .running))
    #expect(await recovery.shouldRestartAfterWake(permissionAvailable: true, outputDeviceAvailable: true))
    #expect(await recovery.shouldReconfigureForDeviceChange(state: .running))
    #expect(await recovery.shouldReconfigureForDeviceChange(state: .idle) == false)
}

@Test func memoryPressureRecoveryKeepsASRAndDropsMLXTranslationFirst() {
    #expect(MemoryPressureRecoveryPolicy.action(
        level: .warning,
        captureIsActive: true,
        mlxTranslationIsLoaded: true
    ) == .keepActiveModels)
    #expect(MemoryPressureRecoveryPolicy.action(
        level: .critical,
        captureIsActive: true,
        mlxTranslationIsLoaded: true
    ) == .fallbackMLXTranslation)
    #expect(MemoryPressureRecoveryPolicy.action(
        level: .critical,
        captureIsActive: true,
        mlxTranslationIsLoaded: false
    ) == .keepActiveModels)
    #expect(MemoryPressureRecoveryPolicy.action(
        level: .warning,
        captureIsActive: false,
        mlxTranslationIsLoaded: true
    ) == .releaseUnusedModels)
}

@Test func overlayFrameIsClampedToVisibleScreen() {
    let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let restored = OverlayFrameRestorer.restoredFrame(
        stored: CGRect(x: 3000, y: 2000, width: 2000, height: 20),
        visibleFrames: [visible],
        primaryVisibleFrame: visible
    )
    #expect(restored.width == 720)
    #expect(restored.height == 180)
    #expect(visible.contains(restored))

    let clamped = OverlayFrameRestorer.clamp(
        CGRect(x: -500, y: -500, width: 100, height: 50),
        to: visible
    )
    #expect(clamped.width == 320)
    #expect(clamped.height == 96)
    #expect(visible.contains(clamped))
}

@Test func preferenceRangesAreClamped() {
    let preferences = PreferencesSnapshot(
        sourceFontSize: 2,
        translationFontSize: 100,
        previewFontSize: 100,
        backgroundOpacity: 2,
        overlayLineCount: 20,
        endpointSilenceSeconds: 0.1
    )
    #expect(preferences.sourceFontSize == 12)
    #expect(preferences.translationFontSize == 72)
    #expect(preferences.previewFontSize == 72)
    #expect(preferences.backgroundOpacity == 1)
    #expect(preferences.overlayLineCount == 10)
    #expect(preferences.endpointSilenceSeconds == 0.4)

    let minimumLines = PreferencesSnapshot(overlayLineCount: 2)
    #expect(minimumLines.overlayLineCount == 2)
}

@Test func providerRegistryRejectsAutomaticAndUnsupportedLanguages() async throws {
    let registry = ProviderRegistry()
    await registry.register(LimitedTranscriptionProvider())
    await #expect(throws: ProviderRegistryError.self) {
        try await registry.transcriptionProvider(
            id: .appleSpeech,
            configuration: TranscriptionConfiguration(
                sourceMode: .automatic,
                chineseScriptPreference: .simplified
            )
        )
    }
    await #expect(throws: ProviderRegistryError.self) {
        try await registry.transcriptionProvider(
            id: .appleSpeech,
            configuration: TranscriptionConfiguration(
                sourceMode: .fixed(.japanese),
                chineseScriptPreference: .simplified
            )
        )
    }
}

@Test func combinedAndSplitLayoutSettingsRoundTrip() throws {
    for layout in OverlayLayout.allCases {
        let original = PreferencesSnapshot(
            mlxTranslationPrompt: "Translate {source_language} into {target_language}.",
            overlayLayout: layout,
            previewFontSize: 24,
            previewColor: RGBAColor(red: 0.4, green: 0.8, blue: 1),
            overlayLineCount: 10,
            endpointSilenceSeconds: 1.3,
            subtitleAlignment: .trailing
        )
        let decoded = try JSONDecoder().decode(
            PreferencesSnapshot.self,
            from: JSONEncoder().encode(original)
        )
        #expect(decoded.overlayLayout == layout)
        #expect(decoded.mlxTranslationPrompt == "Translate {source_language} into {target_language}.")
        #expect(decoded.previewFontSize == 24)
        #expect(decoded.previewColor == RGBAColor(red: 0.4, green: 0.8, blue: 1))
        #expect(decoded.overlayLineCount == 10)
        #expect(decoded.endpointSilenceSeconds == 1.3)
        #expect(decoded.subtitleAlignment == .trailing)
    }
}

@Test func olderPreferencesReceiveEndpointAndLineDefaults() throws {
    let decoded = try JSONDecoder().decode(
        PreferencesSnapshot.self,
        from: Data("{}".utf8)
    )
    #expect(decoded.overlayLineCount == 3)
    #expect(decoded.overlayLocked == true)
    #expect(decoded.endpointSilenceSeconds == 0.8)
    #expect(decoded.subtitleAlignment == .leading)
    #expect(decoded.previewFontSize == 28)
    #expect(decoded.previewColor == .white)
    #expect(decoded.mlxTranslationPrompt == MLXPromptDefaults.translation)
    #expect(decoded.appDisplayLanguage == .english)
    #expect(decoded.sessionLoggingEnabled == false)
    #expect(decoded.sessionLogDirectoryBookmark == nil)
    #expect(decoded.sessionLogDirectoryPath == nil)
}

@Test func overlayIsHiddenFromScreenCaptureByDefault() {
    #expect(PreferencesSnapshot().hideOverlayInScreenCapture)
}

@Test func overlayScreenCaptureHidingPreferenceRoundTripsWhenDisabled() throws {
    let original = PreferencesSnapshot(hideOverlayInScreenCapture: false)
    let decoded = try JSONDecoder().decode(
        PreferencesSnapshot.self,
        from: JSONEncoder().encode(original)
    )
    #expect(decoded.hideOverlayInScreenCapture == false)
}

@Test func olderPreferencesHideOverlayFromScreenCaptureByDefault() throws {
    let decoded = try JSONDecoder().decode(
        PreferencesSnapshot.self,
        from: Data("{}".utf8)
    )
    #expect(decoded.hideOverlayInScreenCapture)
}

@Test func appDisplayLanguageSupportsFourLocalesAndDefaultsToEnglish() {
    #expect(AppDisplayLanguage.allCases == [.english, .chinese, .japanese, .korean])
    #expect(PreferencesSnapshot().appDisplayLanguage == .english)
    #expect(AppDisplayLanguage.chinese.localeIdentifier == "zh-Hans")
}

@Test func sessionLoggingPreferencesRoundTrip() throws {
    let original = PreferencesSnapshot(
        appDisplayLanguage: .japanese,
        sessionLoggingEnabled: true,
        sessionLogDirectoryBookmark: Data([1, 2, 3]),
        sessionLogDirectoryPath: "/tmp/OST"
    )
    let decoded = try JSONDecoder().decode(
        PreferencesSnapshot.self,
        from: JSONEncoder().encode(original)
    )
    #expect(decoded.appDisplayLanguage == .japanese)
    #expect(decoded.sessionLoggingEnabled)
    #expect(decoded.sessionLogDirectoryBookmark == Data([1, 2, 3]))
    #expect(decoded.sessionLogDirectoryPath == "/tmp/OST")
}

@Test func captureShortcutIsUnboundByDefault() {
    #expect(PreferencesSnapshot().captureShortcut == nil)
}

@Test func olderPreferencesDecodeWithUnboundCaptureShortcut() throws {
    let encoded = try JSONEncoder().encode(PreferencesSnapshot(
        captureShortcut: CaptureShortcut(keyCode: 0x0B, modifiers: 0x000D_0000)
    ))
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "captureShortcut")

    let decoded = try JSONDecoder().decode(
        PreferencesSnapshot.self,
        from: try JSONSerialization.data(withJSONObject: object)
    )

    #expect(decoded.captureShortcut == nil)
}

/// The hot key and the menu button share one decision, so the decision has to exist
/// somewhere both can reach and a test can drive without a microphone.
@Test func commandOnlyBindingsAreRefused() {
    // The recorder's own escape hatch is the trap: pressing Command-Q to get out would
    // otherwise bind Command-Q globally and take it away from every other app.
    #expect(CaptureShortcut.isAcceptableBinding(keyCode: 0x0C, modifiers: CaptureShortcut.commandModifier) == false)
    #expect(CaptureShortcut.isAcceptableBinding(keyCode: 0x0C, modifiers: 0) == false)
    #expect(CaptureShortcut.isAcceptableBinding(keyCode: CaptureShortcut.escapeKeyCode, modifiers: CaptureShortcut.controlModifier) == false)
}

@Test func bindingsCarryingControlOrOptionAreAccepted() {
    let control = CaptureShortcut.controlModifier
    let option = CaptureShortcut.optionModifier
    #expect(CaptureShortcut.isAcceptableBinding(keyCode: 0x0B, modifiers: control | option))
    #expect(CaptureShortcut.isAcceptableBinding(keyCode: 0x0B, modifiers: option))
    // Command is fine as long as it is not the only modifier.
    #expect(CaptureShortcut.isAcceptableBinding(keyCode: 0x0B, modifiers: control | CaptureShortcut.commandModifier))
}

/// Why start() carries a generation guard: once a hot key stops capture mid-start, the
/// machine is back at .idle, and the suspended start's own transition is then illegal.
/// Without the guard that throw is reported to the user as a model-load failure.
@Test func aStartThatResumesAfterAStopCannotReachRunning() async throws {
    let machine = CaptureStateMachine()
    #expect(try await machine.transition(to: .requestingPermission) == .requestingPermission)
    #expect(try await machine.transition(to: .preparingModels) == .preparingModels)
    #expect(try await machine.transition(to: .stopping) == .stopping)
    #expect(try await machine.transition(to: .idle) == .idle)

    await #expect(throws: CaptureTransitionError.self) {
        _ = try await machine.transition(to: .running)
    }
}

/// toggleIntent promises a stop while capture is still coming up, so the state machine has
/// to accept that stop. It did not before: stop() already let .preparingModels through while
/// the machine rejected the transition, so the hot key would have hit the failure path.
@Test func captureCanBeStoppedWhileItIsStillComingUp() async throws {
    let fromPermission = CaptureStateMachine()
    #expect(try await fromPermission.transition(to: .requestingPermission) == .requestingPermission)
    #expect(try await fromPermission.transition(to: .stopping) == .stopping)

    let fromModels = CaptureStateMachine()
    #expect(try await fromModels.transition(to: .requestingPermission) == .requestingPermission)
    #expect(try await fromModels.transition(to: .preparingModels) == .preparingModels)
    #expect(try await fromModels.transition(to: .stopping) == .stopping)
}

@Test func toggleIntentStartsFromRestingStates() {
    #expect(CaptureState.idle.toggleIntent == .start)
    #expect(CaptureState.failed(.permissionDenied).toggleIntent == .start)
}

@Test func toggleIntentStopsWhileCaptureIsComingUpOrRunning() {
    #expect(CaptureState.running.toggleIntent == .stop)
    // Pressing the hot key during start-up must cancel it, not queue a second start --
    // otherwise a slow model load looks like a dead shortcut.
    #expect(CaptureState.requestingPermission.toggleIntent == .stop)
    #expect(CaptureState.preparingModels.toggleIntent == .stop)
}

@Test func toggleIntentDoesNothingWhileAlreadyStopping() {
    #expect(CaptureState.stopping.toggleIntent == nil)
}

@Test func sessionLogWriterCreatesSeparateStableFiles() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = SessionLogWriter()
    let startedAt = Date(timeIntervalSince1970: 1_783_775_840) // 2026-07-11 in UTC
    let urls = try await writer.start(directory: directory, startedAt: startedAt)

    #expect(urls.transcript.lastPathComponent.hasSuffix("-transcript.txt"))
    #expect(urls.translation.lastPathComponent.hasSuffix("-translation.txt"))

    let firstID = UUID()
    let secondID = UUID()
    try await writer.recordTranscript(id: firstID, text: "First sentence.")
    try await writer.recordTranscript(id: firstID, text: "First sentence corrected.")
    try await writer.recordTranscript(id: secondID, text: "Second sentence.")
    try await writer.recordTranslation(id: secondID, text: "두 번째 문장입니다.")
    try await writer.recordTranslation(id: firstID, text: "첫 번째 문장입니다.")
    await writer.finish()

    #expect(try String(contentsOf: urls.transcript, encoding: .utf8)
        == "First sentence corrected.\nSecond sentence.\n")
    #expect(try String(contentsOf: urls.translation, encoding: .utf8)
        == "첫 번째 문장입니다.\n두 번째 문장입니다.\n")
}

@Test func olderPreferencesReuseTranslationStyleForTheNewPreview() throws {
    let decoded = try JSONDecoder().decode(
        PreferencesSnapshot.self,
        from: Data(#"{"translationFontSize":34,"translationColor":{"red":0.2,"green":0.8,"blue":0.4,"alpha":1}}"#.utf8)
    )
    #expect(decoded.previewFontSize == 34)
    #expect(decoded.previewColor == RGBAColor(red: 0.2, green: 0.8, blue: 0.4))
}

@Test func mlxPromptTemplatesRenderTheSelectedLanguagePair() {
    let rendered = MLXPromptDefaults.renderTranslation(
        template: "Translate {source_language} into {target_language}.",
        source: .english,
        target: .korean
    )
    #expect(rendered == "Translate English into Korean.")
    #expect(MLXPromptDefaults.transcription.contains("Output only the transcript text"))
}

@Test func mlxTranslationOutputRemovesPromptEchoAndUsesTheLastLabeledResult() {
    let prompt = MLXPromptDefaults.renderTranslation(
        template: MLXPromptDefaults.translation,
        source: .english,
        target: .korean
    )
    let output = """
    translated text: Return only the translation. Do not explain, analyze, or include thinking.
    Korean: \"정말 기대할 만한 미래입니다.\"
    Ryan, return it.
    translated text: 감사합니다.
    """
    #expect(MLXModelOutputSanitizer.translation(
        output,
        prompt: prompt,
        sourceText: "Thank you.",
        target: .korean
    ) == "감사합니다.")
}

@Test func mlxTranscriptionOutputRemovesPromptAndTranscriptPrefix() {
    let output = """
    \(MLXPromptDefaults.transcription)
    Transcript: We need to go bigger.
    """
    #expect(MLXModelOutputSanitizer.transcription(
        output,
        prompt: MLXPromptDefaults.transcription,
        language: .english
    ) == "We need to go bigger.")
}

@Test func overlayPreferredHeightShrinksWithTheConfiguredLineCount() {
    let tenLines = OverlaySizing.combinedSize(
        lineCount: 10,
        sourceFontSize: 20,
        translationFontSize: 28,
        maximumHeight: 900
    )
    let threeLines = OverlaySizing.combinedSize(
        lineCount: 3,
        sourceFontSize: 20,
        translationFontSize: 28,
        maximumHeight: 900
    )
    #expect(tenLines.height > threeLines.height)
    #expect(threeLines.width == tenLines.width)
    #expect(threeLines.height == 352)
}

@Test func overlayHeightAddsTwoPreviewLinesBeyondConfirmedHistory() {
    let combined = OverlaySizing.combinedSize(
        lineCount: 5,
        sourceFontSize: 20,
        translationFontSize: 28,
        maximumHeight: 900
    )
    let source = OverlaySizing.sourceSize(
        lineCount: 5,
        fontSize: 20,
        maximumHeight: 900
    )
    #expect(combined.height == 472)
    #expect(source.height == 203)
}

@Test func translationPreviewFontSizeChangesOnlyItsReservedHeight() {
    let combined = OverlaySizing.combinedSize(
        lineCount: 5,
        sourceFontSize: 20,
        translationFontSize: 28,
        previewFontSize: 40,
        maximumHeight: 900
    )
    let translation = OverlaySizing.translationSize(
        lineCount: 5,
        fontSize: 28,
        previewFontSize: 40,
        maximumHeight: 900
    )
    #expect(combined.height == 502)
    #expect(translation.height == 303)
}

@Test func permissionAndLanguagePackFailuresRemainDistinct() {
    #expect(CaptureFailure.permissionDenied != .permissionRevoked)
    #expect(CaptureFailure.speechLanguagePackUnavailable(.korean)
        != .translationLanguagePackUnavailable)
}
