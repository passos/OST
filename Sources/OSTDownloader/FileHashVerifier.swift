import CryptoKit
import Foundation
import OSTCore

public enum FileVerificationError: Error, Sendable {
    case sizeMismatch(expected: Int64, actual: Int64)
    case hashMismatch
}

public enum FileHashVerifier {
    public static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(_ fileURL: URL, descriptor: ModelFileDescriptor) throws {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        let actualSize = Int64(values.fileSize ?? -1)
        guard actualSize == descriptor.bytes else {
            throw FileVerificationError.sizeMismatch(expected: descriptor.bytes, actual: actualSize)
        }
        guard try sha256(of: fileURL) == descriptor.sha256 else {
            throw FileVerificationError.hashMismatch
        }
    }
}
