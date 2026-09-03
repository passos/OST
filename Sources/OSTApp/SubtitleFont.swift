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
        // Font.custom takes no weight, so without this the semibold translation renders in
        // the same face as the regular transcript the moment a family is chosen.
        return .custom(name, size: size).weight(weight)
    }
}
