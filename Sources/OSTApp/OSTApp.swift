import AppKit
import SwiftUI
import Translation

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct OSTApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        Task { @MainActor in await model.activate() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Label("OST", systemImage: "captions.bubble")
                .translationTask(model.translationPackCoordinator.configuration) { session in
                    await model.translationPackCoordinator.prepare(using: session)
                }
        }

        Settings {
            SettingsView(model: model)
                .environment(\.locale, Locale(identifier: model.preferences.appDisplayLanguage.localeIdentifier))
        }
    }
}
