import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import OSTCore
import Tokenizers

public enum Qwen3TranslationAdapterError: Error, Sendable {
    case modelNotLoaded
    case pairNotPrepared
    case emptyOutput
    case thinkingOutputRejected
}

public actor Qwen3TranslationAdapter: TranslationProvider {
    public nonisolated let id: ProviderID = .qwen3Translation
    public nonisolated let capabilities = TranslationCapabilities(
        supportedLanguages: Set(SupportedLanguage.allCases),
        isExperimental: true
    )

    private var modelContainer: ModelContainer?
    private var source: SupportedLanguage?
    private var target: SupportedLanguage?
    private var promptTemplate = MLXPromptDefaults.translation
    private var generationEpoch: UInt64 = 0

    public init() {}

    public func loadModel(at directory: URL) async throws {
        modelContainer = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: #huggingFaceTokenizerLoader()
        )
    }

    public func prepare(source: SupportedLanguage, target: SupportedLanguage) throws {
        guard modelContainer != nil || source == target else {
            throw Qwen3TranslationAdapterError.modelNotLoaded
        }
        self.source = source
        self.target = target
    }

    public func setPromptTemplate(_ prompt: String) {
        promptTemplate = prompt
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
              let modelContainer else {
            throw Qwen3TranslationAdapterError.pairNotPrepared
        }

        let epoch = generationEpoch
        let systemPrompt = MLXPromptDefaults.renderTranslation(
            template: promptTemplate,
            source: request.sourceLanguage,
            target: request.targetLanguage
        )
        let input = UserInput(
            chat: [
                .system(systemPrompt),
                .user(request.sourceText),
            ],
            additionalContext: ["enable_thinking": false]
        )
        let prepared = try await modelContainer.prepare(input: input)
        let stream = try await modelContainer.generate(
            input: prepared,
            parameters: GenerateParameters(
                maxTokens: 128,
                temperature: 0,
                topP: 1,
                topK: 0,
                repetitionPenalty: 1.05
            )
        )

        var output = ""
        for await generation in stream {
            try Task.checkCancellation()
            guard epoch == generationEpoch else { throw CancellationError() }
            if case .chunk(let text) = generation {
                output += text
            }
        }
        let sanitized = MLXModelOutputSanitizer.translation(
            output,
            prompt: systemPrompt,
            sourceText: request.sourceText,
            target: request.targetLanguage
        )
        guard !sanitized.isEmpty else { throw Qwen3TranslationAdapterError.emptyOutput }
        guard !sanitized.localizedCaseInsensitiveContains("<think>"),
              !sanitized.localizedCaseInsensitiveContains("</think>") else {
            throw Qwen3TranslationAdapterError.thinkingOutputRejected
        }
        return TranslationResult(
            segmentID: request.segmentID,
            translatedText: sanitized,
            provider: id
        )
    }

    public func cancelAll() {
        generationEpoch &+= 1
    }

    public func unload() {
        generationEpoch &+= 1
        modelContainer = nil
        source = nil
        target = nil
        Memory.clearCache()
    }
}
