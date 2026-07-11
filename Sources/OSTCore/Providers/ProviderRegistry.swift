import Foundation

public enum ProviderRegistryError: Error, Sendable, Equatable {
    case transcriptionProviderMissing(ProviderID)
    case translationProviderMissing(ProviderID)
    case automaticDetectionUnsupported(ProviderID)
    case languageUnsupported(ProviderID, SupportedLanguage)
}

public actor ProviderRegistry {
    private var transcriptionProviders: [ProviderID: any TranscriptionProvider] = [:]
    private var translationProviders: [ProviderID: any TranslationProvider] = [:]

    public init() {}

    public func register(_ provider: any TranscriptionProvider) async {
        transcriptionProviders[await provider.id] = provider
    }

    public func register(_ provider: any TranslationProvider) async {
        translationProviders[await provider.id] = provider
    }

    public func transcriptionProvider(
        id: ProviderID,
        configuration: TranscriptionConfiguration
    ) async throws -> any TranscriptionProvider {
        guard let provider = transcriptionProviders[id] else {
            throw ProviderRegistryError.transcriptionProviderMissing(id)
        }
        let capabilities = await provider.capabilities
        switch configuration.sourceMode {
        case .automatic where !capabilities.supportsAutomaticLanguageDetection:
            throw ProviderRegistryError.automaticDetectionUnsupported(id)
        case .fixed(let language) where !capabilities.supportedLanguages.contains(language):
            throw ProviderRegistryError.languageUnsupported(id, language)
        default:
            return provider
        }
    }

    public func translationProvider(
        id: ProviderID,
        source: SupportedLanguage,
        target: SupportedLanguage
    ) async throws -> any TranslationProvider {
        guard let provider = translationProviders[id] else {
            throw ProviderRegistryError.translationProviderMissing(id)
        }
        let languages = await provider.capabilities.supportedLanguages
        guard languages.contains(source), languages.contains(target) else {
            throw ProviderRegistryError.languageUnsupported(id, languages.contains(source) ? target : source)
        }
        return provider
    }
}
