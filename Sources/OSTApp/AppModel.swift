import AppKit
import Combine
import Foundation
import OSTCore
import OSTMLX
import OSTPlatform

@MainActor
final class AppModel: ObservableObject {
    let preferences: PreferencesStore
    let overlayState: OverlayState
    let modelDownloader: ModelDownloaderClient
    let translationPackCoordinator: TranslationPackCoordinator
    let modelCatalog: ModelCatalog

    @Published private(set) var captureState: CaptureState = .idle
    @Published private(set) var overlayVisible = true
    @Published private(set) var appleSpeechSupportedLanguages: Set<SupportedLanguage> = []
    @Published var selectedSettingsTab: SettingsTab = .general
    @Published private(set) var sessionLoggingError: String?
    /// Menu-only mirrors of the two overlay values MenuBarView renders. Kept separate
    /// from OverlayState so the menu does not rebuild on segment churn.
    @Published private(set) var menuStatusText = "Waiting"
    /// Mirrored rather than read through overlayState: that object is deliberately not
    /// forwarded to this one, so the menu would never redraw when the mode changes.
    @Published private(set) var menuOverlayIsRepositioning = false
    @Published private(set) var menuDetectedLanguage: SupportedLanguage?

    private let registry = ProviderRegistry()
    private let stateMachine = CaptureStateMachine()
    private let recovery = CaptureRecoveryCoordinator()
    private let segmentStore = SegmentStore()
    private let translationScheduler = TranslationScheduler()
    private let audioCapture = CoreAudioTapCapture()
    private let appleSpeech = AppleSpeechProvider()
    private let appleTranslation = AppleTranslationProvider()
    private let qwenASR = Qwen3ASRAdapter()
    private let qwenTranslation = Qwen3TranslationAdapter()
    private let powerMonitor = PowerStateMonitor()
    private let overlayCoordinator: OverlayCoordinator
    private let sessionLogWriter = SessionLogWriter()
    private let globalHotKey = GlobalHotKey()
    private let repositionHotKey = GlobalHotKey()

    private var transcriptionTask: Task<Void, Never>?
    private var translationUpdatesTask: Task<Void, Never>?
    private var powerTask: Task<Void, Never>?
    private var captureEventsTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?
    private var activeTranscriptionProvider: (any TranscriptionProvider)?
    private var mlxTranslationReady = false
    private var memoryPressureTranslationFallbackActive = false
    private var activated = false
    private var cancellables: Set<AnyCancellable> = []
    private var activeSessionLogDirectory: URL?
    private var registeredCaptureShortcut: CaptureShortcut?
    private var registeredRepositionShortcut: CaptureShortcut?
    /// Bumped whenever a start or a stop begins. start() awaits the microphone and the
    /// model load, and a hot key can now stop capture during either -- so on the way back
    /// it has to notice it was superseded instead of reporting a model-load failure the
    /// user never caused.
    private var captureGeneration = 0

    init() {
        let preferences = PreferencesStore()
        let overlayState = OverlayState()
        let translationPackCoordinator = TranslationPackCoordinator()
        self.preferences = preferences
        self.overlayState = overlayState
        modelDownloader = ModelDownloaderClient()
        self.translationPackCoordinator = translationPackCoordinator
        modelCatalog = try! ModelCatalog.bundled()
        overlayCoordinator = OverlayCoordinator(
            state: overlayState,
            preferences: preferences,
            translationPackCoordinator: translationPackCoordinator
        )
        translationPackCoordinator.onFailure = { [weak overlayState, weak preferences] in
            let language = preferences?.appDisplayLanguage ?? .english
            overlayState?.statusText = AppCopy.text("Translation pack setup failed — showing transcript", language: language)
        }
        globalHotKey.setAction { [weak self] in
            Task { @MainActor in await self?.toggleCapture() }
        }
        repositionHotKey.setAction { [weak self] in
            Task { @MainActor in self?.toggleTemporaryReposition() }
        }
        preferences.onChange = { [weak self] snapshot in
            self?.overlayCoordinator.applyPreferences()
            self?.applyCaptureShortcut(snapshot.captureShortcut)
            self?.applyRepositionShortcut(snapshot.repositionShortcut)
            Task { [weak self] in
                guard let self else { return }
                self.overlayState.segments = await self.segmentStore.visibleSegments(
                    limit: self.overlayRetentionLimit
                )
            }
        }
        // The menu renders preference-derived labels, so preferences keep invalidating it.
        preferences.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        // overlayState, modelDownloader and translationPackCoordinator are deliberately NOT
        // forwarded. Download progress lands every 500ms and segments change at speech rate,
        // and the menu shows neither; forwarding them rebuilt the whole MenuBarExtra tree —
        // which, for an open NSMenu, is the flicker and truncation users reported.
        // Views that need those objects observe them directly (SettingsView, OverlayContentView).
        // The two values the menu does read are mirrored below, de-duplicated at the source
        // because handleTranscript reassigns them on every transcript event.
        overlayState.$isRepositioning
            .removeDuplicates()
            .sink { [weak self] active in self?.menuOverlayIsRepositioning = active }
            .store(in: &cancellables)
        overlayState.$statusText
            .removeDuplicates()
            .sink { [weak self] text in self?.menuStatusText = text }
            .store(in: &cancellables)
        overlayState.$detectedLanguage
            .removeDuplicates()
            .sink { [weak self] language in self?.menuDetectedLanguage = language }
            .store(in: &cancellables)
    }

    func activate() async {
        guard !activated else { return }
        activated = true
        await registry.register(appleSpeech)
        await registry.register(appleTranslation)
        await registry.register(qwenASR)
        await registry.register(qwenTranslation)
        appleSpeechSupportedLanguages = await AppleSpeechProvider.runtimeSupportedLanguages()
        overlayCoordinator.show()
        startTranslationUpdates()
        startPowerMonitoring()
        startCaptureEventMonitoring()
        applyCaptureShortcut(preferences.captureShortcut)
        applyRepositionShortcut(preferences.repositionShortcut)
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.globalHotKey.unregister()
                self.repositionHotKey.unregister()
                await self.stop()
            }
        }
    }

    func start() async {
        guard captureState != .running,
              captureState != .requestingPermission,
              captureState != .preparingModels else { return }
        captureGeneration += 1
        let generation = captureGeneration
        do {
            if case .failed = captureState {
                try await transition(to: .idle)
            }
            memoryPressureTranslationFallbackActive = false
            await segmentStore.clear()
            overlayState.clear()

            try await transition(to: .requestingPermission)
            let audio = try await audioCapture.start()
            overlayState.isListening = true

            let transcriptionConfiguration = try transcriptionConfiguration()
            let provider = try await registry.transcriptionProvider(
                id: preferences.transcriptionProvider,
                configuration: transcriptionConfiguration
            )
            await startSessionLoggingIfNeeded()
            try await transition(to: .preparingModels)
            try await provider.prepare(configuration: transcriptionConfiguration)
            guard generation == captureGeneration else { return }
            activeTranscriptionProvider = provider
            try await prepareSelectedMLXTranslationIfNeeded()
            guard generation == captureGeneration else { return }
            try await transition(to: .running)
            overlayState.statusText = captureStatusText

            transcriptionTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let events = await provider.transcribe(audio)
                    for try await event in events {
                        guard !Task.isCancelled else { break }
                        await self.handleTranscript(event)
                    }
                } catch {
                    await self.fail(Self.captureFailure(from: error))
                }
            }
        } catch {
            // A stop that landed mid-start is why this threw; surfacing it would blame the
            // user's own cancellation on the model loader.
            guard generation == captureGeneration else { return }
            let failure = Self.captureFailure(from: error)
            if failure == .automaticModelMissing {
                showModelSettings()
            }
            await fail(failure)
        }
    }

    func stop() async {
        guard captureState == .running
            || captureState == .preparingModels
            || captureState == .requestingPermission else { return }
        captureGeneration += 1
        do {
            try await transition(to: .stopping)
        } catch {
            captureState = .stopping
        }
        let finalizingTranscriptionTask = transcriptionTask
        await activeTranscriptionProvider?.stop()
        await finalizingTranscriptionTask?.value
        transcriptionTask = nil
        activeTranscriptionProvider = nil
        await translationScheduler.cancelAll()
        await appleTranslation.cancelAll()
        await qwenTranslation.cancelAll()
        await qwenTranslation.unload()
        await audioCapture.stop()
        await stopSessionLogging()
        mlxTranslationReady = false
        memoryPressureTranslationFallbackActive = false
        overlayState.isListening = false
        do {
            try await transition(to: .idle)
        } catch {
            captureState = .idle
        }
        overlayState.statusText = t("Stopped")
    }

    func toggleCapture() async {
        switch captureState.toggleIntent {
        case .start:
            await start()
        case .stop:
            await stop()
        case nil:
            break
        }
    }

    func restartCapture() async {
        if captureState == .running { await stop() }
        await start()
    }

    func toggleOverlayVisibility() {
        overlayCoordinator.toggleVisibility()
        overlayVisible = overlayCoordinator.isVisible
    }

    func toggleOverlayLock() {
        preferences.overlayLocked.toggle()
    }

    func resetOverlayFrames() {
        overlayCoordinator.resetFrames()
    }

    var canTemporarilyRepositionOverlay: Bool {
        preferences.overlayLocked && overlayVisible
    }

    func beginTemporaryReposition() {
        overlayCoordinator.beginTemporaryReposition()
    }

    func toggleTemporaryReposition() {
        if overlayCoordinator.isTemporarilyRepositioning {
            overlayCoordinator.endTemporaryReposition()
        } else {
            overlayCoordinator.beginTemporaryReposition()
        }
    }

    func openAudioPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func chooseSessionLogDirectory() {
        let panel = NSOpenPanel()
        panel.title = t("Choose a folder for session files")
        panel.prompt = t("Choose")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            preferences.sessionLogDirectoryBookmark = bookmark
            preferences.sessionLogDirectoryPath = url.path
            preferences.sessionLoggingEnabled = true
            sessionLoggingError = nil
        } catch {
            sessionLoggingError = "The selected folder could not be saved."
        }
    }

    func revealSessionLogDirectory() {
        guard let path = preferences.sessionLogDirectoryPath else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    func revealModel(_ descriptor: ModelDescriptor) {
        guard let directory = installedDirectory(for: descriptor) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    func openSettings(tab: SettingsTab? = nil) {
        if let tab { selectedSettingsTab = tab }
        NotificationCenter.default.post(name: .ostOpenSettings, object: nil)
    }

    private func showModelSettings() {
        openSettings(tab: .models)
    }

    private func applyCaptureShortcut(_ shortcut: CaptureShortcut?) {
        guard shortcut != registeredCaptureShortcut else { return }
        globalHotKey.unregister()
        registeredCaptureShortcut = nil

        guard let shortcut else { return }
        guard globalHotKey.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) else {
            return
        }
        registeredCaptureShortcut = shortcut
    }

    private func applyRepositionShortcut(_ shortcut: CaptureShortcut?) {
        guard shortcut != registeredRepositionShortcut else { return }
        repositionHotKey.unregister()
        registeredRepositionShortcut = nil

        guard let shortcut else { return }
        guard repositionHotKey.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) else {
            return
        }
        registeredRepositionShortcut = shortcut
    }

    private func handleTranscript(_ event: TranscriptEvent) async {
        let segments = await segmentStore.merge(
            event,
            limit: overlayRetentionLimit
        )
        overlayState.segments = segments
        switch event {
        case .unsupportedLanguage:
            overlayState.statusText = t("Unsupported language")
            return
        case .silence:
            overlayState.statusText = t("Silence")
            return
        case .overload:
            overlayState.statusText = t("Processing delay")
            return
        case .segment(let segment):
            overlayState.detectedLanguage = segment.language
            overlayState.statusText = captureStatusText
        }
        guard let segment = event.segment else { return }
        if segment.isFinal {
            try? await sessionLogWriter.recordTranscript(id: segment.id, text: segment.sourceText)
        }

        if segment.language == preferences.targetLanguage {
            await translationScheduler.submit(
                event,
                target: preferences.targetLanguage,
                primary: appleTranslation
            )
            return
        }

        do {
            let providers = try await translationProviders(source: segment.language)
            await translationScheduler.submit(
                event,
                target: preferences.targetLanguage,
                primary: providers.primary,
                fallback: providers.fallback
            )
        } catch let error as AppleTranslationProviderError {
            if case .languagePackNotInstalled(let source, let target) = error {
                overlayState.statusText = t("Preparing translation language pack")
                translationPackCoordinator.request(source: source, target: target) { [weak self] in
                    await self?.handleTranscript(event)
                }
            } else {
                overlayState.statusText = t("Unsupported translation language pair")
            }
        } catch {
            overlayState.statusText = t("Translation provider setup failed")
        }
    }

    private func translationProviders(
        source: SupportedLanguage
    ) async throws -> (primary: any TranslationProvider, fallback: (any TranslationProvider)?) {
        let target = preferences.targetLanguage
        if preferences.translationProvider == .qwen3Translation, mlxTranslationReady {
            await qwenTranslation.setPromptTemplate(preferences.mlxTranslationPrompt)
            let primary = try await registry.translationProvider(
                id: .qwen3Translation,
                source: source,
                target: target
            )
            try await primary.prepare(source: source, target: target)
            let fallback: (any TranslationProvider)?
            do {
                let apple = try await registry.translationProvider(
                    id: .appleTranslation,
                    source: source,
                    target: target
                )
                try await apple.prepare(source: source, target: target)
                fallback = apple
            } catch {
                fallback = nil
            }
            return (primary, fallback)
        }

        let primary = try await registry.translationProvider(
            id: .appleTranslation,
            source: source,
            target: target
        )
        try await primary.prepare(source: source, target: target)
        return (primary, nil)
    }

    private func prepareSelectedMLXTranslationIfNeeded() async throws {
        mlxTranslationReady = false
        guard preferences.translationProvider == .qwen3Translation else { return }
        guard let descriptor = modelCatalog.models.first(where: {
            $0.id == preferences.selectedTranslationModelID && $0.task == .translation
        }), let directory = installedDirectory(for: descriptor) else {
            overlayState.statusText = t("MLX translation model unavailable — using Apple Translation")
            return
        }
        do {
            try await qwenTranslation.loadModel(at: directory)
            mlxTranslationReady = true
        } catch {
            overlayState.statusText = t("MLX translation model failed to load — using Apple Translation")
        }
    }

    private func transcriptionConfiguration() throws -> TranscriptionConfiguration {
        if preferences.transcriptionProvider == .appleSpeech {
            guard case .fixed = preferences.sourceMode else {
                throw ProviderRegistryError.automaticDetectionUnsupported(.appleSpeech)
            }
            return TranscriptionConfiguration(
                sourceMode: preferences.sourceMode,
                chineseScriptPreference: preferences.chineseScriptPreference,
                endpointSilenceSeconds: preferences.endpointSilenceSeconds
            )
        }

        guard let descriptor = modelCatalog.models.first(where: {
            $0.id == preferences.selectedASRModelID && $0.task == .transcription
        }), let directory = installedDirectory(for: descriptor) else {
            throw CaptureFailure.automaticModelMissing
        }
        return TranscriptionConfiguration(
            sourceMode: preferences.sourceMode,
            chineseScriptPreference: preferences.chineseScriptPreference,
            modelDirectory: directory,
            endpointSilenceSeconds: preferences.endpointSilenceSeconds
        )
    }

    private func installedDirectory(for descriptor: ModelDescriptor) -> URL? {
        guard let container = ModelStoreLayout.containerURL() else { return nil }
        let directory = ModelStoreLayout.modelDirectory(for: descriptor, in: container)
        let metadataURL = ModelStoreLayout.metadataURL(for: descriptor, in: container)
        guard FileManager.default.fileExists(atPath: directory.path),
              let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(ModelInstallMetadata.self, from: data),
              metadata.id == descriptor.id,
              metadata.revision == descriptor.revision else {
            return nil
        }
        return directory
    }

    private func startTranslationUpdates() {
        translationUpdatesTask = Task { [weak self] in
            guard let self else { return }
            for await update in translationScheduler.updates {
                guard !Task.isCancelled else { return }
                switch update {
                case .translated(let segmentID, let text, let isFinal, _):
                    self.overlayState.segments = await self.segmentStore.applyTranslation(
                        segmentID: segmentID,
                        text: text,
                        limit: self.overlayRetentionLimit
                    )
                    self.overlayState.statusText = self.captureStatusText
                    if isFinal {
                        try? await self.sessionLogWriter.recordTranslation(id: segmentID, text: text)
                    }
                case .failed:
                    self.overlayState.statusText = self.t("Translation failed — showing transcript")
                }
            }
        }
    }

    private func startPowerMonitoring() {
        powerTask = Task { [weak self] in
            guard let self else { return }
            for await event in powerMonitor.events {
                switch event {
                case .willSleep:
                    if await recovery.prepareForSleep(state: captureState) {
                        overlayState.isListening = false
                        await audioCapture.suspendForSleep()
                    }
                case .didWake:
                    if await recovery.shouldRestartAfterWake(
                        permissionAvailable: true,
                        outputDeviceAvailable: true
                    ) {
                        do {
                            try await audioCapture.resumeAfterWake()
                            overlayState.isListening = true
                        } catch {
                            await fail(Self.captureFailure(from: error))
                        }
                    }
                case .memoryPressure(let level):
                    await handleMemoryPressure(level)
                }
            }
        }
    }

    private func startCaptureEventMonitoring() {
        captureEventsTask = Task { [weak self] in
            guard let self else { return }
            for await event in audioCapture.events {
                guard captureState == .running else { continue }
                switch event {
                case .running: overlayState.statusText = captureStatusText
                case .reconfiguring: overlayState.statusText = t("Reconfiguring audio output")
                case .failed(let error):
                    if case .permissionDenied = error {
                        await fail(.permissionRevoked)
                    } else {
                        await fail(Self.captureFailure(from: error))
                    }
                case .stopped: break
                }
            }
        }
    }

    private func transition(to state: CaptureState) async throws {
        captureState = try await stateMachine.transition(to: state)
    }

    private var overlayRetentionLimit: Int {
        preferences.overlayLineCount * 4
    }

    private func fail(_ failure: CaptureFailure) async {
        if captureState == .stopping { return }
        do {
            captureState = try await stateMachine.transition(to: .failed(failure))
        } catch {
            captureState = .failed(failure)
        }
        overlayState.statusText = AppCopy.captureFailure(failure, language: preferences.appDisplayLanguage)
        transcriptionTask?.cancel()
        transcriptionTask = nil
        await activeTranscriptionProvider?.stop()
        activeTranscriptionProvider = nil
        await translationScheduler.cancelAll()
        await appleTranslation.cancelAll()
        await qwenTranslation.cancelAll()
        await qwenTranslation.unload()
        await audioCapture.stop()
        await stopSessionLogging()
        mlxTranslationReady = false
        memoryPressureTranslationFallbackActive = false
        overlayState.isListening = false
    }

    private func handleMemoryPressure(_ level: MemoryPressureLevel) async {
        let action = MemoryPressureRecoveryPolicy.action(
            level: level,
            captureIsActive: captureIsActive,
            mlxTranslationIsLoaded: mlxTranslationReady
        )
        switch action {
        case .keepActiveModels:
            break
        case .releaseUnusedModels:
            await qwenASR.stop()
            await qwenTranslation.unload()
            mlxTranslationReady = false
        case .fallbackMLXTranslation:
            await qwenTranslation.cancelAll()
            await qwenTranslation.unload()
            mlxTranslationReady = false
            memoryPressureTranslationFallbackActive = true
            overlayState.statusText = captureStatusText
        }
    }

    private func startSessionLoggingIfNeeded() async {
        sessionLoggingError = nil
        guard preferences.sessionLoggingEnabled,
              let bookmark = preferences.sessionLogDirectoryBookmark else { return }
        var stale = false
        do {
            let directory = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard directory.startAccessingSecurityScopedResource() else {
                throw CocoaError(.fileReadNoPermission)
            }
            activeSessionLogDirectory = directory
            if stale {
                preferences.sessionLogDirectoryBookmark = try directory.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            }
            try await sessionLogWriter.start(directory: directory)
        } catch {
            activeSessionLogDirectory?.stopAccessingSecurityScopedResource()
            activeSessionLogDirectory = nil
            sessionLoggingError = "Session files could not be created in the selected folder."
        }
    }

    private func stopSessionLogging() async {
        await sessionLogWriter.finish()
        activeSessionLogDirectory?.stopAccessingSecurityScopedResource()
        activeSessionLogDirectory = nil
    }

    private func t(_ english: String) -> String {
        AppCopy.text(english, language: preferences.appDisplayLanguage)
    }

    private var captureIsActive: Bool {
        switch captureState {
        case .requestingPermission, .preparingModels, .running, .stopping: true
        case .idle, .failed: false
        }
    }

    private var captureStatusText: String {
        memoryPressureTranslationFallbackActive
            ? t("Memory pressure — using Apple Translation")
            : t("Capturing")
    }

    private static func captureFailure(from error: Error) -> CaptureFailure {
        if let failure = error as? CaptureFailure { return failure }
        if let audioError = error as? CoreAudioTapError {
            switch audioError {
            case .permissionDenied: return .permissionDenied
            case .outputDeviceUnavailable: return .outputDeviceUnavailable
            default: return .audioSystem(audioError.localizedDescription)
            }
        }
        if let registryError = error as? ProviderRegistryError {
            switch registryError {
            case .automaticDetectionUnsupported: return .automaticModelMissing
            case .languageUnsupported(_, let language): return .unsupportedLanguage(language)
            default: return .modelLoadFailed
            }
        }
        if let speechError = error as? AppleSpeechProviderError {
            switch speechError {
            case .automaticModeUnsupported: return .automaticModelMissing
            case .localeUnsupported(let language): return .unsupportedLanguage(language)
            case .assetUnavailable(let language): return .speechLanguagePackUnavailable(language)
            case .incompatibleAudioFormat: return .audioSystem("The transcription audio format is incompatible.")
            case .audioReadFailed: return .audioSystem("Apple Speech could not read the audio stream.")
            case .notPrepared: return .modelLoadFailed
            }
        }
        if let mlxError = error as? Qwen3ASRAdapterError {
            switch mlxError {
            case .unsupportedLanguage: return .unsupportedDetectedLanguage
            case .modelDirectoryMissing, .modelNotPrepared: return .modelLoadFailed
            }
        }
        return .modelLoadFailed
    }
}
