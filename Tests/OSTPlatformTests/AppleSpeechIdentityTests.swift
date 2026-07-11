import Foundation
import OSTCore
@testable import OSTPlatform
import Testing

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
