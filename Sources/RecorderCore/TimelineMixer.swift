import Foundation

public enum AudioSource: Int, CaseIterable, Sendable { case system, microphone }

public enum RecordingError: LocalizedError {
    case invalidAudio, bufferOverrun, diskSpace, missingSegments, damagedSegment, emptyRecording
    case exportMismatch(expected: Int64, actual: Int64)
    public var errorDescription: String? {
        switch self {
        case .invalidAudio: return "收到无效的音频格式或时间戳。"
        case .bufferOverrun: return "音频处理未能及时跟上，录音已中断并保留已录内容。"
        case .diskSpace: return "磁盘剩余空间不足，请清理空间或选择其他保存位置。"
        case .missingSegments: return "录音缓存不连续，已保留原始文件，请勿删除缓存。"
        case .damagedSegment: return "录音缓存损坏，已保留原始文件。"
        case .emptyRecording: return "没有可保存的音频，请先开始录音。"
        case let .exportMismatch(expected, actual): return "导出长度校验未通过（\(actual)/\(expected) 帧），录音缓存已保留。"
        }
    }
}

/// Single-queue timeline mixer. Silence advances with the clock, even when a source emits no buffers.
/// Source timestamps are translated into the capture's shared clock before calling append.
public final class TimelineMixer {
    public static let sampleRate = 48_000
    public private(set) var cursor: Int64 = 0
    public private(set) var lateFrames: Int64 = 0
    public private(set) var peak: Float = 0
    private let capacity: Int
    private var systemRing: [Float]
    private var microphoneRing: [Float]
    private var sourceEnds = [Int64.min, Int64.min]
    private var gain: Float
    private var sources: Set<AudioSource> = Set(AudioSource.allCases)

    public init(bufferSeconds: Int = 3, gain: Float = 0.7) {
        self.gain = gain
        capacity = max(1, bufferSeconds) * Self.sampleRate
        systemRing = [Float](repeating: 0, count: capacity * 2)
        microphoneRing = [Float](repeating: 0, count: capacity * 2)
    }

    public func clearSource(_ source: AudioSource) {
        if source == .system { systemRing = [Float](repeating: 0, count: capacity * 2) }
        else { microphoneRing = [Float](repeating: 0, count: capacity * 2) }
        sourceEnds[source.rawValue] = cursor
    }

    public func clearBufferedAudio() { AudioSource.allCases.forEach(clearSource) }

    public func selectSources(_ sources: Set<AudioSource>, gain: Float) {
        self.sources = sources; self.gain = gain
        for source in AudioSource.allCases where !sources.contains(source) { clearSource(source) }
    }

    /// Inputs are planar Float32. Timestamp placement continuously corrects clock drift.
    /// Linear interpolation covers native microphone rates; the system source is configured at 48kHz.
    public func append(source: AudioSource, time: Double, rate: Double, channels: [[Float]]) throws {
        guard sources.contains(source) else { return }
        guard time.isFinite, abs(time) < 1e9, rate.isFinite, rate >= 8_000, rate <= 384_000,
              let left = channels.first, !left.isEmpty,
              channels.allSatisfy({ $0.count == left.count }) else { throw RecordingError.invalidAudio }
        let begin = Int64((time * Double(Self.sampleRate)).rounded())
        let count = Int64((Double(left.count) * Double(Self.sampleRate) / rate).rounded())
        let end = begin + count
        guard end - cursor <= Int64(capacity) else { throw RecordingError.bufferOverrun }
        let start = max(begin, cursor, sourceEnds[source.rawValue])
        // Capture can deliver pre-roll samples from before the user's recording epoch.
        // Trimming that pre-roll is intentional; only lost frames at/after zero count as late.
        lateFrames += max(0, min(end, cursor) - max(0, begin, sourceEnds[source.rawValue]))
        sourceEnds[source.rawValue] = max(sourceEnds[source.rawValue], end)
        guard start < end else { return }
        let right = channels.count > 1 ? channels[1] : left
        let capacity = self.capacity
        let write: (UnsafeMutableBufferPointer<Float>) throws -> Void = { ring in
            for frame in start..<end {
                let position = Double(frame - begin) * rate / Double(Self.sampleRate)
                let i = min(Int(position), left.count - 1), j = min(i + 1, left.count - 1)
                let fraction = Float(position - Double(i))
                let l = left[i] + (left[j] - left[i]) * fraction
                let r = right[i] + (right[j] - right[i]) * fraction
                guard l.isFinite, r.isFinite else { throw RecordingError.invalidAudio }
                let slot = Int(frame % Int64(capacity)) * 2
                ring[slot] += l; ring[slot + 1] += r
            }
        }
        if source == .system { try systemRing.withUnsafeMutableBufferPointer { try write($0) } }
        else { try microphoneRing.withUnsafeMutableBufferPointer { try write($0) } }
    }

    /// Emits bounded chunks. Caller must persist each chunk before returning.
    public func drain(through target: Int64, write: ([Float]) throws -> Void) throws {
        guard target >= cursor else { return }
        while cursor < target {
            let length = Int(min(4_800, target - cursor))
            var output = [Float](repeating: 0, count: length * 2)
            let start = cursor, capacity = self.capacity, gain = self.gain
            let includeSystem = sources.contains(.system), includeMic = sources.contains(.microphone)
            var blockPeak: Float = 0
            systemRing.withUnsafeMutableBufferPointer { system in
                microphoneRing.withUnsafeMutableBufferPointer { mic in
                    output.withUnsafeMutableBufferPointer { destination in
                        for i in 0..<length {
                            let slot = Int((start + Int64(i)) % Int64(capacity)) * 2
                            for ch in 0..<2 {
                                let combined = (includeSystem ? system[slot + ch] : 0) + (includeMic ? mic[slot + ch] : 0)
                                let value = max(-1, min(1, combined * gain))
                                destination[i * 2 + ch] = value
                                blockPeak = max(blockPeak, abs(value))
                                system[slot + ch] = 0; mic[slot + ch] = 0
                            }
                        }
                    }
                }
            }
            peak = max(peak, blockPeak)
            try write(output)
            cursor += Int64(length)
        }
    }
}
