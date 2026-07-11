import Foundation

public actor SegmentStore {
    private var finalized: [TranscriptSegment] = []
    private var volatile: TranscriptSegment?

    public init() {}

    @discardableResult
    public func merge(_ event: TranscriptEvent, limit: Int = 3) -> [TranscriptSegment] {
        guard case .segment(let segment) = event else { return visibleSegments(limit: limit) }

        if segment.isFinal {
            if volatile?.id == segment.id {
                volatile = nil
            }
            if let index = finalized.firstIndex(where: { $0.id == segment.id }) {
                finalized[index] = preservingTranslation(from: finalized[index], in: segment)
            } else if let lastIndex = finalized.indices.last,
                      normalized(finalized[lastIndex].sourceText) == normalized(segment.sourceText),
                      overlaps(finalized[lastIndex], segment) {
                finalized[lastIndex] = preservingTranslation(from: finalized[lastIndex], in: segment)
            } else {
                finalized.append(segment)
            }
        } else {
            if let index = finalized.firstIndex(where: { $0.id == segment.id }) {
                var correction = preservingTranslation(from: finalized[index], in: segment)
                correction.isFinal = true
                finalized[index] = correction
                return visibleSegments(limit: limit)
            }
            if let latestFinal = finalized.last,
               normalized(latestFinal.sourceText) == normalized(segment.sourceText),
               overlaps(latestFinal, segment) {
                return visibleSegments(limit: limit)
            }
            if let volatile,
               volatile.id != segment.id,
               volatile.startTime > segment.startTime {
                return visibleSegments(limit: limit)
            }
            if let existing = volatile, existing.id == segment.id {
                volatile = preservingTranslation(from: existing, in: segment)
            } else {
                volatile = segment
            }
        }
        return visibleSegments(limit: limit)
    }

    public func applyTranslation(
        segmentID: UUID,
        text: String,
        limit: Int = 3
    ) -> [TranscriptSegment] {
        if volatile?.id == segmentID {
            volatile?.translatedText = text
        } else if let index = finalized.firstIndex(where: { $0.id == segmentID }) {
            finalized[index].translatedText = text
        }
        return visibleSegments(limit: limit)
    }

    public func visibleSegments(limit: Int = 3) -> [TranscriptSegment] {
        let finalizedTail = finalized.suffix(max(0, limit - (volatile == nil ? 0 : 1)))
        return Array(finalizedTail) + (volatile.map { [$0] } ?? [])
    }

    public func clear() {
        finalized.removeAll(keepingCapacity: false)
        volatile = nil
    }

    private func preservingTranslation(
        from existing: TranscriptSegment,
        in replacement: TranscriptSegment
    ) -> TranscriptSegment {
        guard replacement.translatedText == nil else { return replacement }
        var replacement = replacement
        replacement.translatedText = existing.translatedText
        return replacement
    }

    private func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func overlaps(_ first: TranscriptSegment, _ second: TranscriptSegment) -> Bool {
        let firstEnd = first.endTime ?? first.startTime
        let secondEnd = second.endTime ?? second.startTime
        return first.startTime <= secondEnd && second.startTime <= firstEnd
    }
}

public actor AutomaticLanguageStabilizer {
    private var current: SupportedLanguage?
    private var candidate: SupportedLanguage?
    private var candidateCount = 0

    public init() {}

    public func observe(_ detected: SupportedLanguage) -> SupportedLanguage {
        if current == nil {
            current = detected
            candidate = nil
            candidateCount = 0
            return detected
        }
        if detected == current {
            candidate = nil
            candidateCount = 0
            return current!
        }
        if candidate == detected {
            candidateCount += 1
        } else {
            candidate = detected
            candidateCount = 1
        }
        if candidateCount >= 2 {
            current = detected
            candidate = nil
            candidateCount = 0
        }
        return current!
    }

    public func reset() {
        current = nil
        candidate = nil
        candidateCount = 0
    }
}
