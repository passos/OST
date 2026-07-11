@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import OSTCore

public enum CoreAudioTapError: Error, LocalizedError, Sendable {
    case permissionDenied
    case processObjectUnavailable
    case outputDeviceUnavailable
    case unsupportedTapFormat
    case reconfigurationFailed
    case osStatus(operation: String, status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: "시스템 오디오 캡처 권한이 없습니다."
        case .processObjectUnavailable: "OST 프로세스 오디오를 제외할 수 없습니다."
        case .outputDeviceUnavailable: "기본 출력 장치를 찾을 수 없습니다."
        case .unsupportedTapFormat: "Core Audio tap 형식이 Float32 mono가 아닙니다."
        case .reconfigurationFailed: "Core Audio 캡처를 재구성하지 못했습니다."
        case .osStatus(let operation, let status): "\(operation) 실패 (OSStatus \(status))"
        }
    }
}

public enum CoreAudioCaptureEvent: Sendable {
    case running
    case reconfiguring
    case failed(CoreAudioTapError)
    case stopped
}

public actor CoreAudioTapCapture {
    private final class Resources: @unchecked Sendable {
        let tapID: AudioObjectID
        let aggregateDeviceID: AudioObjectID
        let ioProcID: AudioDeviceIOProcID
        let outputDeviceID: AudioObjectID
        let ringBuffer: AudioSampleRingBuffer
        let converter: PCMConverter
        let defaultDeviceListener: AudioObjectPropertyListenerBlock
        let sampleRateListener: AudioObjectPropertyListenerBlock

        init(
            tapID: AudioObjectID,
            aggregateDeviceID: AudioObjectID,
            ioProcID: AudioDeviceIOProcID,
            outputDeviceID: AudioObjectID,
            ringBuffer: AudioSampleRingBuffer,
            converter: PCMConverter,
            defaultDeviceListener: @escaping AudioObjectPropertyListenerBlock,
            sampleRateListener: @escaping AudioObjectPropertyListenerBlock
        ) {
            self.tapID = tapID
            self.aggregateDeviceID = aggregateDeviceID
            self.ioProcID = ioProcID
            self.outputDeviceID = outputDeviceID
            self.ringBuffer = ringBuffer
            self.converter = converter
            self.defaultDeviceListener = defaultDeviceListener
            self.sampleRateListener = sampleRateListener
        }
    }

    private let hardwareListenerQueue = DispatchQueue(label: "com.reserve.OST.audio.hardware-listeners")
    private var resources: Resources?
    private var processingTask: Task<Void, Never>?
    private var reconfigurationTask: Task<Void, Never>?
    private var continuation: AsyncStream<PCMChunk>.Continuation?
    private var audioStream: AsyncStream<PCMChunk>?
    private var emittedSamples: Int64 = 0
    public nonisolated let events: AsyncStream<CoreAudioCaptureEvent>
    private let eventContinuation: AsyncStream<CoreAudioCaptureEvent>.Continuation

    public init() {
        let pair = AsyncStream<CoreAudioCaptureEvent>.makeStream(bufferingPolicy: .bufferingNewest(4))
        events = pair.stream
        eventContinuation = pair.continuation
    }

    public func start() throws -> AsyncStream<PCMChunk> {
        if let audioStream, resources != nil { return audioStream }

        let stream: AsyncStream<PCMChunk>
        if let existing = audioStream {
            stream = existing
        } else {
            let pair = AsyncStream<PCMChunk>.makeStream(bufferingPolicy: .bufferingNewest(8))
            stream = pair.stream
            audioStream = pair.stream
            continuation = pair.continuation
        }
        try startResources()
        return stream
    }

    public func stop() {
        reconfigurationTask?.cancel()
        reconfigurationTask = nil
        stopResources()
        continuation?.finish()
        continuation = nil
        audioStream = nil
        emittedSamples = 0
        eventContinuation.yield(.stopped)
    }

    public func suspendForSleep() {
        reconfigurationTask?.cancel()
        reconfigurationTask = nil
        stopResources()
    }

    public func resumeAfterWake() throws {
        guard audioStream != nil, resources == nil else { return }
        try startResources()
    }

    public func restart() throws {
        guard audioStream != nil else { return }
        stopResources()
        try startResources()
    }

    private func startResources() throws {
        guard resources == nil else { return }

        let processObjectID = try Self.currentProcessObjectID()
        let outputDeviceID = try Self.audioObjectIDProperty(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice
        )
        guard outputDeviceID != kAudioObjectUnknown else {
            throw CoreAudioTapError.outputDeviceUnavailable
        }

        let tapDescription = CATapDescription(
            monoGlobalTapButExcludeProcesses: [processObjectID]
        )
        tapDescription.name = "OST System Audio"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = CATapMuteBehavior.unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try Self.check(
            AudioHardwareCreateProcessTap(tapDescription, &tapID),
            operation: "AudioHardwareCreateProcessTap"
        )

        var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        var ioProcID: AudioDeviceIOProcID?
        var listenersInstalled = false
        var defaultDeviceListener: AudioObjectPropertyListenerBlock?
        var sampleRateListener: AudioObjectPropertyListenerBlock?

        do {
            let tapFormat = try Self.streamDescriptionProperty(
                objectID: tapID,
                selector: kAudioTapPropertyFormat
            )
            guard tapFormat.mFormatID == kAudioFormatLinearPCM,
                  tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  tapFormat.mChannelsPerFrame == 1,
                  tapFormat.mBitsPerChannel == 32 else {
                throw CoreAudioTapError.unsupportedTapFormat
            }

            let ring = AudioSampleRingBuffer(capacity: max(Int(tapFormat.mSampleRate * 10), 160_000))
            let converter = try PCMConverter(inputStreamDescription: tapFormat)
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "OST Capture Device",
                kAudioAggregateDeviceUIDKey: "com.reserve.OST.capture.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]
            try Self.check(
                AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID),
                operation: "AudioHardwareCreateAggregateDevice"
            )

            try Self.check(
                AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, nil) { _, inputData, _, _, _ in
                    let buffers = UnsafeMutableAudioBufferListPointer(
                        UnsafeMutablePointer(mutating: inputData)
                    )
                    guard let buffer = buffers.first,
                          let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
                    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    ring.write(data, count: count)
                },
                operation: "AudioDeviceCreateIOProcIDWithBlock"
            )
            guard let createdIOProcID = ioProcID else {
                throw CoreAudioTapError.osStatus(operation: "IOProc creation", status: -1)
            }

            let deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { await self?.scheduleReconfiguration() }
            }
            let rateListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { await self?.scheduleReconfiguration() }
            }
            var defaultAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var rateAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            try Self.check(
                AudioObjectAddPropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject),
                    &defaultAddress,
                    hardwareListenerQueue,
                    deviceListener
                ),
                operation: "default output listener"
            )
            try Self.check(
                AudioObjectAddPropertyListenerBlock(
                    outputDeviceID,
                    &rateAddress,
                    hardwareListenerQueue,
                    rateListener
                ),
                operation: "sample rate listener"
            )
            listenersInstalled = true
            defaultDeviceListener = deviceListener
            sampleRateListener = rateListener

            try Self.check(
                AudioDeviceStart(aggregateDeviceID, createdIOProcID),
                operation: "AudioDeviceStart"
            )

            let built = Resources(
                tapID: tapID,
                aggregateDeviceID: aggregateDeviceID,
                ioProcID: createdIOProcID,
                outputDeviceID: outputDeviceID,
                ringBuffer: ring,
                converter: converter,
                defaultDeviceListener: deviceListener,
                sampleRateListener: rateListener
            )
            resources = built
            startProcessing(resources: built)
            eventContinuation.yield(.running)
        } catch {
            if listenersInstalled,
               let defaultDeviceListener,
               let sampleRateListener {
                Self.removeListeners(
                    outputDeviceID: outputDeviceID,
                    defaultDeviceListener: defaultDeviceListener,
                    sampleRateListener: sampleRateListener,
                    queue: hardwareListenerQueue
                )
            }
            if let ioProcID, aggregateDeviceID != kAudioObjectUnknown {
                _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
            if aggregateDeviceID != kAudioObjectUnknown {
                _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            }
            if tapID != kAudioObjectUnknown {
                _ = AudioHardwareDestroyProcessTap(tapID)
            }
            throw error
        }
    }

    private func startProcessing(resources: Resources) {
        processingTask?.cancel()
        let continuation = continuation
        let startSample = emittedSamples
        processingTask = Task.detached(priority: .userInitiated) { [weak self] in
            var processed = startSample
            while !Task.isCancelled {
                let source = resources.ringBuffer.read(maxCount: 4096)
                if source.isEmpty {
                    try? await Task.sleep(for: .milliseconds(10))
                    continue
                }
                do {
                    let converted = try resources.converter.convert(source)
                    guard !converted.isEmpty else { continue }
                    let startTime = Duration.seconds(Double(processed) / PCMConverter.outputSampleRate)
                    continuation?.yield(PCMChunk(samples: converted, startTime: startTime))
                    processed += Int64(converted.count)
                    await self?.setEmittedSamples(processed)
                } catch {
                    await self?.scheduleReconfiguration()
                    return
                }
            }
        }
    }

    private func setEmittedSamples(_ value: Int64) {
        emittedSamples = value
    }

    private func scheduleReconfiguration() {
        guard resources != nil else { return }
        eventContinuation.yield(.reconfiguring)
        reconfigurationTask?.cancel()
        reconfigurationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.performReconfiguration()
        }
    }

    private func performReconfiguration() {
        stopResources()
        do {
            try startResources()
        } catch {
            eventContinuation.yield(.failed(
                error as? CoreAudioTapError ?? .reconfigurationFailed
            ))
            continuation?.finish()
            continuation = nil
            audioStream = nil
        }
    }

    private func stopResources() {
        processingTask?.cancel()
        processingTask = nil
        guard let resources else { return }

        Self.removeListeners(
            outputDeviceID: resources.outputDeviceID,
            defaultDeviceListener: resources.defaultDeviceListener,
            sampleRateListener: resources.sampleRateListener,
            queue: hardwareListenerQueue
        )
        _ = AudioDeviceStop(resources.aggregateDeviceID, resources.ioProcID)
        _ = AudioDeviceDestroyIOProcID(resources.aggregateDeviceID, resources.ioProcID)
        _ = AudioHardwareDestroyAggregateDevice(resources.aggregateDeviceID)
        _ = AudioHardwareDestroyProcessTap(resources.tapID)
        self.resources = nil
    }

    private static func removeListeners(
        outputDeviceID: AudioObjectID,
        defaultDeviceListener: @escaping AudioObjectPropertyListenerBlock,
        sampleRateListener: @escaping AudioObjectPropertyListenerBlock,
        queue: DispatchQueue
    ) {
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            queue,
            defaultDeviceListener
        )
        _ = AudioObjectRemovePropertyListenerBlock(
            outputDeviceID,
            &rateAddress,
            queue,
            sampleRateListener
        )
    }

    private static func currentProcessObjectID() throws -> AudioObjectID {
        var pid = getpid()
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                &pid,
                &size,
                &objectID
            ),
            operation: "translate process ID"
        )
        guard objectID != kAudioObjectUnknown else {
            throw CoreAudioTapError.processObjectUnavailable
        }
        return objectID
    }

    private static func audioObjectIDProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> AudioObjectID {
        var value = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value),
            operation: "read Core Audio property"
        )
        return value
    }

    private static func streamDescriptionProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> AudioStreamBasicDescription {
        var value = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value),
            operation: "read Core Audio stream description"
        )
        return value
    }

    private static func check(_ status: OSStatus, operation: String) throws {
        guard status != noErr else { return }
        if status == kAudioDevicePermissionsError {
            throw CoreAudioTapError.permissionDenied
        }
        throw CoreAudioTapError.osStatus(operation: operation, status: status)
    }
}
