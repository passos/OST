import Foundation
import OSTCore
@testable import OSTDownloader
import Testing

private final class StubResponseURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let isSuccessful = url.lastPathComponent == "success.bin"
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: isSuccessful ? 200 : 404,
            httpVersion: nil,
            headerFields: nil
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data((isSuccessful ? "fixture" : "not found").utf8)
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor FixtureDownloader: FileDownloading {
    let data: Data
    let delay: Duration

    init(data: Data, delay: Duration = .zero) {
        self.data = data
        self.delay = delay
    }

    func download(
        request: URLRequest,
        destination: URL,
        resumeDataURL: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        if delay > .zero { try await Task.sleep(for: delay) }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        progress(Int64(data.count), Int64(data.count))
    }
}

private struct FixedDiskCapacityChecker: DiskCapacityChecking {
    let bytes: Int64

    func availableCapacity(at directory: URL) throws -> Int64 {
        bytes
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "OSTTests-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func fixtureCatalog(data: Data) throws -> (ModelCatalog, ModelDescriptor) {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "fixture.bin")
    try data.write(to: file)
    let descriptor = ModelDescriptor(
        id: "fixture/model",
        revision: String(repeating: "a", count: 40),
        adapter: .qwen3Translation,
        task: .translation,
        quantization: "test",
        supportedLanguages: [.english, .korean],
        capabilities: ModelCapabilities(experimental: true),
        downloadBytes: Int64(data.count),
        estimatedPeakBytes: 1,
        license: ModelLicense(spdxID: "MIT", name: "MIT", noticeResource: "MIT.txt"),
        files: [ModelFileDescriptor(
            path: "fixture.bin",
            bytes: Int64(data.count),
            sha256: try FileHashVerifier.sha256(of: file)
        )]
    )
    return (ModelCatalog(schemaVersion: 1, models: [descriptor]), descriptor)
}

private func waitForTerminalStatus(
    installer: ModelInstaller,
    requestID: UUID
) async throws -> ModelDownloadStatus {
    for _ in 0..<200 {
        let status = try await installer.status(requestID: requestID)
        if [.completed, .cancelled, .failed].contains(status.phase) { return status }
        try await Task.sleep(for: .milliseconds(10))
    }
    return try await installer.status(requestID: requestID)
}

@Test func fileHashVerifierDetectsCorruption() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "fixture.bin")
    try Data("fixture".utf8).write(to: file)
    let descriptor = ModelFileDescriptor(
        path: "fixture.bin",
        bytes: 7,
        sha256: String(repeating: "0", count: 64)
    )
    #expect(throws: FileVerificationError.self) {
        try FileHashVerifier.verify(file, descriptor: descriptor)
    }
}

@Test func resumableDownloaderRejectsHTTPErrorResponses() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubResponseURLProtocol.self]
    let downloader = ResumableFileDownloader(configuration: configuration)
    let destination = root.appending(path: "fixture.bin")
    let requestURL = try #require(URL(string: "https://example.invalid/fixture.bin"))

    await #expect(throws: ResumableDownloadError.responseRejected) {
        try await downloader.download(
            request: URLRequest(url: requestURL),
            destination: destination,
            resumeDataURL: root.appending(path: "fixture.resume")
        ) { _, _ in }
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func resumableDownloaderMovesSuccessfulHTTPResponses() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubResponseURLProtocol.self]
    let downloader = ResumableFileDownloader(configuration: configuration)
    let destination = root.appending(path: "fixture.bin")
    let requestURL = try #require(URL(string: "https://example.invalid/success.bin"))

    try await downloader.download(
        request: URLRequest(url: requestURL),
        destination: destination,
        resumeDataURL: root.appending(path: "fixture.resume")
    ) { _, _ in }

    #expect(try Data(contentsOf: destination) == Data("fixture".utf8))
}

@Test func resumableDownloaderImmediateCancellationCompletes() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubResponseURLProtocol.self]
    let downloader = ResumableFileDownloader(configuration: configuration)
    let requestURL = try #require(URL(string: "https://example.invalid/fixture.bin"))
    let task = Task {
        try await downloader.download(
            request: URLRequest(url: requestURL),
            destination: root.appending(path: "fixture.bin"),
            resumeDataURL: root.appending(path: "fixture.resume")
        ) { _, _ in }
    }

    task.cancel()
    await #expect(throws: CancellationError.self) {
        try await task.value
    }
}

@Test func installerVerifiesAndAtomicallyInstallsFixture() async throws {
    let data = Data("verified model fixture".utf8)
    let (catalog, descriptor) = try fixtureCatalog(data: data)
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let installer = ModelInstaller(
        catalog: catalog,
        containerURL: root,
        downloader: FixtureDownloader(data: data)
    )
    let requestID = try await installer.install(
        modelID: descriptor.id,
        revision: descriptor.revision,
        allowedFiles: descriptor.files.map(\.path)
    )
    let status = try await waitForTerminalStatus(installer: installer, requestID: requestID)
    #expect(status.phase == .completed)
    let installed = ModelStoreLayout.modelDirectory(for: descriptor, in: root)
    #expect(FileManager.default.fileExists(atPath: installed.appending(path: "fixture.bin").path))
    #expect(FileManager.default.fileExists(atPath: installed.appending(path: "install-metadata.json").path))
}

@Test func installerRejectsCorruptDownload() async throws {
    let expected = Data("expected".utf8)
    let (catalog, descriptor) = try fixtureCatalog(data: expected)
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let installer = ModelInstaller(
        catalog: catalog,
        containerURL: root,
        downloader: FixtureDownloader(data: Data("corrupt".utf8))
    )
    let requestID = try await installer.install(
        modelID: descriptor.id,
        revision: descriptor.revision,
        allowedFiles: descriptor.files.map(\.path)
    )
    let status = try await waitForTerminalStatus(installer: installer, requestID: requestID)
    #expect(status.phase == .failed)
}

@Test func installerRejectsInsufficientDiskSpaceBeforeDownload() async throws {
    let data = Data("disk fixture".utf8)
    let (catalog, descriptor) = try fixtureCatalog(data: data)
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let installer = ModelInstaller(
        catalog: catalog,
        containerURL: root,
        downloader: FixtureDownloader(data: data),
        diskCapacityChecker: FixedDiskCapacityChecker(bytes: 0)
    )
    let requestID = try await installer.install(
        modelID: descriptor.id,
        revision: descriptor.revision,
        allowedFiles: descriptor.files.map(\.path)
    )
    let status = try await waitForTerminalStatus(installer: installer, requestID: requestID)
    #expect(status.phase == .failed)
    let staging = ModelStoreLayout.stagingRoot(in: root)
    #expect(!FileManager.default.fileExists(atPath: staging.path))
}

@Test func installerReplacesCorruptExistingRevision() async throws {
    let data = Data("verified replacement".utf8)
    let (catalog, descriptor) = try fixtureCatalog(data: data)
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let installed = ModelStoreLayout.modelDirectory(for: descriptor, in: root)
    try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
    try Data("corrupt".utf8).write(to: installed.appending(path: "fixture.bin"))

    let installer = ModelInstaller(
        catalog: catalog,
        containerURL: root,
        downloader: FixtureDownloader(data: data)
    )
    let requestID = try await installer.install(
        modelID: descriptor.id,
        revision: descriptor.revision,
        allowedFiles: descriptor.files.map(\.path)
    )
    let status = try await waitForTerminalStatus(installer: installer, requestID: requestID)
    #expect(status.phase == .completed)
    #expect(try Data(contentsOf: installed.appending(path: "fixture.bin")) == data)
    #expect(FileManager.default.fileExists(
        atPath: installed.appending(path: "install-metadata.json").path
    ))
}

@Test func installerCancellationIsObservableAndResumeCanStart() async throws {
    let data = Data("resume fixture".utf8)
    let (catalog, descriptor) = try fixtureCatalog(data: data)
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let installer = ModelInstaller(
        catalog: catalog,
        containerURL: root,
        downloader: FixtureDownloader(data: data, delay: .seconds(2))
    )
    let requestID = try await installer.install(
        modelID: descriptor.id,
        revision: descriptor.revision,
        allowedFiles: descriptor.files.map(\.path)
    )
    try await installer.cancel(requestID: requestID)
    let cancelled = try await waitForTerminalStatus(installer: installer, requestID: requestID)
    #expect(cancelled.phase == .cancelled)

    let resumedID = try await installer.resume(
        modelID: descriptor.id,
        revision: descriptor.revision,
        allowedFiles: descriptor.files.map(\.path)
    )
    #expect(resumedID != requestID)
}

@Test func deletingCancelledModelRemovesStagingData() async throws {
    let data = Data("delete fixture".utf8)
    let (catalog, descriptor) = try fixtureCatalog(data: data)
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let installer = ModelInstaller(
        catalog: catalog,
        containerURL: root,
        downloader: FixtureDownloader(data: data, delay: .seconds(2))
    )
    let requestID = try await installer.install(
        modelID: descriptor.id,
        revision: descriptor.revision,
        allowedFiles: descriptor.files.map(\.path)
    )
    try? await Task.sleep(for: .milliseconds(50))
    try await installer.delete(modelID: descriptor.id, revision: descriptor.revision)
    let status = try await installer.status(requestID: requestID)
    #expect(status.phase == .cancelled)
    let staging = ModelStoreLayout.stagingRoot(in: root)
        .appending(path: ModelStoreLayout.safeComponent(descriptor.id))
        .appending(path: descriptor.revision)
    #expect(!FileManager.default.fileExists(atPath: staging.path))
}

@Test func installerRejectsRevisionOrFileListOutsideManifest() async throws {
    let data = Data("fixture".utf8)
    let (catalog, descriptor) = try fixtureCatalog(data: data)
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let installer = ModelInstaller(catalog: catalog, containerURL: root)
    await #expect(throws: ModelInstallerError.self) {
        try await installer.install(
            modelID: descriptor.id,
            revision: String(repeating: "b", count: 40),
            allowedFiles: descriptor.files.map(\.path)
        )
    }
    await #expect(throws: ModelInstallerError.self) {
        try await installer.install(
            modelID: descriptor.id,
            revision: descriptor.revision,
            allowedFiles: ["unexpected.bin"]
        )
    }
}
