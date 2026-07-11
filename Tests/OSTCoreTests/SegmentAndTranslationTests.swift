import Foundation
import OSTCore
import Testing

private actor TestTranslationProvider: TranslationProvider {
    nonisolated let id: ProviderID
    nonisolated let capabilities = TranslationCapabilities(
        supportedLanguages: Set(SupportedLanguage.allCases),
        isExperimental: false
    )

    private let prefix: String
    private let shouldFail: Bool
    private let delay: Duration
    private(set) var calls = 0
    private(set) var sourceTexts: [String] = []

    init(
        id: ProviderID,
        prefix: String,
        shouldFail: Bool = false,
        delay: Duration = .zero
    ) {
        self.id = id
        self.prefix = prefix
        self.shouldFail = shouldFail
        self.delay = delay
    }

    func prepare(source: SupportedLanguage, target: SupportedLanguage) {}

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        calls += 1
        sourceTexts.append(request.sourceText)
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        if shouldFail { throw CaptureFailure.modelLoadFailed }
        return TranslationResult(
            segmentID: request.segmentID,
            translatedText: prefix + request.sourceText,
            provider: id
        )
    }

    func cancelAll() {}
}

@Test func volatileSegmentIsReplacedAndFinalIsCommitted() async {
    let store = SegmentStore()
    let id = UUID()
    let first = TranscriptSegment(
        id: id,
        startTime: .zero,
        language: .english,
        sourceText: "hel",
        isFinal: false
    )
    let second = TranscriptSegment(
        id: id,
        startTime: .zero,
        language: .english,
        sourceText: "hello",
        isFinal: false
    )
    let final = TranscriptSegment(
        id: id,
        startTime: .zero,
        endTime: .seconds(1),
        language: .english,
        sourceText: "hello",
        isFinal: true
    )
    _ = await store.merge(.segment(first))
    let volatile = await store.merge(.segment(second))
    #expect(volatile.count == 1)
    #expect(volatile[0].sourceText == "hello")
    #expect(volatile[0].isFinal == false)
    let committed = await store.merge(.segment(final))
    #expect(committed.count == 1)
    #expect(committed[0].isFinal)
}

@Test func newerVolatileSourceKeepsThePreviousPreviewTranslation() async {
    let store = SegmentStore()
    let id = UUID()
    var translated = TranscriptSegment(
        id: id,
        startTime: .zero,
        language: .english,
        sourceText: "The current",
        isFinal: false
    )
    translated.translatedText = "현재"
    let newerSource = TranscriptSegment(
        id: id,
        startTime: .zero,
        language: .english,
        sourceText: "The current sentence",
        isFinal: false
    )

    _ = await store.merge(.segment(translated))
    let visible = await store.merge(.segment(newerSource))
    #expect(visible.last?.sourceText == "The current sentence")
    #expect(visible.last?.translatedText == "현재")
}

@Test func visibleSegmentsKeepTheNewestFinalsAndCurrentVolatile() async {
    let store = SegmentStore()
    for index in 0..<5 {
        _ = await store.merge(.segment(TranscriptSegment(
            startTime: .seconds(index),
            language: .english,
            sourceText: "final-\(index)",
            isFinal: true
        )))
    }
    _ = await store.merge(.segment(TranscriptSegment(
        startTime: .seconds(5),
        language: .english,
        sourceText: "current",
        isFinal: false
    )))

    let visible = await store.visibleSegments(limit: 4)
    #expect(visible.map(\.sourceText) == ["final-2", "final-3", "final-4", "current"])
}

@Test func identicalFinalSegmentsAreDeduplicated() async {
    let store = SegmentStore()
    let first = TranscriptSegment(
        startTime: .zero,
        endTime: .seconds(2),
        language: .english,
        sourceText: "Repeat this sentence.",
        isFinal: true
    )
    var duplicate = TranscriptSegment(
        startTime: .seconds(1),
        language: .english,
        sourceText: "  Repeat   this sentence.  ",
        isFinal: true
    )
    duplicate.translatedText = "반복"

    _ = await store.merge(.segment(first))
    let visible = await store.merge(.segment(duplicate))
    #expect(visible.count == 1)
    #expect(visible[0].id == duplicate.id)
    #expect(visible[0].translatedText == "반복")
}

@Test func intentionalRepeatedSentenceAtALaterTimeIsPreserved() async {
    let store = SegmentStore()
    let first = TranscriptSegment(
        startTime: .zero,
        endTime: .seconds(1),
        language: .english,
        sourceText: "Please confirm.",
        isFinal: true
    )
    let repeatedLater = TranscriptSegment(
        startTime: .seconds(3),
        endTime: .seconds(4),
        language: .english,
        sourceText: "Please confirm.",
        isFinal: true
    )

    _ = await store.merge(.segment(first))
    let visible = await store.merge(.segment(repeatedLater))
    #expect(visible.map(\.id) == [first.id, repeatedLater.id])
}

@Test func volatileCopyOfTheLatestFinalIsSuppressed() async {
    let store = SegmentStore()
    let final = TranscriptSegment(
        startTime: .zero,
        endTime: .seconds(1),
        language: .english,
        sourceText: "Stable sentence.",
        isFinal: true
    )
    let repeatedVolatile = TranscriptSegment(
        startTime: .milliseconds(500),
        language: .english,
        sourceText: "Stable sentence.",
        isFinal: false
    )
    _ = await store.merge(.segment(final))
    let visible = await store.merge(.segment(repeatedVolatile))
    #expect(visible.count == 1)
    #expect(visible[0].id == final.id)
}

@Test func olderVolatileResultCannotReplaceTheCurrentSentence() async {
    let store = SegmentStore()
    let current = TranscriptSegment(
        startTime: .seconds(2),
        language: .english,
        sourceText: "current",
        isFinal: false
    )
    let lateOlder = TranscriptSegment(
        startTime: .seconds(1),
        language: .english,
        sourceText: "old",
        isFinal: false
    )
    _ = await store.merge(.segment(current))
    let visible = await store.merge(.segment(lateOlder))
    #expect(visible.last?.id == current.id)
    #expect(visible.last?.sourceText == "current")
}

@Test func automaticLanguageRequiresTwoMatchingUtterancesToSwitch() async {
    let stabilizer = AutomaticLanguageStabilizer()
    #expect(await stabilizer.observe(.english) == .english)
    #expect(await stabilizer.observe(.japanese) == .english)
    #expect(await stabilizer.observe(.japanese) == .japanese)
}

@Test func sameLanguageSkipsTranslationProvider() async {
    let provider = TestTranslationProvider(id: .appleTranslation, prefix: "translated:")
    let scheduler = TranslationScheduler()
    var iterator = scheduler.updates.makeAsyncIterator()
    let segment = TranscriptSegment(
        startTime: .zero,
        language: .korean,
        sourceText: "안녕",
        isFinal: true
    )
    await scheduler.submit(.segment(segment), target: .korean, primary: provider)
    let update = await iterator.next()
    #expect(update == .translated(
        segmentID: segment.id,
        text: "안녕",
        isFinal: true,
        provider: nil
    ))
    #expect(await provider.calls == 0)
}

@Test func translationFallsBackWithoutStoppingTranscriptFlow() async {
    let primary = TestTranslationProvider(id: .qwen3Translation, prefix: "", shouldFail: true)
    let fallback = TestTranslationProvider(id: .appleTranslation, prefix: "fallback:")
    let scheduler = TranslationScheduler()
    var iterator = scheduler.updates.makeAsyncIterator()
    let segment = TranscriptSegment(
        startTime: .zero,
        language: .english,
        sourceText: "hello",
        isFinal: true
    )
    await scheduler.submit(
        .segment(segment),
        target: .korean,
        primary: primary,
        fallback: fallback
    )
    let update = await iterator.next()
    #expect(update == .translated(
        segmentID: segment.id,
        text: "fallback:hello",
        isFinal: true,
        provider: .appleTranslation
    ))
}

@Test func allTwelveProductTranslationDirectionsFlowThroughProvider() async {
    let provider = TestTranslationProvider(id: .appleTranslation, prefix: "translated:")
    let scheduler = TranslationScheduler()
    var iterator = scheduler.updates.makeAsyncIterator()
    var directionCount = 0

    for source in SupportedLanguage.productPickerCases {
        for target in SupportedLanguage.productPickerCases where source != target {
            directionCount += 1
            let segment = TranscriptSegment(
                startTime: .zero,
                language: source,
                sourceText: "\(source.rawValue)-to-\(target.rawValue)",
                isFinal: true
            )
            await scheduler.submit(.segment(segment), target: target, primary: provider)
            let update = await iterator.next()
            #expect(update == .translated(
                segmentID: segment.id,
                text: "translated:\(segment.sourceText)",
                isFinal: true,
                provider: .appleTranslation
            ))
        }
    }

    #expect(directionCount == 12)
    #expect(await provider.calls == 12)
}

@Test func volatileSourceStartsPreviewTranslationAfterDebounce() async {
    let provider = TestTranslationProvider(
        id: .appleTranslation,
        prefix: "translated:",
        delay: .zero
    )
    let scheduler = TranslationScheduler()
    await scheduler.submit(
        .segment(TranscriptSegment(
            startTime: .zero,
            language: .english,
            sourceText: "still changing",
            isFinal: false
        )),
        target: .korean,
        primary: provider
    )
    try? await Task.sleep(for: .milliseconds(600))
    #expect(await provider.calls == 1)
}

@Test func volatileTranslationDebounceUsesTheLatestSource() async {
    let provider = TestTranslationProvider(id: .appleTranslation, prefix: "translated:")
    let scheduler = TranslationScheduler()
    let id = UUID()
    await scheduler.submit(
        .segment(TranscriptSegment(
            id: id,
            startTime: .zero,
            language: .english,
            sourceText: "older partial",
            isFinal: false
        )),
        target: .korean,
        primary: provider
    )
    try? await Task.sleep(for: .milliseconds(100))
    await scheduler.submit(
        .segment(TranscriptSegment(
            id: id,
            startTime: .zero,
            language: .english,
            sourceText: "newer partial",
            isFinal: false
        )),
        target: .korean,
        primary: provider
    )
    try? await Task.sleep(for: .milliseconds(600))
    #expect(await provider.sourceTexts == ["newer partial"])
}

@Test func correctedFinalTranslationCancelsTheOlderFinalRequest() async {
    let provider = TestTranslationProvider(
        id: .appleTranslation,
        prefix: "translated:",
        delay: .milliseconds(100)
    )
    let scheduler = TranslationScheduler()
    var iterator = scheduler.updates.makeAsyncIterator()
    let id = UUID()
    await scheduler.submit(
        .segment(TranscriptSegment(
            id: id,
            startTime: .zero,
            language: .english,
            sourceText: "old final",
            isFinal: true
        )),
        target: .korean,
        primary: provider
    )
    try? await Task.sleep(for: .milliseconds(10))
    await scheduler.submit(
        .segment(TranscriptSegment(
            id: id,
            startTime: .zero,
            language: .english,
            sourceText: "corrected final",
            isFinal: true
        )),
        target: .korean,
        primary: provider
    )

    let update = await iterator.next()
    #expect(update == .translated(
        segmentID: id,
        text: "translated:corrected final",
        isFinal: true,
        provider: .appleTranslation
    ))
    #expect(await provider.calls == 2)
}
