import Foundation
import OSTCore

public final class ModelDownloaderService: NSObject, ModelDownloaderXPCProtocol, @unchecked Sendable {
    private let installer: ModelInstaller

    private struct XPCReply<Value>: @unchecked Sendable {
        let value: Value
    }

    public init(catalog: ModelCatalog, containerURL: URL) {
        installer = ModelInstaller(catalog: catalog, containerURL: containerURL)
        super.init()
    }

    public func installModel(
        _ modelID: NSString,
        revision: NSString,
        allowedFiles: [NSString],
        withReply reply: @escaping (NSUUID?, NSError?) -> Void
    ) {
        let modelID = modelID as String
        let revision = revision as String
        let allowedFiles = allowedFiles.map { $0 as String }
        let reply = XPCReply(value: reply)
        Task {
            do {
                let requestID = try await installer.install(
                    modelID: modelID,
                    revision: revision,
                    allowedFiles: allowedFiles
                )
                reply.value(requestID as NSUUID, nil)
            } catch {
                reply.value(nil, Self.publicError(error))
            }
        }
    }

    public func resumeModel(
        _ modelID: NSString,
        revision: NSString,
        allowedFiles: [NSString],
        withReply reply: @escaping (NSUUID?, NSError?) -> Void
    ) {
        let modelID = modelID as String
        let revision = revision as String
        let allowedFiles = allowedFiles.map { $0 as String }
        let reply = XPCReply(value: reply)
        Task {
            do {
                let requestID = try await installer.resume(
                    modelID: modelID,
                    revision: revision,
                    allowedFiles: allowedFiles
                )
                reply.value(requestID as NSUUID, nil)
            } catch {
                reply.value(nil, Self.publicError(error))
            }
        }
    }

    public func cancelInstall(
        _ requestID: NSUUID,
        withReply reply: @escaping (NSError?) -> Void
    ) {
        let requestID = requestID as UUID
        let reply = XPCReply(value: reply)
        Task {
            do {
                try await installer.cancel(requestID: requestID)
                reply.value(nil)
            } catch {
                reply.value(Self.publicError(error))
            }
        }
    }

    public func installationStatus(
        _ requestID: NSUUID,
        withReply reply: @escaping (NSData?, NSError?) -> Void
    ) {
        let requestID = requestID as UUID
        let reply = XPCReply(value: reply)
        Task {
            do {
                let status = try await installer.status(requestID: requestID)
                reply.value(try status.encoded(), nil)
            } catch {
                reply.value(nil, Self.publicError(error))
            }
        }
    }

    public func deleteModel(
        _ modelID: NSString,
        revision: NSString,
        withReply reply: @escaping (NSError?) -> Void
    ) {
        let modelID = modelID as String
        let revision = revision as String
        let reply = XPCReply(value: reply)
        Task {
            do {
                try await installer.delete(
                    modelID: modelID,
                    revision: revision
                )
                reply.value(nil)
            } catch {
                reply.value(Self.publicError(error))
            }
        }
    }

    private static func publicError(_ error: Error) -> NSError {
        NSError(
            domain: "com.reserve.OST.ModelDownloader",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "모델 작업을 완료하지 못했습니다."]
        )
    }
}
