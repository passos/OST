import Foundation
import OSTCore
import Testing

@Test func endpointDetectorEndsSpeechAfterConfiguredSilence() {
    var detector = EndpointDetector(
        sampleRate: 10,
        amplitudeThreshold: 0.1,
        silenceDuration: 0.5,
        maximumUtteranceDuration: 10
    )

    #expect(detector.observe([0, 0]) == .idle)
    #expect(detector.observe([0.5, 0.5]) == .speechStarted)
    #expect(detector.observe([0, 0, 0]) == .speechContinued)
    #expect(detector.observe([0, 0]) == .endpoint)
    #expect(detector.observe([0, 0]) == .idle)
}

@Test func endpointDetectorCapsAnUnbrokenUtterance() {
    var detector = EndpointDetector(
        sampleRate: 10,
        amplitudeThreshold: 0.1,
        silenceDuration: 1,
        maximumUtteranceDuration: 0.5
    )

    #expect(detector.observe([0.5, 0.5]) == .speechStarted)
    #expect(detector.observe([0.5, 0.5, 0.5]) == .endpoint)
}

@Test func progressiveSentenceSegmenterSeparatesStableSentencePrefix() {
    let rawID = UUID()
    var segmenter = ProgressiveSentenceSegmenter()
    let first = segmenter.observe(TranscriptSegment(
        id: rawID,
        startTime: .zero,
        language: .english,
        sourceText: "Hello wor",
        isFinal: false
    ))
    #expect(first.count == 1)
    #expect(first[0].sourceText == "Hello wor")
    #expect(first[0].isFinal == false)

    let split = segmenter.observe(TranscriptSegment(
        id: rawID,
        startTime: .zero,
        language: .english,
        sourceText: "Hello world. How are",
        isFinal: false
    ))
    #expect(split.count == 2)
    #expect(split[0].id == first[0].id)
    #expect(split[0].sourceText == "Hello world.")
    #expect(split[0].isFinal)
    #expect(split[1].sourceText == "How are")
    #expect(split[1].isFinal == false)
    #expect(split[1].id != split[0].id)
}

@Test func progressiveSentenceSegmenterStartsANewIDAfterEndpoint() {
    let rawID = UUID()
    var segmenter = ProgressiveSentenceSegmenter()
    let first = segmenter.observe(TranscriptSegment(
        id: rawID,
        startTime: .zero,
        language: .english,
        sourceText: "First thought",
        isFinal: false
    ))
    let endpoint = segmenter.finalize(at: .seconds(1))
    #expect(endpoint?.id == first[0].id)
    #expect(endpoint?.sourceText == "First thought")
    #expect(endpoint?.isFinal == true)

    let next = segmenter.observe(TranscriptSegment(
        id: rawID,
        startTime: .zero,
        language: .english,
        sourceText: "First thought Second thought",
        isFinal: false
    ))
    #expect(next.count == 1)
    #expect(next[0].id != endpoint?.id)
    #expect(next[0].sourceText == "Second thought")
    #expect(next[0].isFinal == false)
}

@Test func displaySegmentGrouperKeepsSoftEndpointsOnTheSameLine() {
    let fragments = [
        TranscriptSegment(
            startTime: .zero,
            endTime: .seconds(1),
            language: .english,
            sourceText: "We need",
            translatedText: "우리는",
            isFinal: true
        ),
        TranscriptSegment(
            startTime: .seconds(1),
            endTime: .seconds(2),
            language: .english,
            sourceText: "more time",
            translatedText: "시간이 더 필요합니다",
            isFinal: true
        ),
        TranscriptSegment(
            startTime: .seconds(2),
            endTime: .seconds(2.1),
            language: .english,
            sourceText: ".",
            translatedText: ".",
            isFinal: true
        ),
        TranscriptSegment(
            startTime: .seconds(3),
            language: .english,
            sourceText: "Next topic",
            isFinal: false
        )
    ]

    let grouped = DisplaySegmentGrouper.group(fragments)
    #expect(grouped.count == 2)
    #expect(grouped[0].sourceText == "We need more time.")
    #expect(grouped[0].translatedText == "우리는 시간이 더 필요합니다.")
    #expect(grouped[1].sourceText == "Next topic")
    #expect(grouped[1].isFinal == false)
}
