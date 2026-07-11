import Foundation
import NaturalLanguage

public struct EndpointDetector: Sendable {
    public enum Event: Sendable, Equatable {
        case idle
        case speechStarted
        case speechContinued
        case endpoint
    }

    private let amplitudeThreshold: Float
    private let requiredSilentSamples: Int
    private let maximumUtteranceSamples: Int
    private var active = false
    private var utteranceSamples = 0
    private var silentSamples = 0

    public init(
        sampleRate: Double = 16_000,
        amplitudeThreshold: Float = 0.005,
        silenceDuration: Double = 0.8,
        maximumUtteranceDuration: Double = 15
    ) {
        precondition(sampleRate > 0)
        precondition(amplitudeThreshold >= 0)
        precondition(silenceDuration > 0)
        precondition(maximumUtteranceDuration > 0)
        self.amplitudeThreshold = amplitudeThreshold
        requiredSilentSamples = max(1, Int((sampleRate * silenceDuration).rounded()))
        maximumUtteranceSamples = max(1, Int((sampleRate * maximumUtteranceDuration).rounded()))
    }

    public mutating func observe(_ samples: [Float]) -> Event {
        guard !samples.isEmpty else { return active ? .speechContinued : .idle }
        let meanSquare = samples.reduce(Float.zero) { partial, sample in
            partial + sample * sample
        } / Float(samples.count)
        let isSpeech = sqrt(meanSquare) >= amplitudeThreshold

        if !active {
            guard isSpeech else { return .idle }
            active = true
            utteranceSamples = samples.count
            silentSamples = 0
            if utteranceSamples >= maximumUtteranceSamples {
                reset()
                return .endpoint
            }
            return .speechStarted
        }

        utteranceSamples += samples.count
        silentSamples = isSpeech ? 0 : silentSamples + samples.count
        if silentSamples >= requiredSilentSamples || utteranceSamples >= maximumUtteranceSamples {
            reset()
            return .endpoint
        }
        return .speechContinued
    }

    public mutating func reset() {
        active = false
        utteranceSamples = 0
        silentSamples = 0
    }
}

public struct ProgressiveSentenceSegmenter: Sendable {
    private struct State: Sendable {
        var committedPrefix = ""
        var pendingID = UUID()
        var latestFullText = ""
        var latestRemainder = ""
        var nextStartTime: Duration
        var template: TranscriptSegment
    }

    private var states: [UUID: State] = [:]
    private var activeRawID: UUID?

    public init() {}

    public mutating func observe(_ raw: TranscriptSegment) -> [TranscriptSegment] {
        var output: [TranscriptSegment] = []
        if let activeRawID, activeRawID != raw.id {
            if let previous = finalize(rawID: activeRawID, at: raw.startTime) {
                output.append(previous)
            }
            states[activeRawID] = nil
        }
        activeRawID = raw.id

        var state = states[raw.id] ?? State(
            nextStartTime: raw.startTime,
            template: raw
        )
        state.template = raw
        let fullText = raw.sourceText
        let uncommitted: String
        if fullText.hasPrefix(state.committedPrefix) {
            uncommitted = String(fullText.dropFirst(state.committedPrefix.count))
        } else {
            let committedCount = min(state.committedPrefix.count, fullText.count)
            let boundary = fullText.index(fullText.startIndex, offsetBy: committedCount)
            state.committedPrefix = String(fullText[..<boundary])
            uncommitted = String(fullText[boundary...])
        }

        let split = stableSentenceSplit(uncommitted, includeTrailing: raw.isFinal)
        var currentID = state.pendingID
        for sentence in split.sentences where !sentence.isEmpty {
            output.append(makeSegment(
                from: raw,
                id: currentID,
                startTime: state.nextStartTime,
                text: sentence,
                isFinal: true
            ))
            currentID = UUID()
            state.nextStartTime = raw.endTime ?? state.nextStartTime
        }

        state.pendingID = currentID
        state.committedPrefix += split.consumedPrefix
        state.latestFullText = fullText
        state.latestRemainder = split.remainder

        if raw.isFinal {
            if !split.remainder.isEmpty {
                output.append(makeSegment(
                    from: raw,
                    id: currentID,
                    startTime: state.nextStartTime,
                    text: split.remainder,
                    isFinal: true
                ))
            }
            states[raw.id] = nil
            if activeRawID == raw.id { activeRawID = nil }
        } else {
            states[raw.id] = state
            if !split.remainder.isEmpty {
                output.append(makeSegment(
                    from: raw,
                    id: currentID,
                    startTime: state.nextStartTime,
                    text: split.remainder,
                    isFinal: false
                ))
            }
        }
        return output
    }

    public mutating func finalize(at endTime: Duration) -> TranscriptSegment? {
        guard let activeRawID else { return nil }
        return finalize(rawID: activeRawID, at: endTime)
    }

    public mutating func reset() {
        states.removeAll(keepingCapacity: false)
        activeRawID = nil
    }

    private mutating func finalize(rawID: UUID, at endTime: Duration) -> TranscriptSegment? {
        guard var state = states[rawID], !state.latestRemainder.isEmpty else { return nil }
        var segment = makeSegment(
            from: state.template,
            id: state.pendingID,
            startTime: state.nextStartTime,
            text: state.latestRemainder,
            isFinal: true
        )
        segment.endTime = endTime
        state.committedPrefix = state.latestFullText
        state.pendingID = UUID()
        state.latestRemainder = ""
        state.nextStartTime = endTime
        states[rawID] = state
        return segment
    }

    private func makeSegment(
        from raw: TranscriptSegment,
        id: UUID,
        startTime: Duration,
        text: String,
        isFinal: Bool
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            startTime: startTime,
            endTime: raw.endTime,
            language: raw.language,
            sourceText: text.trimmingCharacters(in: .whitespacesAndNewlines),
            isFinal: isFinal
        )
    }

    private func stableSentenceSplit(
        _ text: String,
        includeTrailing: Bool
    ) -> (sentences: [String], consumedPrefix: String, remainder: String) {
        guard !text.isEmpty else { return ([], "", "") }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            ranges.append(range)
            return true
        }
        guard !ranges.isEmpty else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return includeTrailing ? ([trimmed], text, "") : ([], "", trimmed)
        }

        let stableCount = includeTrailing ? ranges.count : max(0, ranges.count - 1)
        let stableRanges = ranges.prefix(stableCount)
        let sentences = stableRanges.map { range in
            String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard let lastStable = stableRanges.last else {
            return ([], "", text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let consumedPrefix = String(text[..<lastStable.upperBound])
        let remainder = String(text[lastStable.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (sentences, consumedPrefix, remainder)
    }
}
