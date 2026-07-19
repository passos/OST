import Foundation

public enum ModelAdapterID: String, Codable, CaseIterable, Sendable {
    case qwen3ASR
    case qwen3Translation
}

public enum ModelTask: String, Codable, Sendable {
    case transcription
    case translation
}

public struct ModelCapabilities: Codable, Equatable, Sendable {
    public let automaticLanguageDetection: Bool
    public let volatileTranscription: Bool
    public let experimental: Bool

    public init(
        automaticLanguageDetection: Bool = false,
        volatileTranscription: Bool = false,
        experimental: Bool
    ) {
        self.automaticLanguageDetection = automaticLanguageDetection
        self.volatileTranscription = volatileTranscription
        self.experimental = experimental
    }
}

public struct ModelLicense: Codable, Equatable, Sendable {
    public let spdxID: String
    public let name: String
    public let noticeResource: String

    public init(spdxID: String, name: String, noticeResource: String) {
        self.spdxID = spdxID
        self.name = name
        self.noticeResource = noticeResource
    }
}

public struct ModelFileDescriptor: Codable, Equatable, Hashable, Sendable {
    public let path: String
    public let bytes: Int64
    public let sha256: String

    public init(path: String, bytes: Int64, sha256: String) {
        self.path = path
        self.bytes = bytes
        self.sha256 = sha256
    }
}

public struct ModelDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let revision: String
    public let adapter: ModelAdapterID
    public let task: ModelTask
    public let quantization: String
    public let supportedLanguages: Set<SupportedLanguage>
    public let capabilities: ModelCapabilities
    public let downloadBytes: Int64
    public let estimatedPeakBytes: Int64
    public let license: ModelLicense
    public let files: [ModelFileDescriptor]

    public init(
        id: String,
        revision: String,
        adapter: ModelAdapterID,
        task: ModelTask,
        quantization: String,
        supportedLanguages: Set<SupportedLanguage>,
        capabilities: ModelCapabilities,
        downloadBytes: Int64,
        estimatedPeakBytes: Int64,
        license: ModelLicense,
        files: [ModelFileDescriptor]
    ) {
        self.id = id
        self.revision = revision
        self.adapter = adapter
        self.task = task
        self.quantization = quantization
        self.supportedLanguages = supportedLanguages
        self.capabilities = capabilities
        self.downloadBytes = downloadBytes
        self.estimatedPeakBytes = estimatedPeakBytes
        self.license = license
        self.files = files
    }
}

public struct ModelCatalog: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let models: [ModelDescriptor]

    public init(schemaVersion: Int, models: [ModelDescriptor]) {
        self.schemaVersion = schemaVersion
        self.models = models
    }

    public static func decode(_ data: Data) throws -> ModelCatalog {
        let catalog = try JSONDecoder().decode(ModelCatalog.self, from: data)
        try catalog.validate()
        return catalog
    }

    public static func bundled() throws -> ModelCatalog {
        guard let url = Bundle.module.url(forResource: "ModelCatalog", withExtension: "json") else {
            throw ModelCatalogError.resourceUnavailable
        }
        return try decode(Data(contentsOf: url))
    }

    public func descriptor(id: String, revision: String) -> ModelDescriptor? {
        models.first { $0.id == id && $0.revision == revision }
    }

    public func validate() throws {
        guard schemaVersion == 1, !models.isEmpty else {
            throw ModelCatalogError.invalidManifest
        }

        var modelKeys: Set<String> = []
        for model in models {
            let modelKey = "\(model.id)@\(model.revision)"
            guard modelKeys.insert(modelKey).inserted,
                  isSafeModelID(model.id),
                  isLowercaseHex(model.revision, count: 40),
                  !model.quantization.isEmpty,
                  !model.supportedLanguages.isEmpty,
                  model.downloadBytes > 0,
                  model.estimatedPeakBytes > 0,
                  !model.license.spdxID.isEmpty,
                  !model.license.name.isEmpty,
                  isSafeRelativePath(model.license.noticeResource),
                  !model.files.isEmpty else {
                throw ModelCatalogError.invalidManifest
            }

            var filePaths: Set<String> = []
            var computedDownloadBytes: Int64 = 0
            for file in model.files {
                let (nextDownloadBytes, overflow) = computedDownloadBytes.addingReportingOverflow(file.bytes)
                guard !overflow,
                      file.bytes > 0,
                      filePaths.insert(file.path).inserted,
                      isSafeRelativePath(file.path),
                      isLowercaseHex(file.sha256, count: 64) else {
                    throw ModelCatalogError.invalidManifest
                }
                computedDownloadBytes = nextDownloadBytes
            }
            guard computedDownloadBytes == model.downloadBytes else {
                throw ModelCatalogError.invalidManifest
            }
        }
    }

    private func isSafeModelID(_ value: String) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.count == 2 && components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\")
        }
    }

    private func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\") else { return false }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.count == count && value.allSatisfy { character in
            character.isNumber || ("a"..."f").contains(character)
        }
    }
}

public enum ModelCatalogError: Error, Equatable {
    case resourceUnavailable
    case invalidManifest
}

public struct ModelInstallMetadata: Codable, Equatable, Sendable {
    public let id: String
    public let revision: String
    public let verifiedFiles: [ModelFileDescriptor]
    public let installedAt: Date
    public let acceptedLicenseSPDXID: String

    public init(
        id: String,
        revision: String,
        verifiedFiles: [ModelFileDescriptor],
        installedAt: Date,
        acceptedLicenseSPDXID: String
    ) {
        self.id = id
        self.revision = revision
        self.verifiedFiles = verifiedFiles
        self.installedAt = installedAt
        self.acceptedLicenseSPDXID = acceptedLicenseSPDXID
    }
}

public enum ModelStoreLayout {
    public static let appGroupIdentifier = "group.com.reserve.OST"

    public static func containerURL(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    public static func modelsRoot(in containerURL: URL) -> URL {
        containerURL.appending(path: "Models", directoryHint: .isDirectory)
    }

    public static func stagingRoot(in containerURL: URL) -> URL {
        modelsRoot(in: containerURL).appending(path: ".staging", directoryHint: .isDirectory)
    }

    public static func modelDirectory(for descriptor: ModelDescriptor, in containerURL: URL) -> URL {
        modelsRoot(in: containerURL)
            .appending(path: safeComponent(descriptor.id), directoryHint: .isDirectory)
            .appending(path: descriptor.revision, directoryHint: .isDirectory)
    }

    public static func metadataURL(for descriptor: ModelDescriptor, in containerURL: URL) -> URL {
        modelDirectory(for: descriptor, in: containerURL)
            .appending(path: "install-metadata.json")
    }

    public static func safeComponent(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "--")
    }
}

public enum ThirdPartyNoticeError: Error, Equatable {
    case invalidResource
    case resourceUnavailable
}

public enum ThirdPartyNotices {
    public static let runtimeResource = "ThirdParty/ThirdPartyNotices.txt"

    public static func text(at resource: String) throws -> String {
        guard !resource.isEmpty,
              !resource.hasPrefix("/"),
              !resource.contains("\\"),
              resource.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else {
            throw ThirdPartyNoticeError.invalidResource
        }

        let fileName = URL(fileURLWithPath: resource).lastPathComponent
        guard let url = Bundle.module.url(forResource: fileName, withExtension: nil) else {
            throw ThirdPartyNoticeError.resourceUnavailable
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
