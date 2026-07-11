@preconcurrency import AVFoundation
import OSTPlatform
import Testing

@Test func ringBufferIsBoundedAndWraps() {
    let ring = AudioSampleRingBuffer(capacity: 5)
    let first: [Float] = [1, 2, 3, 4]
    _ = first.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
    #expect(ring.read(maxCount: 3) == [1, 2, 3])
    let second: [Float] = [5, 6, 7, 8, 9]
    _ = second.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
    #expect(ring.read(maxCount: 8) == [4, 5, 6, 7, 8])
    #expect(ring.droppedSampleCount == 1)
}

@Test func converterProducesMono16kPCM() throws {
    let description = AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: 1,
        mBitsPerChannel: 32,
        mReserved: 0
    )
    let converter = try PCMConverter(inputStreamDescription: description)
    let input = [Float](repeating: 0.25, count: 4_800)
    let outputs = try (0..<10).map { _ in try converter.convert(input) }

    #expect(outputs.allSatisfy { !$0.isEmpty })
    #expect(abs(outputs.reduce(0) { $0 + $1.count } - 16_000) < 512)
}

@Test func converterContinuesAcrossAudioChunks() throws {
    let description = AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: 1,
        mBitsPerChannel: 32,
        mReserved: 0
    )
    let converter = try PCMConverter(inputStreamDescription: description)
    let input = [Float](repeating: 0.25, count: 4_800)

    let first = try converter.convert(input)
    let second = try converter.convert(input)

    #expect(!first.isEmpty)
    #expect(abs(second.count - 1_600) < 128)
}
