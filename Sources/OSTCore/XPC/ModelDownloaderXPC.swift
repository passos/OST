import Foundation

@objc(OSTModelDownloaderXPCProtocol)
public protocol ModelDownloaderXPCProtocol {
    func installModel(
        _ modelID: NSString,
        revision: NSString,
        allowedFiles: [NSString],
        withReply reply: @escaping (NSUUID?, NSError?) -> Void
    )

    func resumeModel(
        _ modelID: NSString,
        revision: NSString,
        allowedFiles: [NSString],
        withReply reply: @escaping (NSUUID?, NSError?) -> Void
    )

    func cancelInstall(
        _ requestID: NSUUID,
        withReply reply: @escaping (NSError?) -> Void
    )

    func installationStatus(
        _ requestID: NSUUID,
        withReply reply: @escaping (NSData?, NSError?) -> Void
    )

    func deleteModel(
        _ modelID: NSString,
        revision: NSString,
        withReply reply: @escaping (NSError?) -> Void
    )
}

public struct ModelDownloadStatus: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case queued
        case checkingDisk
        case downloading
        case verifying
        case installing
        case completed
        case cancelled
        case failed
    }

    public let requestID: UUID
    public let modelID: String
    public let revision: String
    public var phase: Phase
    public var completedBytes: Int64
    public let totalBytes: Int64

    public init(
        requestID: UUID,
        modelID: String,
        revision: String,
        phase: Phase,
        completedBytes: Int64,
        totalBytes: Int64
    ) {
        self.requestID = requestID
        self.modelID = modelID
        self.revision = revision
        self.phase = phase
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }

    public func encoded() throws -> NSData {
        try JSONEncoder().encode(self) as NSData
    }

    public static func decode(_ data: Data) throws -> ModelDownloadStatus {
        try JSONDecoder().decode(ModelDownloadStatus.self, from: data)
    }
}
