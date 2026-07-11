import Foundation

public struct SilenceDetector: Sendable {
    private let amplitudeThreshold: Float
    private let requiredSilentSamples: Int
    private var silentSamples = 0
    private var reported = false

    public init(
        amplitudeThreshold: Float = 0.005,
        requiredSilentSamples: Int = 80_000
    ) {
        precondition(amplitudeThreshold >= 0)
        precondition(requiredSilentSamples > 0)
        self.amplitudeThreshold = amplitudeThreshold
        self.requiredSilentSamples = requiredSilentSamples
    }

    public mutating func observe(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        let meanSquare = samples.reduce(Float.zero) { partial, sample in
            partial + sample * sample
        } / Float(samples.count)
        if sqrt(meanSquare) < amplitudeThreshold {
            silentSamples = min(requiredSilentSamples, silentSamples + samples.count)
            if silentSamples >= requiredSilentSamples, !reported {
                reported = true
                return true
            }
            return false
        }
        reset()
        return false
    }

    public mutating func reset() {
        silentSamples = 0
        reported = false
    }
}
