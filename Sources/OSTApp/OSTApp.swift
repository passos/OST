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
            SettingsSceneBridgeLabel()
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

extension Notification.Name {
    static let ostOpenSettings = Notification.Name("com.reserve.OST.open-settings")
}

private struct SettingsSceneBridgeLabel: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Label("OST", systemImage: "captions.bubble")
            .onReceive(NotificationCenter.default.publisher(for: .ostOpenSettings)) { _ in
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
                Task { @MainActor in
                    await SettingsWindowPresenter.bringForward()
                }
            }
    }
}

@MainActor
enum SettingsWindowPresenter {
    private static let settingsWindowIdentifier = "com_apple_SwiftUI_Settings_window"

    static func bringForward() async {
        NSApp.activate(ignoringOtherApps: true)
        for attempt in 0..<20 {
            if let window = NSApp.windows.first(where: {
                $0.identifier?.rawValue == settingsWindowIdentifier
            }) {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                return
            }
            if attempt < 19 {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}
