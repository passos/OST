import AppKit
import SwiftUI

enum SubtitleFont {
    static func isAvailable(_ family: String) -> Bool {
        NSFontManager.shared.availableFontFamilies.contains(family)
    }

    static func resolve(name: String?, size: CGFloat, weight: Font.Weight) -> Font {
        guard let name, isAvailable(name) else {
            return .system(size: size, weight: weight)
        }
        return .custom(name, size: size)
    }
}
