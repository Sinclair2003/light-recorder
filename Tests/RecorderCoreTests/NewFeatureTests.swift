import Foundation
import AVFoundation
import CoreMedia
import RecorderCore

final class NewFeatureTests: CheckSuite {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func toneFile(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for i in 0..<48_000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48_000)) * 0.2 }
        try file!.write(from: buffer); file = nil
    }

    private func buffer(value: Float, frames: Int = 4800, time: CMTime) throws -> CMSampleBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { pcm.floatChannelData![0][i] = value }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        let created = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription, sampleCount: frames,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        expectEqual(created, noErr)
        let result = try requireValue(sample)
        expectEqual(CMSampleBufferSetDataBufferFromAudioBufferList(result, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList), noErr)
        CMSampleBufferSetDataReady(result)
        return result
    }

    private func amplitude(_ session: RecordingSession, frame: Int) throws -> Float {
        let data = try Data(contentsOf: session.directory.appendingPathComponent("000000.pcm"))
        return data.withUnsafeBytes { Float(Int16(littleEndian: $0.loadUnaligned(fromByteOffset: frame * 4, as: Int16.self))) / 32768 }
    }

    func testRoutingAndModePolicy() {
        let builtIn = InputCandidate(id: "builtin", name: "Mac microphone", isBuiltIn: true)
        let headset = InputCandidate(id: "headset", name: "Headset", isBuiltIn: false)
        let usb = InputCandidate(id: "usb", name: "USB", isBuiltIn: false)
        expectEqual(InputRouting.choose(preferredID: "", available: [headset, builtIn], defaultID: "headset")?.id, "builtin")
        expectEqual(InputRouting.choose(preferredID: "headset", available: [headset, builtIn], defaultID: "builtin")?.id, "headset")
        expectEqual(InputRouting.choose(preferredID: "headset", available: [builtIn], defaultID: "builtin")?.id, "builtin")
        expectEqual(InputRouting.choose(preferredID: "headset", available: [usb], defaultID: "usb")?.id, "usb")
        expectNil(InputRouting.choose(preferredID: "headset", available: [], defaultID: nil))
        expectEqual(InputRouting.choose(preferredID: "headset", available: [headset, builtIn], defaultID: "builtin")?.id, "headset")
        expectFalse(CaptureMode.system.needsMicrophone)
        expectFalse(CaptureMode.microphone.needsSystem)
        expectTrue(CaptureMode.both.needsMicrophone && CaptureMode.both.needsSystem)
    }

    func testReconnectGenerationAndBackoff() {
        var gate = SourceGenerationGate(mode: .system)
        let old = UUID(), new = UUID()
        gate.activate(.system, token: old); gate.activate(.microphone, token: old)
        expectTrue(gate.accepts(.system, token: old)); expectFalse(gate.accepts(.microphone, token: old))
        gate.activate(.system, token: new); gate.invalidate(.system, token: old)
        expectFalse(gate.accepts(.system, token: old)); expectTrue(gate.accepts(.system, token: new))
        var retries = ReconnectBackoff()
        expectEqual((0..<6).map { _ in retries.failed() }, [1, 2, 4, 8, 8, 8])
        retries.succeeded(); expectEqual(retries.failed(), 1)
    }

    func testPipelineModeIsolation() async throws {
        let root = try temporary()
        for mode in CaptureMode.allCases {
            let epoch = CMClockGetTime(CMClockGetHostTimeClock())
            let session = try RecordingSession(root: root, destination: root, mode: mode)
            let pipeline = CapturePipeline(session: session, mode: mode, epoch: epoch)
            let system = UUID(), mic = UUID()
            await pipeline.activate(.system, token: system); await pipeline.activate(.microphone, token: mic)
            let time = CMTimeAdd(epoch, CMTime(seconds: 0.05, preferredTimescale: 48000))
            let a = try buffer(value: 0.2, time: time), b = try buffer(value: 0.4, time: time)
            pipeline.queue.sync {
                pipeline.receive(a, source: .system, clock: nil, token: system)
                pipeline.receive(b, source: .microphone, clock: nil, token: mic)
            }
            _ = try await pipeline.finish(at: CMTimeAdd(epoch, CMTime(seconds: 0.2, preferredTimescale: 48000)), interruption: nil)
            let expected: Float = mode == .both ? 0.42 : mode == .system ? 0.2 : 0.4
            expectEqual(try amplitude(session, frame: 4800), expected, accuracy: 0.0001)
            expectEqual(session.totalFrames, 9600)
            expectEqual(session.info.mode, mode.rawValue)
        }
    }

    func testPipelineReconnectKeepsOneTimeline() async throws {
        let root = try temporary()
        let epoch = CMClockGetTime(CMClockGetHostTimeClock())
        let session = try RecordingSession(root: root, destination: root, mode: .both)
        let pipeline = CapturePipeline(session: session, mode: .both, epoch: epoch)
        let counter = EventCounter()
        pipeline.onFailure = { counter.add("failure:\($0)") }
        pipeline.onSourceIssue = { _, _ in counter.add("sourceIssue") }
        let system = UUID(), oldMic = UUID(), newMic = UUID()
        await pipeline.activate(.system, token: system); await pipeline.activate(.microphone, token: oldMic)
        let systemBuffer = try buffer(value: 0.2, frames: 48000, time: epoch)
        let micBuffer = try buffer(value: 0.3, time: CMTimeAdd(epoch, CMTime(seconds: 0.02, preferredTimescale: 48000)))
        pipeline.queue.sync {
            pipeline.receive(systemBuffer, source: .system, clock: nil, token: system)
            pipeline.receive(micBuffer, source: .microphone, clock: nil, token: oldMic)
        }
        pipeline.reportSourceError(.microphone, token: oldMic, message: "synthetic device removed")
        pipeline.note("合成测试：设备切换，录音继续。")
        await pipeline.activate(.microphone, token: newMic)
        let time = CMTimeAdd(epoch, CMTime(seconds: 0.6, preferredTimescale: 48000))
        let stale = try buffer(value: 0.9, time: time), replacement = try buffer(value: 0.4, time: time)
        pipeline.queue.sync {
            pipeline.receive(stale, source: .microphone, clock: nil, token: oldMic)
            pipeline.receive(replacement, source: .microphone, clock: nil, token: newMic)
        }
        pipeline.reportSourceError(.microphone, token: oldMic, message: "stale old-stream callback")
        _ = try await pipeline.finish(at: CMTimeAdd(epoch, CMTime(seconds: 1, preferredTimescale: 48000)), interruption: nil)
        expectEqual(session.totalFrames, 48000)
        expectNil(session.info.interruption)
        expectEqual(session.info.notices?.count, 1)
        expectEqual(counter.snapshot, ["sourceIssue"])
        expectEqual(try amplitude(session, frame: 2400), 0.35, accuracy: 0.0001)
        expectEqual(try amplitude(session, frame: 12000), 0.14, accuracy: 0.0001)
        expectEqual(try amplitude(session, frame: 31200), 0.42, accuracy: 0.0001)
    }

    func testMissingMicRequestsReconnectInsteadOfEnding() async throws {
        let root = try temporary()
        let epoch = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: 6, preferredTimescale: 48000))
        let session = try RecordingSession(root: root, destination: root, mode: .microphone)
        let pipeline = CapturePipeline(session: session, mode: .microphone, epoch: epoch)
        let counter = EventCounter()
        pipeline.onFailure = { counter.add("failure:\($0)") }
        pipeline.onSourceIssue = { _, _ in counter.add("reconnect") }
        pipeline.begin()
        try await Task.sleep(nanoseconds: 150_000_000)
        let cutoff = CMClockGetTime(CMClockGetHostTimeClock())
        await pipeline.freeze(at: cutoff)
        _ = try await pipeline.finish(at: cutoff, interruption: nil)
        expectEqual(counter.snapshot, ["reconnect"])
        expectGreaterThan(session.totalFrames, 288000)
        expectNil(session.info.interruption)
    }

    func testSourceClockGlitchReconnectsWithoutEnding() async throws {
        let root = try temporary()
        let epoch = CMClockGetTime(CMClockGetHostTimeClock())
        let session = try RecordingSession(root: root, destination: root, mode: .both)
        let pipeline = CapturePipeline(session: session, mode: .both, epoch: epoch)
        let counter = EventCounter()
        pipeline.onFailure = { counter.add("failure:\($0)") }
        pipeline.onSourceIssue = { _, _ in counter.add("reconnect") }
        let old = UUID(), new = UUID()
        await pipeline.activate(.system, token: old)
        let future = try buffer(value: 1, time: CMTimeAdd(epoch, CMTime(seconds: 2.95, preferredTimescale: 48000)))
        pipeline.queue.sync { pipeline.receive(future, source: .system, clock: nil, token: old) }
        await pipeline.activate(.system, token: new)
        let valid = try buffer(value: 0.2, time: CMTimeAdd(epoch, CMTime(seconds: 0.05, preferredTimescale: 48000)))
        pipeline.queue.sync { pipeline.receive(valid, source: .system, clock: nil, token: new) }
        _ = try await pipeline.finish(at: CMTimeAdd(epoch, CMTime(seconds: 0.2, preferredTimescale: 48000)), interruption: nil)
        expectEqual(counter.snapshot, ["reconnect"])
        expectEqual(session.totalFrames, 9600)
        expectNil(session.info.interruption)
        expectEqual(try amplitude(session, frame: 4800), 0.14, accuracy: 0.0001)
    }

    func testLibraryMetadataAndOldRecordings() throws {
        let root = try temporary(), out = root.appendingPathComponent("output"), sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try toneFile(out.appendingPathComponent("已有录音.caf"))
        try Data([1]).write(to: out.appendingPathComponent(".partial.m4a"))
        try Data([1]).write(to: out.appendingPathComponent("损坏音频.m4a"))
        let session = try RecordingSession(root: sessions, destination: out, mode: .system)
        try session.write([Float](repeating: 0.1, count: 96000))
        try session.addNotice("00:00:00 设备切换提示"); try session.finish()
        let exported = try session.export()
        let scan = RecordingLibrary.scan(directories: [out, out], sessionsRoot: sessions)
        expectEqual(scan.entries.count, 3); expectTrue(scan.warnings.isEmpty)
        let entry = try requireValue(scan.entries.first { $0.url == exported })
        expectEqual(entry.mode, .system); expectEqual(entry.notices.count, 1)
        expectEqual(try requireValue(entry.duration), 1, accuracy: 0.05)
        let old = try requireValue(scan.entries.first { $0.title == "已有录音" })
        expectNil(old.mode); expectEqual(try requireValue(old.duration), 1, accuracy: 0.001)
        expectNil(scan.entries.first { $0.title == "损坏音频" }?.duration)
        try FileManager.default.removeItem(at: out.appendingPathComponent("已有录音.caf"))
        expectEqual(RecordingLibrary.scan(directories: [out], sessionsRoot: sessions).entries.count, 2)
    }

    func testOldSessionSchemaStillDecodes() throws {
        let root = try temporary()
        let object: [String: Any] = ["id": UUID().uuidString, "createdAt": "2026-10-26T12:00:00Z", "destination": root.path, "state": "ready"]
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let info = try decoder.decode(SessionInfo.self, from: JSONSerialization.data(withJSONObject: object))
        expectNil(info.mode); expectNil(info.notices)
    }

    @MainActor
    func testPlaybackControlsOnSyntheticAudio() async throws {
        let root = try temporary(), url = root.appendingPathComponent("合成播放自检.caf")
        try toneFile(url)
        let playback = PlaybackController(); playback.volume = 0
        defer { playback.stop() }
        expectTrue(playback.load(url)); expectNil(playback.error)
        expectEqual(playback.duration, 1, accuracy: 0.01)
        playback.seek(to: 0.4); expectEqual(playback.position, 0.4, accuracy: 0.01)
        playback.play()
        try await Task.sleep(nanoseconds: 180_000_000); playback.refresh()
        expectTrue(playback.isPlaying); expectGreaterThan(playback.position, 0.45)
        playback.pause(); let paused = playback.position
        try await Task.sleep(nanoseconds: 80_000_000); playback.refresh()
        expectFalse(playback.isPlaying); expectEqual(playback.position, paused, accuracy: 0.01)
        playback.seek(to: 20); expectEqual(playback.position, 1)
        playback.stop(); expectEqual(playback.position, 0)
        playback.play()
        try await Task.sleep(nanoseconds: 60_000_000); playback.refresh()
        expectTrue(playback.isPlaying)
        expectGreaterThan(playback.position, 0)
        playback.seek(to: 0.95)
        try await Task.sleep(nanoseconds: 200_000_000); playback.refresh()
        expectFalse(playback.isPlaying)
        expectEqual(playback.position, 1, accuracy: 0.05)
        playback.play()
        try await Task.sleep(nanoseconds: 60_000_000); playback.refresh()
        expectTrue(playback.isPlaying)
        expectGreaterThan(playback.position, 0)
        playback.stop()
        expectFalse(playback.load(root.appendingPathComponent("missing.caf")))
        expectTrue(playback.error != nil)
    }
}

private final class EventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func add(_ value: String) { lock.lock(); events.append(value); lock.unlock() }
    var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return events }
}
