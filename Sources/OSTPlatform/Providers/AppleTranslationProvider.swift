import Foundation
import OSTCore
import Translation

public enum AppleTranslationProviderError: Error, Sendable, Equatable {
    case unsupportedPair(SupportedLanguage, SupportedLanguage)
    case languagePackNotInstalled(SupportedLanguage, SupportedLanguage)
    case notPrepared
}

private final class TranslationSessionBox: @unchecked Sendable {
    let value: TranslationSession

    init(_ value: TranslationSession) {
        self.value = value
    }

    func translate(_ text: String) async throws -> String {
        try await value.translate(text).targetText
    }

    func cancel() {
        value.cancel()
    }
}

public actor AppleTranslationProvider: TranslationProvider {
    public nonisolated let id: ProviderID = .appleTranslation
    public nonisolated let capabilities = TranslationCapabilities(
        supportedLanguages: Set(SupportedLanguage.allCases),
        isExperimental: false
    )

    private var source: SupportedLanguage?
    private var target: SupportedLanguage?
    private var session: TranslationSessionBox?

    public init() {}

    public func prepare(source: SupportedLanguage, target: SupportedLanguage) async throws {
        if source == target {
            self.source = source
            self.target = target
            session = nil
            return
        }

        let availability: LanguageAvailability
        if #available(macOS 26.4, *) {
            availability = LanguageAvailability(preferredStrategy: .lowLatency)
        } else {
            availability = LanguageAvailability()
        }
        switch await availability.status(from: source.locale.language, to: target.locale.language) {
        case .unsupported:
            throw AppleTranslationProviderError.unsupportedPair(source, target)
        case .supported:
            throw AppleTranslationProviderError.languagePackNotInstalled(source, target)
        case .installed:
            self.source = source
            self.target = target
            if #available(macOS 26.4, *) {
                session = TranslationSessionBox(TranslationSession(
                    installedSource: source.locale.language,
                    target: target.locale.language,
                    preferredStrategy: .lowLatency
                ))
            } else {
                session = TranslationSessionBox(TranslationSession(
                    installedSource: source.locale.language,
                    target: target.locale.language
                ))
            }
        @unknown default:
            throw AppleTranslationProviderError.unsupportedPair(source, target)
        }
    }

    public func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        try Task.checkCancellation()
        if request.sourceLanguage == request.targetLanguage {
            return TranslationResult(
                segmentID: request.segmentID,
                translatedText: request.sourceText,
                provider: id
            )
        }
        guard source == request.sourceLanguage,
              target == request.targetLanguage,
              let session else {
            throw AppleTranslationProviderError.notPrepared
        }
        let translatedText = try await session.translate(request.sourceText)
        try Task.checkCancellation()
        return TranslationResult(
            segmentID: request.segmentID,
            translatedText: translatedText,
            provider: id
        )
    }

    public func cancelAll() {
        session?.cancel()
    }
}
