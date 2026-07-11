import Foundation
import OSTCore

public enum ModelInstallerError: Error, Sendable {
    case modelNotAllowlisted
    case requestDoesNotMatchManifest
    case appGroupUnavailable
    case insufficientDiskSpace(required: Int64, available: Int64)
    case invalidDownloadURL
    case requestNotFound
}

public actor ModelInstaller {
    private let catalog: ModelCatalog
    private let containerURL: URL
    private let fileManager: FileManager
    private let downloader: any FileDownloading
    private let diskCapacityChecker: any DiskCapacityChecking

    private var statuses: [UUID: ModelDownloadStatus] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    public init(
        catalog: ModelCatalog,
        containerURL: URL,
        fileManager: FileManager = .default,
        downloader: any FileDownloading = ResumableFileDownloader(),
        diskCapacityChecker: any DiskCapacityChecking = VolumeDiskCapacityChecker()
    ) {
        self.catalog = catalog
        self.containerURL = containerURL
        self.fileManager = fileManager
        self.downloader = downloader
        self.diskCapacityChecker = diskCapacityChecker
    }

    public func install(
        modelID: String,
        revision: String,
        allowedFiles: [String]
    ) throws -> UUID {
        let descriptor = try validatedDescriptor(
            modelID: modelID,
            revision: revision,
            allowedFiles: allowedFiles
        )
        let requestID = UUID()
        statuses[requestID] = ModelDownloadStatus(
            requestID: requestID,
            modelID: descriptor.id,
            revision: descriptor.revision,
            phase: .queued,
            completedBytes: 0,
            totalBytes: descriptor.downloadBytes
        )
        let task = Task { [weak self] in
            do {
                try await self?.performInstall(descriptor: descriptor, requestID: requestID)
            } catch is CancellationError {
                await self?.setPhase(.cancelled, requestID: requestID)
            } catch {
                await self?.setPhase(.failed, requestID: requestID)
            }
            await self?.removeTask(requestID)
        }
        tasks[requestID] = task
        return requestID
    }

    public func resume(
        modelID: String,
        revision: String,
        allowedFiles: [String]
    ) throws -> UUID {
        try install(modelID: modelID, revision: revision, allowedFiles: allowedFiles)
    }

    public func cancel(requestID: UUID) throws {
        guard let task = tasks[requestID] else { throw ModelInstallerError.requestNotFound }
        task.cancel()
    }

    public func status(requestID: UUID) throws -> ModelDownloadStatus {
        guard let status = statuses[requestID] else { throw ModelInstallerError.requestNotFound }
        return status
    }

    public func delete(modelID: String, revision: String) async throws {
        guard let descriptor = catalog.descriptor(id: modelID, revision: revision) else {
            throw ModelInstallerError.modelNotAllowlisted
        }
        let matchingTasks = statuses.compactMap { requestID, status -> Task<Void, Never>? in
            guard status.modelID == descriptor.id,
                  status.revision == descriptor.revision else { return nil }
            return tasks[requestID]
        }
        for task in matchingTasks { task.cancel() }
        for task in matchingTasks { await task.value }

        let staging = ModelStoreLayout.stagingRoot(in: containerURL)
            .appending(path: ModelStoreLayout.safeComponent(descriptor.id), directoryHint: .isDirectory)
            .appending(path: descriptor.revision, directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: staging.path) {
            try fileManager.removeItem(at: staging)
        }
        let directory = ModelStoreLayout.modelDirectory(for: descriptor, in: containerURL)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    private func performInstall(descriptor: ModelDescriptor, requestID: UUID) async throws {
        try Task.checkCancellation()
        setPhase(.checkingDisk, requestID: requestID)
        let destination = ModelStoreLayout.modelDirectory(for: descriptor, in: containerURL)
        if isVerifiedInstallation(descriptor, at: destination) {
            setProgress(descriptor.downloadBytes, requestID: requestID)
            setPhase(.completed, requestID: requestID)
            return
        }
        let safetyMargin: Int64 = 268_435_456
        let (required, overflow) = descriptor.downloadBytes.addingReportingOverflow(safetyMargin)
        let available = try diskCapacityChecker.availableCapacity(at: containerURL)
        guard !overflow, available >= required else {
            throw ModelInstallerError.insufficientDiskSpace(
                required: overflow ? Int64.max : required,
                available: available
            )
        }

        let staging = ModelStoreLayout.stagingRoot(in: containerURL)
            .appending(path: ModelStoreLayout.safeComponent(descriptor.id), directoryHint: .isDirectory)
            .appending(path: descriptor.revision, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let resumeRoot = staging.appending(path: ".resume", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: resumeRoot, withIntermediateDirectories: true)

        var completed: Int64 = 0
        for file in descriptor.files {
            try Task.checkCancellation()
            let destination = staging.appending(path: file.path)
            if fileManager.fileExists(atPath: destination.path),
               (try? FileHashVerifier.verify(destination, descriptor: file)) != nil {
                completed += file.bytes
                setProgress(completed, requestID: requestID)
                continue
            }

            setPhase(.downloading, requestID: requestID)
            guard let url = URL(
                string: "https://huggingface.co/\(descriptor.id)/resolve/\(descriptor.revision)/\(file.path)"
            ) else {
                throw ModelInstallerError.invalidDownloadURL
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 120
            let resumeURL = resumeRoot.appending(
                path: ModelStoreLayout.safeComponent(file.path) + ".resume"
            )
            let priorCompleted = completed
            try await downloader.download(
                request: request,
                destination: destination,
                resumeDataURL: resumeURL
            ) { [weak self] bytes, _ in
                Task { await self?.setProgress(priorCompleted + bytes, requestID: requestID) }
            }

            setPhase(.verifying, requestID: requestID)
            do {
                try FileHashVerifier.verify(destination, descriptor: file)
            } catch {
                try? fileManager.removeItem(at: destination)
                throw error
            }
            completed += file.bytes
            setProgress(completed, requestID: requestID)
        }

        try Task.checkCancellation()
        setPhase(.installing, requestID: requestID)
        try? fileManager.removeItem(at: resumeRoot)
        let metadata = ModelInstallMetadata(
            id: descriptor.id,
            revision: descriptor.revision,
            verifiedFiles: descriptor.files,
            installedAt: Date(),
            acceptedLicenseSPDXID: descriptor.license.spdxID
        )
        let metadataData = try JSONEncoder().encode(metadata)
        try metadataData.write(
            to: staging.appending(path: "install-metadata.json"),
            options: .atomic
        )

        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
        setProgress(descriptor.downloadBytes, requestID: requestID)
        setPhase(.completed, requestID: requestID)
    }

    private func isVerifiedInstallation(_ descriptor: ModelDescriptor, at directory: URL) -> Bool {
        let metadataURL = directory.appending(path: "install-metadata.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(ModelInstallMetadata.self, from: data),
              metadata.id == descriptor.id,
              metadata.revision == descriptor.revision,
              metadata.verifiedFiles == descriptor.files,
              metadata.acceptedLicenseSPDXID == descriptor.license.spdxID else {
            return false
        }
        return descriptor.files.allSatisfy { file in
            let url = directory.appending(path: file.path)
            return (try? FileHashVerifier.verify(url, descriptor: file)) != nil
        }
    }

    private func validatedDescriptor(
        modelID: String,
        revision: String,
        allowedFiles: [String]
    ) throws -> ModelDescriptor {
        guard let descriptor = catalog.descriptor(id: modelID, revision: revision) else {
            throw ModelInstallerError.modelNotAllowlisted
        }
        guard Set(allowedFiles) == Set(descriptor.files.map(\.path)),
              allowedFiles.count == descriptor.files.count else {
            throw ModelInstallerError.requestDoesNotMatchManifest
        }
        return descriptor
    }

    private func setPhase(_ phase: ModelDownloadStatus.Phase, requestID: UUID) {
        statuses[requestID]?.phase = phase
    }

    private func setProgress(_ bytes: Int64, requestID: UUID) {
        guard let total = statuses[requestID]?.totalBytes else { return }
        statuses[requestID]?.completedBytes = min(max(0, bytes), total)
    }

    private func removeTask(_ requestID: UUID) {
        tasks[requestID] = nil
    }
}
