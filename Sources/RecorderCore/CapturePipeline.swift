import Foundation
import AVFoundation
import CoreMedia

/// One queue and one recording epoch survive every device/source reconnection.
public final class CapturePipeline: @unchecked Sendable {
    public let queue = DispatchQueue(label: "cn.local.lightrecorder.audio", qos: .userInitiated)
    public let session: RecordingSession
    public private(set) var mode: CaptureMode
    public var onMeter: ((Float, Float, Double) -> Void)?
    public var onFailure: ((String) -> Void)?
    public var onSourceIssue: ((AudioSource, String) -> Void)?
    private let mixer: TimelineMixer
    private let epoch: CMTime
    private var timer: DispatchSourceTimer?
    private var ended = false
    private var failed = false
    private var cutoffSeconds: Double?
    private var transitionBoundary: Double?
    private var timeline = RecordingTimeline()
    private var levels: [Float] = [0, 0]
    private var lastArrival: [AudioSource: Double] = [:]
    private var activation: [AudioSource: Double] = [:]
    private var firstBuffer: Set<AudioSource> = []
    private var issued: Set<AudioSource> = []
    private var lastDiskCheck: Double = 0
    private var reportedLateFrames: Int64 = 0
    private let decoder = PCMDecoder()
    private var gate: SourceGenerationGate

    public init(session: RecordingSession, mode: CaptureMode, epoch: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) {
        self.epoch = epoch
        self.session = session; self.mode = mode
        mixer = TimelineMixer(gain: mode.mixerGain)
        mixer.selectSources(mode.sources, gain: mode.mixerGain)
        gate = SourceGenerationGate(mode: mode)
    }

    private var wallElapsed: Double {
        CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), epoch))
    }
    private var elapsed: Double { timeline.outputTime(at: wallElapsed) }
    private func wallTime(_ time: CMTime) -> Double { max(0, CMTimeGetSeconds(CMTimeSubtract(time, epoch))) }

    public func activate(_ source: AudioSource, token: UUID) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !timeline.isPaused, !ended else { continuation.resume(); return }
                gate.activate(source, token: token)
                activation[source] = wallElapsed; lastArrival[source] = wallElapsed
                issued.remove(source); firstBuffer.insert(source)
                continuation.resume()
            }
        }
    }

    public func deactivate(_ source: AudioSource, token: UUID) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in gate.invalidate(source, token: token); continuation.resume() }
        }
    }

    public func begin() {
        queue.async { [self] in startTimer() }
    }

    private func startTimer() {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(100))
        source.setEventHandler { [weak self] in autoreleasepool { self?.tick() } }
        timer = source; source.resume()
    }

    public func freeze(at cutoff: CMTime) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                cutoffSeconds = wallTime(cutoff)
                timer?.cancel(); timer = nil
                continuation.resume()
            }
        }
    }

    public func beginTransition(at time: CMTime) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in transitionBoundary = wallTime(time); continuation.resume() }
        }
    }

    public func updateMode(_ newMode: CaptureMode, at time: CMTime) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard !ended else { throw RecordingError.invalidAudio }
                    if !timeline.isPaused {
                        try mixer.drain(through: Int64(timeline.outputTime(at: wallTime(time)) * 48_000), write: session.write)
                    }
                    let newlyEnabled = newMode.newlyEnabled(comparedTo: mode)
                    gate.updateMode(newMode); mixer.selectSources(newMode.sources, gain: newMode.mixerGain)
                    mode = newMode
                    for source in newlyEnabled { lastArrival[source] = wallElapsed; issued.remove(source) }
                    for source in AudioSource.allCases where !newMode.sources.contains(source) { levels[source.rawValue] = 0 }
                    transitionBoundary = nil
                    try session.recordMode(newMode)
                    try session.addNotice("\(audioTimeText(elapsed)) 录音来源切换为\(newMode.title)。")
                    continuation.resume()
                } catch { transitionBoundary = nil; continuation.resume(throwing: error) }
            }
        }
    }

    public func resetSource(_ source: AudioSource, at time: CMTime) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    if !timeline.isPaused {
                        try mixer.drain(through: Int64(timeline.outputTime(at: wallTime(time)) * 48_000), write: session.write)
                    }
                    gate.clear(source); mixer.clearSource(source); levels[source.rawValue] = 0
                    transitionBoundary = nil
                    continuation.resume()
                } catch { transitionBoundary = nil; continuation.resume(throwing: error) }
            }
        }
    }

    @discardableResult
    public func pause(at time: CMTime) async throws -> Double {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard !ended else { throw RecordingError.invalidAudio }
                    if !timeline.isPaused {
                        let wall = wallTime(time)
                        try mixer.drain(through: Int64(timeline.outputTime(at: wall) * 48_000), write: session.write)
                        timeline.pause(at: wall)
                        mixer.clearBufferedAudio(); gate.clearAll(); levels = [0, 0]
                        timer?.cancel(); timer = nil; cutoffSeconds = nil; transitionBoundary = nil
                        try session.checkpoint(paused: true)
                    }
                    continuation.resume(returning: timeline.outputTime(at: wallTime(time)))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func resume(at time: CMTime) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard !ended else { throw RecordingError.invalidAudio }
                    try session.checkpoint(paused: false)
                    timeline.resume(at: wallTime(time))
                    cutoffSeconds = nil; transitionBoundary = nil; issued.removeAll()
                    for source in mode.sources { lastArrival[source] = wallElapsed }
                    startTimer(); continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func note(_ text: String) {
        queue.async { [self] in
            guard !ended else { return }
            do { try session.addNotice("\(audioTimeText(elapsed)) \(text)") }
            catch { fail(error.localizedDescription) }
        }
    }

    private func tick() {
        guard !ended, !failed, cutoffSeconds == nil, !timeline.isPaused else { return }
        do {
            let seconds = elapsed
            let bufferedWall = min(max(0, wallElapsed - 0.35), transitionBoundary ?? .greatestFiniteMagnitude)
            try mixer.drain(through: Int64(timeline.outputTime(at: bufferedWall) * 48_000), write: session.write)
            if transitionBoundary == nil, mode.needsMicrophone, wallElapsed - (lastArrival[.microphone] ?? 0) > 5 {
                sourceIssue(.microphone, "麦克风暂时没有数据，正在重连；本次录音继续。")
            }
            if wallElapsed - lastDiskCheck >= 5 {
                lastDiskCheck = wallElapsed
                if try RecordingSession.freeBytes(at: session.directory) < 256 * 1_024 * 1_024 { throw RecordingError.diskSpace }
            }
            onMeter?(levels[0], levels[1], seconds)
            levels[0] *= 0.75; levels[1] *= 0.75
        } catch { fail(error.localizedDescription) }
    }

    /// Called on queue by each immutable source-generation delegate.
    public func receive(_ buffer: CMSampleBuffer, source: AudioSource, clock: CMClock?, token: UUID) {
        autoreleasepool {
            guard !ended, !failed, !timeline.isPaused, gate.accepts(source, token: token), buffer.isValid, CMSampleBufferDataIsReady(buffer) else { return }
            do {
                let time = CMSyncConvertTime(buffer.presentationTimeStamp, from: clock ?? CMClockGetHostTimeClock(), to: CMClockGetHostTimeClock())
                var seconds = CMTimeGetSeconds(CMTimeSubtract(time, epoch))
                guard seconds.isFinite, abs(seconds - wallElapsed) < 3 else { throw RecordingError.invalidAudio }
                let pcm = try decoder.decode(buffer, source: source)
                var channels = pcm.channels
                if firstBuffer.remove(source) != nil {
                    let trimBefore = max(activation[source] ?? 0, Double(mixer.cursor) / 48_000 + timeline.excludedDuration)
                    let trim = max(0, Int(ceil((trimBefore - seconds) * pcm.sampleRate)))
                    if trim >= channels[0].count { firstBuffer.insert(source); return }
                    if trim > 0 {
                        channels = channels.map { Array($0.dropFirst(trim)) }
                        seconds += Double(trim) / pcm.sampleRate
                    }
                }
                if let cutoffSeconds {
                    guard seconds < cutoffSeconds else { return }
                    let frames = min(channels[0].count, Int(max(0, (cutoffSeconds - seconds) * pcm.sampleRate)))
                    guard frames > 0 else { return }
                    channels = channels.map { Array($0.prefix(frames)) }
                }
                levels[source.rawValue] = min(1, pcm.peak)
                lastArrival[source] = wallElapsed
                try mixer.append(source: source, time: timeline.outputTime(at: seconds), rate: pcm.sampleRate, channels: channels)
                if mixer.lateFrames - reportedLateFrames > 4_800 {
                    reportedLateFrames = mixer.lateFrames
                    try session.addNotice("\(audioTimeText(elapsed)) 有采样到达过晚；此处可能短暂静音。")
                }
            } catch RecordingError.bufferOverrun {
                sourceIssue(source, "声源时间戳发生变化或数据暂时积压，正在重连；本次录音继续。")
            }
            catch { sourceIssue(source, "\(source == .system ? "系统声音" : "麦克风")数据暂不可用，正在重连：\(error.localizedDescription)") }
        }
    }

    public func reportSourceError(_ source: AudioSource, token: UUID, message: String) {
        queue.async { [self] in
            guard gate.accepts(source, token: token) else { return }
            sourceIssue(source, message)
        }
    }

    private func sourceIssue(_ source: AudioSource, _ text: String) {
        guard !ended, !failed, !timeline.isPaused, mode.sources.contains(source), issued.insert(source).inserted else { return }
        levels[source.rawValue] = 0; onSourceIssue?(source, text)
    }

    private func fail(_ message: String) {
        guard !failed, !ended else { return }
        failed = true; timer?.cancel(); timer = nil; onFailure?(message)
    }

    public func finish(at cutoff: CMTime, interruption: String?) async throws -> RecordingSession {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                timer?.cancel(); timer = nil
                guard !ended else { continuation.resume(returning: session); return }
                ended = true
                do {
                    let duration = timeline.outputTime(at: wallTime(cutoff))
                    try mixer.drain(through: Int64(max(0, duration) * 48_000), write: session.write)
                    try session.finish(interruption: interruption)
                    continuation.resume(returning: session)
                } catch {
                    try? session.finish(interruption: interruption ?? error.localizedDescription)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
