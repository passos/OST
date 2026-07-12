import AppKit
import Foundation
import OSTCore

public enum PowerStateEvent: Sendable {
    case willSleep
    case didWake
    case memoryPressure(MemoryPressureLevel)
}

private final class WorkspaceObserverBag: @unchecked Sendable {
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter) {
        self.notificationCenter = notificationCenter
    }

    func append(_ observer: NSObjectProtocol) {
        observers.append(observer)
    }

    func invalidate() {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    deinit {
        invalidate()
    }
}

@MainActor
public final class PowerStateMonitor {
    public let events: AsyncStream<PowerStateEvent>

    private let continuation: AsyncStream<PowerStateEvent>.Continuation
    private let observerBag: WorkspaceObserverBag
    private let memoryPressureSource: DispatchSourceMemoryPressure

    public init(notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        let pair = AsyncStream<PowerStateEvent>.makeStream(bufferingPolicy: .bufferingNewest(2))
        events = pair.stream
        continuation = pair.continuation
        observerBag = WorkspaceObserverBag(notificationCenter: notificationCenter)
        let memoryPressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        self.memoryPressureSource = memoryPressureSource
        memoryPressureSource.setEventHandler { [continuation, memoryPressureSource] in
            let pressure = memoryPressureSource.data
            continuation.yield(.memoryPressure(
                pressure.contains(.critical) ? .critical : .warning
            ))
        }
        memoryPressureSource.resume()
        observerBag.append(notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [continuation] _ in
            continuation.yield(.willSleep)
        })
        observerBag.append(notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [continuation] _ in
            continuation.yield(.didWake)
        })
    }

    deinit {
        memoryPressureSource.cancel()
        observerBag.invalidate()
        continuation.finish()
    }
}
