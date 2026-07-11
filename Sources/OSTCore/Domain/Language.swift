import Foundation

public enum SupportedLanguage: String, Codable, CaseIterable, Sendable, Hashable {
    case english
    case chineseSimplified
    case chineseTraditional
    case japanese
    case korean

    public static let productPickerCases: [SupportedLanguage] = [
        .english,
        .chineseSimplified,
        .japanese,
        .korean,
    ]

    public var isChinese: Bool {
        self == .chineseSimplified || self == .chineseTraditional
    }

    public var productDisplayName: String {
        isChinese ? "중국어" : displayName
    }

    public func applyingChinesePreference(
        _ preference: ChineseScriptPreference
    ) -> SupportedLanguage {
        isChinese ? preference.language : self
    }

    public var localeIdentifier: String {
        switch self {
        case .english: "en"
        case .chineseSimplified: "zh-Hans"
        case .chineseTraditional: "zh-Hant"
        case .japanese: "ja"
        case .korean: "ko"
        }
    }

    public var locale: Locale { Locale(identifier: localeIdentifier) }

    public var modelLanguageName: String {
        switch self {
        case .english: "English"
        case .chineseSimplified, .chineseTraditional: "Chinese"
        case .japanese: "Japanese"
        case .korean: "Korean"
        }
    }

    public var displayName: String {
        switch self {
        case .english: "영어"
        case .chineseSimplified: "중국어(간체)"
        case .chineseTraditional: "중국어(번체)"
        case .japanese: "일본어"
        case .korean: "한국어"
        }
    }
}

public enum ChineseScriptPreference: String, Codable, CaseIterable, Sendable {
    case simplified
    case traditional

    public var language: SupportedLanguage {
        switch self {
        case .simplified: .chineseSimplified
        case .traditional: .chineseTraditional
        }
    }
}

public enum SourceLanguageMode: Codable, Sendable, Equatable, Hashable {
    case fixed(SupportedLanguage)
    case automatic
}
