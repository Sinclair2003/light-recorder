import Foundation

/// Maps the host clock to retained audio time. Pause ranges are removed, route gaps are not.
public struct RecordingTimeline: Sendable {
    public private(set) var pauseStart: Double?
    public private(set) var excludedDuration: Double = 0
    private var pauses: [ClosedRange<Double>] = []
    private var lastTransition: Double = 0
    public init() {}
    public var isPaused: Bool { pauseStart != nil }

    public mutating func pause(at wallTime: Double) {
        guard !isPaused, wallTime.isFinite else { return }
        let time = max(0, lastTransition, wallTime)
        pauseStart = time; lastTransition = time
    }

    public mutating func resume(at wallTime: Double) {
        guard let start = pauseStart, wallTime.isFinite else { return }
        let end = max(start, wallTime)
        pauses.append(start...end); excludedDuration += end - start
        pauseStart = nil; lastTransition = end
    }

    public func outputTime(at wallTime: Double) -> Double {
        guard wallTime.isFinite else { return 0 }
        let time = max(0, wallTime)
        var excluded: Double = 0
        for range in pauses where time > range.lowerBound {
            excluded += min(time, range.upperBound) - range.lowerBound
        }
        if let start = pauseStart, time > start { excluded += time - start }
        return max(0, time - excluded)
    }
}
