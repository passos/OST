@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import OSTCore
import Speech
import Synchronization

public enum AppleSpeechProviderError: Error, Sendable {
    case automaticModeUnsupported
    case localeUnsupported(SupportedLanguage)
    case assetUnavailable(SupportedLanguage)
    case incompatibleAudioFormat
    case audioReadFailed
    case notPrepared
}

public actor AppleSpeechProvider: TranscriptionProvider {
    public static let supportedLanguages: Set<SupportedLanguage> = [
        .english,
        .chineseSimplified,
        .chineseTraditional,
        .japanese,
        .korean,
    ]

    public nonisolated let id: ProviderID = .appleSpeech
    public nonisolated let capabilities = TranscriptionCapabilities(
        supportedLanguages: AppleSpeechProvider.supportedLanguages,
        supportsAutomaticLanguageDetection: false,
        supportsVolatileResults: true
    )

    private var language: SupportedLanguage?
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var sourceFormat: AVAudioFormat?
    private var inputConverter: AVAudioConverter?
    private var reservedLocale: Locale?
    private var feedTask: Task<Void, Never>?
    private var analysisStartTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultIdentity = AppleSpeechResultIdentityTracker()
    private var sentenceSegmenter = ProgressiveSentenceSegmenter()
    private var endpointSilenceSeconds = 0.8

    public init() {}

    public static func runtimeSupportedLanguages() async -> Set<SupportedLanguage> {
        guard SpeechTranscriber.isAvailable else { return [] }
        var supported: Set<SupportedLanguage> = []
        for language in supportedLanguages {
            if await SpeechTranscriber.supportedLocale(equivalentTo: language.locale) != nil {
                supported.insert(language)
            }
        }
        return supported
    }

    public func prepare(configuration: TranscriptionConfiguration) async throws {
        guard case .fixed(let requestedLanguage) = configuration.sourceMode else {
            throw AppleSpeechProviderError.automaticModeUnsupported
        }
        guard Self.supportedLanguages.contains(requestedLanguage) else {
            throw AppleSpeechProviderError.localeUnsupported(requestedLanguage)
        }
        guard SpeechTranscriber.isAvailable else {
            throw AppleSpeechProviderError.assetUnavailable(requestedLanguage)
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLanguage.locale) else {
            throw AppleSpeechProviderError.localeUnsupported(requestedLanguage)
        }
        endpointSilenceSeconds = configuration.endpointSilenceSeconds

        if reservedLocale != locale {
            await releaseReservedLocale()
        }
        do {
            if reservedLocale == nil {
                _ = try await AssetInventory.reserve(locale: locale)
                reservedLocale = locale
            }
            let module = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
            switch await AssetInventory.status(forModules: [module]) {
            case .unsupported:
                throw AppleSpeechProviderError.assetUnavailable(requestedLanguage)
            case .supported:
                guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
                    throw AppleSpeechProviderError.assetUnavailable(requestedLanguage)
                }
                try await request.downloadAndInstall()
            case .downloading:
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    try await request.downloadAndInstall()
                }
            case .installed:
                break
            @unknown default:
                throw AppleSpeechProviderError.assetUnavailable(requestedLanguage)
            }
            try await configureAnalyzer(module: module, language: requestedLanguage)
        } catch {
            await releaseReservedLocale()
            if let providerError = error as? AppleSpeechProviderError {
                throw providerError
            }
            throw AppleSpeechProviderError.assetUnavailable(requestedLanguage)
        }
    }

    private func configureAnalyzer(
        module: SpeechTranscriber,
        language requestedLanguage: SupportedLanguage
    ) async throws {
        guard let source = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ),
        let compatible = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module],
            considering: source
        ) else {
            throw AppleSpeechProviderError.incompatibleAudioFormat
        }

        language = requestedLanguage
        transcriber = module
        analyzer = SpeechAnalyzer(modules: [module])
        analyzerFormat = compatible
        sourceFormat = source
        inputConverter = source == compatible ? nil : AVAudioConverter(from: source, to: compatible)
        resultIdentity.reset()
        sentenceSegmenter.reset()
        try await analyzer?.prepareToAnalyze(in: compatible)
    }

    public func transcribe(_ audio: AsyncStream<PCMChunk>) -> AsyncThrowingStream<TranscriptEvent, Error> {
        guard let analyzer, let transcriber, let language else {
            return AsyncThrowingStream { $0.finish(throwing: AppleSpeechProviderError.notPrepared) }
        }

        let inputPair = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(32))
        inputContinuation = inputPair.continuation

        let outputPair = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        let analysisTask = Task {
            do {
                try await analyzer.start(inputSequence: inputPair.stream)
            } catch is CancellationError {
                await analyzer.cancelAndFinishNow()
            } catch {
                outputPair.continuation.finish(throwing: Self.mapAnalysisError(error))
            }
        }
        let feedTask = Task { [weak self] in
            guard let self else { return }
            var endpointDetector = EndpointDetector(
                silenceDuration: await self.configuredEndpointSilenceSeconds()
            )
            for await chunk in audio {
                guard !Task.isCancelled else { break }
                if endpointDetector.observe(chunk.samples) == .endpoint {
                    let duration = Double(chunk.samples.count) / chunk.sampleRate
                    let endTime = chunk.startTime + .seconds(duration)
                    if let segment = await self.finalizeCurrentSegment(at: endTime) {
                        outputPair.continuation.yield(.segment(segment))
                    } else {
                        outputPair.continuation.yield(.silence)
                    }
                }
                do {
                    let input = try await self.analyzerInput(from: chunk)
                    inputPair.continuation.yield(input)
                } catch {
                    outputPair.continuation.finish(throwing: error)
                    break
                }
            }
            inputPair.continuation.finish()
        }
        let resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { break }
                    let key = Int64((CMTimeGetSeconds(result.range.start) * 1_000).rounded())
                    let segmentID = await self?.segmentID(for: key, final: result.isFinal) ?? UUID()
                    let start = Duration.seconds(CMTimeGetSeconds(result.range.start))
                    let end = Duration.seconds(CMTimeGetSeconds(result.range.end))
                    let rawSegment = TranscriptSegment(
                        id: segmentID,
                        startTime: start,
                        endTime: end,
                        language: language,
                        sourceText: String(result.text.characters),
                        isFinal: result.isFinal
                    )
                    let segments = await self?.observe(rawSegment) ?? [rawSegment]
                    for segment in segments {
                        outputPair.continuation.yield(.segment(segment))
                    }
                }
                outputPair.continuation.finish()
            } catch {
                outputPair.continuation.finish(throwing: Self.mapAnalysisError(error))
            }
        }
        self.feedTask = feedTask
        analysisStartTask = analysisTask
        self.resultTask = resultTask
        outputPair.continuation.onTermination = { termination in
            guard case .cancelled = termination else { return }
            analysisTask.cancel()
            feedTask.cancel()
            resultTask.cancel()
        }
        return outputPair.stream
    }

    public func stop() async {
        inputContinuation?.finish()
        inputContinuation = nil
        if let feedTask {
            feedTask.cancel()
            await feedTask.value
            self.feedTask = nil
        }
        if let analysisStartTask {
            await analysisStartTask.value
            self.analysisStartTask = nil
            do {
                try await analyzer?.finalizeAndFinishThroughEndOfInput()
            } catch {
                await analyzer?.cancelAndFinishNow()
            }
        } else {
            await analyzer?.cancelAndFinishNow()
        }
        if let resultTask {
            await resultTask.value
            self.resultTask = nil
        }
        analyzer = nil
        transcriber = nil
        inputConverter = nil
        analyzerFormat = nil
        sourceFormat = nil
        resultIdentity.reset()
        sentenceSegmenter.reset()
        await releaseReservedLocale()
    }

    private func releaseReservedLocale() async {
        guard let reservedLocale else { return }
        _ = await AssetInventory.release(reservedLocale: reservedLocale)
        self.reservedLocale = nil
    }

    private func analyzerInput(from chunk: PCMChunk) throws -> AnalyzerInput {
        guard let sourceFormat, let analyzerFormat else {
            throw AppleSpeechProviderError.notPrepared
        }
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(chunk.samples.count)
        ) else {
            throw AppleSpeechProviderError.incompatibleAudioFormat
        }
        sourceBuffer.frameLength = AVAudioFrameCount(chunk.samples.count)
        guard let channel = sourceBuffer.floatChannelData?[0] else {
            throw AppleSpeechProviderError.incompatibleAudioFormat
        }
        chunk.samples.withUnsafeBufferPointer { samples in
            if let base = samples.baseAddress {
                channel.update(from: base, count: samples.count)
            }
        }

        guard let converter = inputConverter else {
            return AnalyzerInput(buffer: sourceBuffer)
        }
        let ratio = analyzerFormat.sampleRate / sourceFormat.sampleRate
        guard let destination = AVAudioPCMBuffer(
            pcmFormat: analyzerFormat,
            frameCapacity: AVAudioFrameCount(ceil(Double(chunk.samples.count) * ratio) + 64)
        ) else {
            throw AppleSpeechProviderError.incompatibleAudioFormat
        }
        let supplied = Atomic(false)
        var conversionError: NSError?
        let status = converter.convert(to: destination, error: &conversionError) { _, inputStatus in
            if supplied.exchange(true, ordering: .acquiringAndReleasing) {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return sourceBuffer
        }
        guard status != .error else {
            throw conversionError ?? AppleSpeechProviderError.incompatibleAudioFormat
        }
        return AnalyzerInput(buffer: destination)
    }

    static func mapAnalysisError(_ error: Error) -> Error {
        let cocoaError = error as NSError
        if cocoaError.domain == SFSpeechErrorDomain,
           cocoaError.code == SFSpeechError.Code.audioReadFailed.rawValue {
            return AppleSpeechProviderError.audioReadFailed
        }
        return error
    }

    private func segmentID(for key: Int64, final: Bool) -> UUID {
        resultIdentity.segmentID(forStartMilliseconds: key, final: final)
    }

    private func configuredEndpointSilenceSeconds() -> Double {
        endpointSilenceSeconds
    }

    private func observe(_ segment: TranscriptSegment) -> [TranscriptSegment] {
        sentenceSegmenter.observe(segment)
    }

    private func finalizeCurrentSegment(at endTime: Duration) -> TranscriptSegment? {
        sentenceSegmenter.finalize(at: endTime)
    }
}
