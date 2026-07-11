@preconcurrency import AVFoundation
import Foundation
import Synchronization

public enum PCMConverterError: Error {
    case formatUnavailable
    case allocationFailed
    case conversionFailed(Error?)
}

public final class PCMConverter: @unchecked Sendable {
    public static let outputSampleRate: Double = 16_000

    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    public init(inputStreamDescription: AudioStreamBasicDescription) throws {
        var description = inputStreamDescription
        guard let source = AVAudioFormat(streamDescription: &description),
              let destination = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.outputSampleRate,
                channels: 1,
                interleaved: false
              ) else {
            throw PCMConverterError.formatUnavailable
        }
        inputFormat = source
        outputFormat = destination
        converter = source == destination ? nil : AVAudioConverter(from: source, to: destination)
        if source != destination, converter == nil {
            throw PCMConverterError.formatUnavailable
        }
    }

    public func convert(_ samples: [Float]) throws -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard let input = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw PCMConverterError.allocationFailed
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        guard let inputChannel = input.floatChannelData?[0] else {
            throw PCMConverterError.formatUnavailable
        }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                inputChannel.update(from: base, count: source.count)
            }
        }

        guard let converter else { return samples }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(samples.count) * ratio) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw PCMConverterError.allocationFailed
        }
        let supplied = Atomic(false)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied.exchange(true, ordering: .acquiringAndReleasing) {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, let channel = output.floatChannelData?[0] else {
            throw PCMConverterError.conversionFailed(conversionError)
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
