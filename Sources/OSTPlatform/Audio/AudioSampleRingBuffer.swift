import Darwin
import Foundation
import Synchronization

public final class AudioSampleRingBuffer: @unchecked Sendable {
    public let capacity: Int

    private let storage: UnsafeMutablePointer<Float>
    private let readIndex = Atomic<Int>(0)
    private let writeIndex = Atomic<Int>(0)
    private let droppedSamples = Atomic<Int>(0)

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    @discardableResult
    public func write(_ source: UnsafePointer<Float>, count requestedCount: Int) -> Int {
        guard requestedCount > 0 else { return 0 }
        let read = readIndex.load(ordering: .acquiring)
        let write = writeIndex.load(ordering: .relaxed)
        let writable = max(0, capacity - (write - read))
        let count = min(requestedCount, writable)
        guard count > 0 else {
            _ = droppedSamples.wrappingAdd(requestedCount, ordering: .relaxed)
            return 0
        }

        let offset = write % capacity
        let firstCount = min(count, capacity - offset)
        storage.advanced(by: offset).update(from: source, count: firstCount)
        if count > firstCount {
            storage.update(from: source.advanced(by: firstCount), count: count - firstCount)
        }
        writeIndex.store(write + count, ordering: .releasing)

        if count < requestedCount {
            _ = droppedSamples.wrappingAdd(requestedCount - count, ordering: .relaxed)
        }
        return count
    }

    public func read(maxCount: Int) -> [Float] {
        guard maxCount > 0 else { return [] }
        let write = writeIndex.load(ordering: .acquiring)
        let read = readIndex.load(ordering: .relaxed)
        let count = min(maxCount, max(0, write - read))
        guard count > 0 else { return [] }

        var result = [Float](repeating: 0, count: count)
        result.withUnsafeMutableBufferPointer { destination in
            guard let base = destination.baseAddress else { return }
            let offset = read % capacity
            let firstCount = min(count, capacity - offset)
            base.update(from: storage.advanced(by: offset), count: firstCount)
            if count > firstCount {
                base.advanced(by: firstCount).update(from: storage, count: count - firstCount)
            }
        }
        readIndex.store(read + count, ordering: .releasing)
        return result
    }

    public var availableSampleCount: Int {
        let write = writeIndex.load(ordering: .acquiring)
        let read = readIndex.load(ordering: .acquiring)
        return max(0, write - read)
    }

    public var droppedSampleCount: Int {
        droppedSamples.load(ordering: .relaxed)
    }
}
