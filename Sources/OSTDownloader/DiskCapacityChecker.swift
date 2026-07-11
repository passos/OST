import Foundation

public protocol DiskCapacityChecking: Sendable {
    func availableCapacity(at directory: URL) throws -> Int64
}

public struct VolumeDiskCapacityChecker: DiskCapacityChecking {
    public init() {}

    public func availableCapacity(at directory: URL) throws -> Int64 {
        let values = try directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        let importantCapacity = values.volumeAvailableCapacityForImportantUsage ?? 0
        let regularCapacity = Int64(values.volumeAvailableCapacity ?? 0)
        let attributes = try? FileManager.default.attributesOfFileSystem(
            forPath: directory.path
        )
        let fileSystemCapacity = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        return max(importantCapacity, max(regularCapacity, fileSystemCapacity))
    }
}
