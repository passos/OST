import Carbon.HIToolbox
import Foundation
import OSTCore

/// 'OSTH'. File scope because the Carbon callback below is nonisolated.
private let globalHotKeySignature = OSType(0x4F535448)

private func globalHotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return noErr }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    // The handler is installed on the process-wide dispatcher target, so every Carbon hot
    // key in the process arrives here -- including any that Apple frameworks register.
    // Claiming those would swallow them; ours are the ones carrying our signature.
    guard hotKeyID.signature == globalHotKeySignature else { return OSStatus(eventNotHandledErr) }

    return MainActor.assumeIsolated {
        GlobalHotKey.dispatch(id: hotKeyID.id) ? noErr : OSStatus(eventNotHandledErr)
    }
}

@MainActor
final class GlobalHotKey {
    static var installedEventHandlerCountForTesting: Int {
        eventHandlerRef == nil ? 0 : 1
    }

    private static var nextID: UInt32 = 1
    private static var eventHandlerRef: EventHandlerRef?
    private static var registrars: [UInt32: GlobalHotKey] = [:]

    private let id: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var action: (() -> Void)?

    init() {
        id = Self.nextID
        Self.nextID += 1
    }

    func setAction(_ action: @escaping () -> Void) {
        self.action = action
    }

    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        guard CaptureShortcut.isAcceptableBinding(keyCode: keyCode, modifiers: modifiers) else {
            return false
        }
        unregister()
        guard Self.installEventHandlerIfNeeded() else { return false }

        let hotKeyID = EventHotKeyID(signature: globalHotKeySignature, id: id)
        var registeredRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &registeredRef
        )
        guard status == noErr, let registeredRef else { return false }

        hotKeyRef = registeredRef
        // Registration hands ownership to the process-wide table: a hot key is a global
        // resource and stays claimed until unregister() gives it back.
        Self.registrars[id] = self
        return true
    }

    func unregister() {
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
        Self.registrars.removeValue(forKey: id)
    }

    /// Returns whether the event belonged to a live registrar, so an id we no longer know
    /// about is handed back to Carbon rather than silently absorbed.
    @discardableResult
    fileprivate static func dispatch(id: UInt32) -> Bool {
        guard let action = registrars[id]?.action else { return false }
        action()
        return true
    }

    private static func installEventHandlerIfNeeded() -> Bool {
        guard eventHandlerRef == nil else { return true }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var installedRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            globalHotKeyEventHandler,
            1,
            &eventSpec,
            nil,
            &installedRef
        )
        guard status == noErr, let installedRef else { return false }

        eventHandlerRef = installedRef
        return true
    }
}
