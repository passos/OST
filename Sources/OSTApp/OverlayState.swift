import Foundation
import Combine
import OSTCore

@MainActor
final class OverlayState: ObservableObject {
    @Published var segments: [TranscriptSegment] = []
    @Published var statusText = "Waiting"
    @Published var detectedLanguage: SupportedLanguage?
    @Published var isListening = false

    func clear() {
        segments.removeAll()
        detectedLanguage = nil
        isListening = false
        statusText = "Waiting"
    }
}
