import Foundation

public enum CaptureMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case system, microphone, both
    public var id: String { rawValue }
    public var title: String {
        switch self { case .system: return "仅系统声音"; case .microphone: return "仅麦克风"; case .both: return "两者都录" }
    }
    public var sources: Set<AudioSource> {
        switch self { case .system: return [.system]; case .microphone: return [.microphone]; case .both: return [.system, .microphone] }
    }
    public var needsMicrophone: Bool { sources.contains(.microphone) }
    public var needsSystem: Bool { sources.contains(.system) }
    public var mixerGain: Float { self == .both ? 0.7 : 1 }
    public func newlyEnabled(comparedTo previous: CaptureMode) -> Set<AudioSource> { sources.subtracting(previous.sources) }
}

public struct InputCandidate: Sendable {
    public let id: String
    public let name: String
    public let isBuiltIn: Bool
    public init(id: String, name: String, isBuiltIn: Bool) {
        self.id = id; self.name = name; self.isBuiltIn = isBuiltIn
    }
}

public enum InputRouting {
    /// Keep an explicit selection while connected. Automatic/fallback prefers the built-in
    /// microphone so attaching headphones doesn't force Bluetooth input/profile switching.
    public static func choose(preferredID: String, available: [InputCandidate], defaultID: String?) -> InputCandidate? {
        available.first { $0.id == preferredID }
            ?? available.first { $0.isBuiltIn }
            ?? available.first { $0.id == defaultID }
            ?? available.first
    }
}

public struct ReconnectBackoff: Sendable {
    private var failures = 0
    public init() {}
    public mutating func failed() -> TimeInterval {
        let delay = min(8, pow(2, Double(min(failures, 3))))
        failures = min(3, failures + 1)
        return delay
    }
    public mutating func succeeded() { failures = 0 }
}

public func audioTimeText(_ seconds: Double) -> String {
    let value = seconds.isFinite ? Int(max(0, seconds)) : 0
    return String(format: "%02d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60)
}

public struct SourceGenerationGate: Sendable {
    private var mode: CaptureMode
    private var tokens: [AudioSource: UUID] = [:]
    public init(mode: CaptureMode) { self.mode = mode }
    public mutating func activate(_ source: AudioSource, token: UUID) {
        guard mode.sources.contains(source) else { return }
        tokens[source] = token
    }
    public mutating func updateMode(_ mode: CaptureMode) {
        self.mode = mode; tokens = tokens.filter { mode.sources.contains($0.key) }
    }
    public mutating func clear(_ source: AudioSource) { tokens.removeValue(forKey: source) }
    public mutating func clearAll() { tokens.removeAll() }
    public mutating func invalidate(_ source: AudioSource, token: UUID) {
        if tokens[source] == token { tokens.removeValue(forKey: source) }
    }
    public func accepts(_ source: AudioSource, token: UUID) -> Bool {
        mode.sources.contains(source) && tokens[source] == token
    }
}
