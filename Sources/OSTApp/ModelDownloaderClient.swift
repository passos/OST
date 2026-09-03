import Foundation
import Combine
import OSTCore

private final class XPCConnectionBox: @unchecked Sendable {
    var value: NSXPCConnection?

    func invalidate() {
        value?.invalidate()
        value = nil
    }

    deinit {
        invalidate()
    }
}

@MainActor
final class ModelDownloaderClient: ObservableObject {
    @Published var statusByModelID: [String: ModelDownloadStatus] = [:]
    @Published var errorByModelID: [String: String] = [:]

    private let connectionBox = XPCConnectionBox()
    private var pollingTasks: [String: Task<Void, Never>] = [:]
    private var pollGeneration: [String: UInt64] = [:]

    deinit {
        connectionBox.invalidate()
        pollingTasks.values.forEach { $0.cancel() }
    }

    func install(_ descriptor: ModelDescriptor) {
        errorByModelID[descriptor.id] = nil
        guard let proxy = proxy() else {
            errorByModelID[descriptor.id] = "The model download service is unavailable."
            return
        }
        proxy.installModel(
            descriptor.id as NSString,
            revision: descriptor.revision as NSString,
            allowedFiles: descriptor.files.map { $0.path as NSString }
        ) { [weak self] requestID, error in
            Task { @MainActor in
                self?.handleStartReply(descriptor, requestID: requestID, error: error)
            }
        }
    }

    func resume(_ descriptor: ModelDescriptor) {
        errorByModelID[descriptor.id] = nil
        guard let proxy = proxy() else {
            errorByModelID[descriptor.id] = "The model download service is unavailable."
            return
        }
        proxy.resumeModel(
            descriptor.id as NSString,
            revision: descriptor.revision as NSString,
            allowedFiles: descriptor.files.map { $0.path as NSString }
        ) { [weak self] requestID, error in
            Task { @MainActor in
                self?.handleStartReply(descriptor, requestID: requestID, error: error)
            }
        }
    }

    func cancel(_ descriptor: ModelDescriptor) {
        guard let requestID = statusByModelID[descriptor.id]?.requestID,
              let proxy = proxy() else { return }
        proxy.cancelInstall(requestID as NSUUID) { [weak self] error in
            Task { @MainActor in
                if error != nil {
                    self?.errorByModelID[descriptor.id] = "The model download could not be cancelled."
                }
            }
        }
    }

    func delete(_ descriptor: ModelDescriptor) {
        guard let proxy = proxy() else { return }
        proxy.deleteModel(
            descriptor.id as NSString,
            revision: descriptor.revision as NSString
        ) { [weak self] error in
            Task { @MainActor in
                if error != nil {
                    self?.errorByModelID[descriptor.id] = "The downloaded model could not be deleted."
                } else {
                    self?.statusByModelID[descriptor.id] = nil
                }
            }
        }
    }

    func isInstalled(_ descriptor: ModelDescriptor) -> Bool {
        guard let container = ModelStoreLayout.containerURL() else { return false }
        let metadataURL = ModelStoreLayout.metadataURL(for: descriptor, in: container)
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(ModelInstallMetadata.self, from: data) else {
            return false
        }
        return metadata.id == descriptor.id && metadata.revision == descriptor.revision
    }

    private func poll(descriptor: ModelDescriptor, requestID: UUID) {
        pollingTasks[descriptor.id]?.cancel()
        // Retire only our own handle: re-installing the same model replaces the task, and a
        // finishing task's cleanup must not delete the newer poller's entry.
        let generation = (pollGeneration[descriptor.id] ?? 0) &+ 1
        pollGeneration[descriptor.id] = generation
        pollingTasks[descriptor.id] = Task { [weak self] in
            defer {
                if self?.pollGeneration[descriptor.id] == generation {
                    self?.pollingTasks[descriptor.id] = nil
                }
            }
            while !Task.isCancelled {
                guard let self, let proxy = self.proxy() else { return }
                let status = await withCheckedContinuation { continuation in
                    proxy.installationStatus(requestID as NSUUID) { data, _ in
                        let decoded = data.flatMap { try? ModelDownloadStatus.decode($0 as Data) }
                        continuation.resume(returning: decoded)
                    }
                }
                if let status {
                    self.statusByModelID[descriptor.id] = status
                    if [.completed, .cancelled, .failed].contains(status.phase) { return }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func handleStartReply(
        _ descriptor: ModelDescriptor,
        requestID: NSUUID?,
        error: NSError?
    ) {
        guard error == nil, let requestID else {
            errorByModelID[descriptor.id] = "The model download could not be started."
            return
        }
        poll(descriptor: descriptor, requestID: requestID as UUID)
    }

    private func proxy() -> ModelDownloaderXPCProtocol? {
        let connection: NSXPCConnection
        if let existing = connectionBox.value {
            connection = existing
        } else {
            connection = NSXPCConnection(serviceName: "com.reserve.OST.ModelDownloader")
            connection.remoteObjectInterface = NSXPCInterface(with: ModelDownloaderXPCProtocol.self)
            connection.interruptionHandler = { [weak self] in
                Task { @MainActor in self?.connectionBox.value = nil }
            }
            connection.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.connectionBox.value = nil }
            }
            connection.resume()
            connectionBox.value = connection
        }
        return connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in self?.connectionBox.value = nil }
        } as? ModelDownloaderXPCProtocol
    }
}
