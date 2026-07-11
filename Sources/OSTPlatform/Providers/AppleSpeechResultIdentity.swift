import Foundation

struct AppleSpeechResultIdentityTracker {
    private var idsByStartMilliseconds: [Int64: UUID] = [:]
    private let correctionToleranceMilliseconds: Int64

    init(correctionToleranceMilliseconds: Int64 = 250) {
        self.correctionToleranceMilliseconds = max(0, correctionToleranceMilliseconds)
    }

    mutating func segmentID(forStartMilliseconds start: Int64, final: Bool) -> UUID {
        let matchedStart = idsByStartMilliseconds.keys
            .filter { abs($0 - start) <= correctionToleranceMilliseconds }
            .min { abs($0 - start) < abs($1 - start) }
        let id = matchedStart.flatMap { idsByStartMilliseconds[$0] } ?? UUID()

        if final {
            if let matchedStart {
                idsByStartMilliseconds[matchedStart] = nil
            }
        } else {
            if let matchedStart, matchedStart != start {
                idsByStartMilliseconds[matchedStart] = nil
            }
            idsByStartMilliseconds[start] = id
        }
        return id
    }

    mutating func reset() {
        idsByStartMilliseconds.removeAll(keepingCapacity: false)
    }
}
