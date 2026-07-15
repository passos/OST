import CoreMedia
import Foundation
import OSTCore
@testable import OSTPlatform
import Testing

@Test func appleSpeechSupportsOnlyTheFourProductLanguages() {
    #expect(AppleSpeechProvider.supportedLanguages == [
        .english,
        .chineseSimplified,
        .chineseTraditional,
        .japanese,
        .korean,
    ])
}

@Test func appleSpeechAnalyzerTimePreservesTheCapturedAudioTimeline() {
    let time = AppleSpeechProvider.analyzerTime(for: .seconds(12) + .milliseconds(345))

    #expect(abs(CMTimeGetSeconds(time) - 12.345) < 0.000_001)
}

@Test func appleSpeechStartTimeCorrectionKeepsTheActiveResultIdentity() {
    var tracker = AppleSpeechResultIdentityTracker()
    let provisionalID = tracker.segmentID(forStartMilliseconds: 1_000, final: false)
    let finalID = tracker.segmentID(forStartMilliseconds: 1_180, final: true)

    #expect(finalID == provisionalID)
}

@Test func appleSpeechFinalResultDoesNotRepeatAnEndpointCommittedSentence() {
    var tracker = AppleSpeechResultIdentityTracker()
    var segmenter = ProgressiveSentenceSegmenter()
    let text = "To do a single patch well requires many small decisions."
    let provisionalID = tracker.segmentID(forStartMilliseconds: 1_000, final: false)

    _ = segmenter.observe(TranscriptSegment(
        id: provisionalID,
        startTime: .seconds(1),
        endTime: .seconds(3),
        language: .english,
        sourceText: text,
        isFinal: false
    ))
    let endpoint = segmenter.finalize(at: .seconds(3))
    let correctedFinalID = tracker.segmentID(forStartMilliseconds: 1_180, final: true)
    let finalOutput = segmenter.observe(TranscriptSegment(
        id: correctedFinalID,
        startTime: .milliseconds(1_180),
        endTime: .seconds(3),
        language: .english,
        sourceText: text,
        isFinal: true
    ))

    #expect(endpoint?.sourceText == text)
    #expect(correctedFinalID == provisionalID)
    #expect(finalOutput.isEmpty)
}

@Test func appleSpeechResultAfterFinalizationGetsANewIdentity() {
    var tracker = AppleSpeechResultIdentityTracker()
    let first = tracker.segmentID(forStartMilliseconds: 1_000, final: false)
    let final = tracker.segmentID(forStartMilliseconds: 1_150, final: true)
    let intentionalRepeat = tracker.segmentID(forStartMilliseconds: 1_150, final: false)

    #expect(final == first)
    #expect(intentionalRepeat != first)
}

@Test func longCumulativeAppleSpeechStreamDoesNotDuplicateEndpointCommittedSentences() async {
    var tracker = AppleSpeechResultIdentityTracker()
    var segmenter = ProgressiveSentenceSegmenter()
    let store = SegmentStore()
    let rawID = tracker.segmentID(forStartMilliseconds: 1_000, final: false)
    var cumulativeText = ""
    var expectedSentences: [String] = []

    for index in 0..<100 {
        let usesEndpoint = index.isMultiple(of: 4) || index == 99
        let sentence = usesEndpoint
            ? "Endpoint sentence \(index)"
            : "Punctuated sentence \(index)."
        cumulativeText += (cumulativeText.isEmpty ? "" : " ") + sentence
        expectedSentences.append(sentence)
        let endTime = Duration.seconds(index + 2)
        let outputs = segmenter.observe(TranscriptSegment(
            id: rawID,
            startTime: .seconds(1),
            endTime: endTime,
            language: .english,
            sourceText: cumulativeText,
            isFinal: false
        ))
        for output in outputs {
            _ = await store.merge(.segment(output), limit: 200)
        }
        if usesEndpoint {
            let endpoint = segmenter.finalize(at: endTime)
            #expect(endpoint != nil)
            if let endpoint {
                _ = await store.merge(.segment(endpoint), limit: 200)
            }
        }
    }

    let correctedFinalID = tracker.segmentID(forStartMilliseconds: 1_180, final: true)
    let lateFinalOutputs = segmenter.observe(TranscriptSegment(
        id: correctedFinalID,
        startTime: .milliseconds(1_180),
        endTime: .seconds(102),
        language: .english,
        sourceText: cumulativeText,
        isFinal: true
    ))
    for output in lateFinalOutputs {
        _ = await store.merge(.segment(output), limit: 200)
    }

    let visible = await store.visibleSegments(limit: 200)
    #expect(correctedFinalID == rawID)
    #expect(lateFinalOutputs.isEmpty)
    #expect(visible.count == expectedSentences.count)
    #expect(visible.map(\.sourceText) == expectedSentences)
    #expect(Set(visible.map(\.id)).count == expectedSentences.count)
    #expect(visible.allSatisfy { $0.isFinal })
}
