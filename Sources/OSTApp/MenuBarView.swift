import AppKit
import OSTCore
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            Label(statusLabel, systemImage: statusImage)
            if let language = model.menuDetectedLanguage {
                Text("\(t("Detected:")) \(AppCopy.languageName(language, displayLanguage: model.preferences.appDisplayLanguage))")
            }

            Divider()

            Button(model.captureState.toggleIntent == .stop ? t("Stop") : t("Start")) {
                Task {
                    await model.toggleCapture()
                }
            }

            Picker(t("Input language"), selection: sourceModeBinding) {
                Text(t("Automatic detection (MLX ASR)"))
                    .tag(SourceLanguageMode.automatic)
                    .disabled(model.preferences.transcriptionProvider != .qwen3ASR)
                ForEach(SupportedLanguage.productPickerCases, id: \.self) { productLanguage in
                    let language = productLanguage.applyingChinesePreference(
                        model.preferences.chineseScriptPreference
                    )
                    Text(AppCopy.productLanguageName(productLanguage, displayLanguage: model.preferences.appDisplayLanguage))
                        .tag(SourceLanguageMode.fixed(language))
                        .disabled(
                            model.preferences.transcriptionProvider == .appleSpeech
                                && !model.appleSpeechSupportedLanguages.contains(language)
                        )
                }
            }

            Picker(t("Target language"), selection: targetBinding) {
                ForEach(SupportedLanguage.productPickerCases, id: \.self) { productLanguage in
                    let language = productLanguage.applyingChinesePreference(
                        model.preferences.chineseScriptPreference
                    )
                    Text(AppCopy.productLanguageName(productLanguage, displayLanguage: model.preferences.appDisplayLanguage)).tag(language)
                }
            }

            Divider()

            Button(model.overlayVisible ? t("Hide Overlay") : t("Show Overlay")) {
                model.toggleOverlayVisibility()
            }
            Button(model.preferences.overlayLocked ? t("Unlock Overlay") : t("Lock Overlay")) {
                model.toggleOverlayLock()
            }

            Button(t("Restart Capture")) {
                Task { await model.restartCapture() }
            }
            .disabled(model.captureState != .running)

            Divider()

            Button(t("Settings…")) { model.openSettings() }
            Button(t("Quit")) { NSApplication.shared.terminate(nil) }

        }
    }

    private var sourceModeBinding: Binding<SourceLanguageMode> {
        Binding(
            get: {
                guard case .fixed(let language) = model.preferences.sourceMode else {
                    return model.preferences.sourceMode
                }
                return .fixed(language.applyingChinesePreference(
                    model.preferences.chineseScriptPreference
                ))
            },
            set: { selection in
                guard case .fixed(let language) = selection else {
                    model.preferences.sourceMode = selection
                    return
                }
                model.preferences.sourceMode = .fixed(language.applyingChinesePreference(
                    model.preferences.chineseScriptPreference
                ))
            }
        )
    }

    private var targetBinding: Binding<SupportedLanguage> {
        Binding(
            get: {
                model.preferences.targetLanguage.applyingChinesePreference(
                    model.preferences.chineseScriptPreference
                )
            },
            set: {
                model.preferences.targetLanguage = $0.applyingChinesePreference(
                    model.preferences.chineseScriptPreference
                )
            }
        )
    }

    private var statusLabel: String {
        switch model.captureState {
        case .idle: t("Waiting")
        case .requestingPermission: t("Checking permission")
        case .preparingModels: t("Preparing models")
        case .running: model.menuStatusText
        case .stopping: t("Stopping")
        case .failed(let failure): AppCopy.captureFailure(failure, language: model.preferences.appDisplayLanguage)
        }
    }

    private var statusImage: String {
        switch model.captureState {
        case .running: "waveform.circle.fill"
        case .failed: "exclamationmark.triangle"
        default: "waveform.circle"
        }
    }

    private func t(_ english: String) -> String {
        AppCopy.text(english, language: model.preferences.appDisplayLanguage)
    }
}
