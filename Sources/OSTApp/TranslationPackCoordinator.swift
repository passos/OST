import Foundation
import Combine
import OSTCore
import Translation

private final class TranslationPreparationSession: @unchecked Sendable {
    private let session: TranslationSession

    init(_ session: TranslationSession) {
        self.session = session
    }

    func prepare() async throws {
        try await session.prepareTranslation()
    }
}

@MainActor
final class TranslationPackCoordinator: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    @Published var errorText: String?

    private var completion: (@MainActor @Sendable () async -> Void)?
    private var requestedPair: (source: SupportedLanguage, target: SupportedLanguage)?
    var onFailure: (@MainActor @Sendable () -> Void)?

    func request(
        source: SupportedLanguage,
        target: SupportedLanguage,
        completion: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.completion = completion
        errorText = nil
        if configuration != nil,
           requestedPair?.source == source,
           requestedPair?.target == target {
            return
        }
        requestedPair = (source, target)
        if #available(macOS 26.4, *) {
            configuration = TranslationSession.Configuration(
                source: source.locale.language,
                target: target.locale.language,
                preferredStrategy: .lowLatency
            )
        } else {
            configuration = TranslationSession.Configuration(
                source: source.locale.language,
                target: target.locale.language
            )
        }
    }

    func prepare(using session: TranslationSession) async {
        do {
            try await TranslationPreparationSession(session).prepare()
            configuration = nil
            requestedPair = nil
            let callback = completion
            completion = nil
            await callback?()
        } catch {
            errorText = "번역 언어팩을 준비하지 못했습니다."
            configuration = nil
            requestedPair = nil
            completion = nil
            onFailure?()
        }
    }
}
