import Foundation
import AVFoundation
import CoreMedia
import RecorderCore

final class SessionControlTests: CheckSuite {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func time(_ epoch: CMTime, _ offset: Double) -> CMTime {
        CMTimeAdd(epoch, CMTime(seconds: offset, preferredTimescale: 48000))
    }

    private func buffer(_ value: Float, frames: Int = 4800, at timestamp: CMTime) throws -> CMSampleBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { pcm.floatChannelData![0][i] = value }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
        expectEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription, sampleCount: frames,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
        let result = try requireValue(sample)
        expectEqual(CMSampleBufferSetDataBufferFromAudioBufferList(result, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList), noErr)
        CMSampleBufferSetDataReady(result)
        return result
    }

    private func amplitude(_ session: RecordingSession, at seconds: Double) throws -> Float {
        let data = try Data(contentsOf: session.directory.appendingPathComponent("000000.pcm"))
        let frame = Int((seconds * 48000).rounded())
        return data.withUnsafeBytes { Float(Int16(littleEndian: $0.loadUnaligned(fromByteOffset: frame * 4, as: Int16.self))) / 32768 }
    }

    func testTimelineExcludesPausesAndKeepsHistory() {
        var timeline = RecordingTimeline()
        timeline.pause(at: 10); timeline.pause(at: 15)
        expectEqual(timeline.outputTime(at: 100), 10)
        timeline.resume(at: 30)
        timeline.pause(at: 50)
        expectEqual(timeline.outputTime(at: 99), 30)
        timeline.resume(at: 70)
        expectEqual(timeline.outputTime(at: 80), 40)
        expectEqual(timeline.outputTime(at: 5), 5)
        expectEqual(timeline.outputTime(at: 20), 10)
        expectEqual(timeline.outputTime(at: 40), 20)
        expectEqual(timeline.excludedDuration, 40)
        var many = RecordingTimeline()
        for i in 0..<1000 {
            let start = Double(i) * 14.4 + 4
            many.pause(at: start); many.resume(at: start + 0.2)
        }
        expectEqual(many.outputTime(at: 14400), 14200, accuracy: 0.000001)
    }

    func testPauseResumeDropsPausedAndPrefilledAudio() async throws {
        let root = try temporary(), epoch = CMClockGetTime(CMClockGetHostTimeClock())
        let session = try RecordingSession(root: root, destination: root, mode: .system)
        let pipeline = CapturePipeline(session: session, mode: .system, epoch: epoch)
        let old = UUID(), ignored = UUID(), resumed = UUID()
        await pipeline.activate(.system, token: old)
        let initial = try buffer(0.2, frames: 48000, at: epoch)
        pipeline.queue.sync { pipeline.receive(initial, source: .system, clock: nil, token: old) }
        let pausedDuration = try await pipeline.pause(at: time(epoch, 0.2))
        expectEqual(pausedDuration, 0.2, accuracy: 0.00001)
        expectEqual(session.info.state, "paused")
        await pipeline.activate(.system, token: ignored)
        let paused = try buffer(0.95, at: time(epoch, 0.4))
        pipeline.queue.sync { pipeline.receive(paused, source: .system, clock: nil, token: ignored) }
        try await pipeline.resume(at: time(epoch, 1.2))
        await pipeline.activate(.system, token: resumed)
        let next = try buffer(0.4, at: time(epoch, 1.25))
        let stale = try buffer(0.9, at: time(epoch, 1.25))
        pipeline.queue.sync {
            pipeline.receive(stale, source: .system, clock: nil, token: old)
            pipeline.receive(stale, source: .system, clock: nil, token: ignored)
            pipeline.receive(next, source: .system, clock: nil, token: resumed)
        }
        await pipeline.freeze(at: time(epoch, 1.5))
        let finished = try await pipeline.finish(at: time(epoch, 1.5), interruption: nil)
        expectTrue(finished === session)
        expectEqual(session.totalFrames, 24000)
        expectEqual(try amplitude(session, at: 0.1), 0.2, accuracy: 0.0001)
        expectEqual(try amplitude(session, at: 0.3), 0.4, accuracy: 0.0001)
        expectEqual(try amplitude(session, at: 0.4), 0, accuracy: 0.0001)
        expectNil(session.info.interruption)
    }

    func testFinishWhilePausedAndRecoverPausedCheckpoint() async throws {
        let root = try temporary(), epoch = CMClockGetTime(CMClockGetHostTimeClock())
        let session = try RecordingSession(root: root, destination: root, mode: .microphone)
        let pipeline = CapturePipeline(session: session, mode: .microphone, epoch: epoch)
        let token = UUID(); await pipeline.activate(.microphone, token: token)
        let audio = try buffer(0.3, frames: 24000, at: epoch)
        pipeline.queue.sync { pipeline.receive(audio, source: .microphone, clock: nil, token: token) }
        try await pipeline.pause(at: time(epoch, 0.15))
        let checkpoint = try requireValue(RecordingSession.recoverable(in: root).first)
        expectEqual(checkpoint.info.state, "paused")
        expectEqual(checkpoint.frames, 7200)
        _ = try await pipeline.finish(at: time(epoch, 2), interruption: nil)
        expectEqual(session.totalFrames, 7200)
        let output = try session.export()
        expectEqual(Double(try AVAudioFile(forReading: output).length) / 48000, 0.15, accuracy: 0.05)

        let separate = try RecordingSession(root: root, destination: root, mode: .system)
        try separate.write([Float](repeating: 0.1, count: 9600)); try separate.checkpoint(paused: true)
        let candidate = try requireValue(RecordingSession.recoverable(in: root).first)
        let recovered = try RecordingSession(recovering: candidate)
        expectTrue(recovered.info.interruption != nil)
    }

    func testLiveModeSwitchCutsDisabledAudioAndAdjustsGain() async throws {
        let root = try temporary(), epoch = CMClockGetTime(CMClockGetHostTimeClock())
        let session = try RecordingSession(root: root, destination: root.appendingPathComponent("out"), mode: .both)
        let pipeline = CapturePipeline(session: session, mode: .both, epoch: epoch)
        let system = UUID(), mic = UUID(), newMic = UUID(), newSystem = UUID()
        await pipeline.activate(.system, token: system); await pipeline.activate(.microphone, token: mic)
        let systemData = try buffer(0.1, frames: 48000, at: epoch), micData = try buffer(0.2, frames: 48000, at: epoch)
        pipeline.queue.sync {
            pipeline.receive(systemData, source: .system, clock: nil, token: system)
            pipeline.receive(micData, source: .microphone, clock: nil, token: mic)
        }
        await pipeline.beginTransition(at: time(epoch, 0.2))
        try await pipeline.updateMode(.system, at: time(epoch, 0.2))
        let rejected = try buffer(0.9, at: time(epoch, 0.25))
        pipeline.queue.sync { pipeline.receive(rejected, source: .microphone, clock: nil, token: mic) }
        try await pipeline.updateMode(.microphone, at: time(epoch, 0.4))
        await pipeline.activate(.microphone, token: newMic)
        let newMicData = try buffer(0.4, frames: 28800, at: time(epoch, 0.4))
        pipeline.queue.sync { pipeline.receive(newMicData, source: .microphone, clock: nil, token: newMic) }
        try await pipeline.updateMode(.both, at: time(epoch, 0.6))
        await pipeline.activate(.system, token: newSystem)
        let newSystemData = try buffer(0.2, frames: 19200, at: time(epoch, 0.6))
        pipeline.queue.sync { pipeline.receive(newSystemData, source: .system, clock: nil, token: newSystem) }
        _ = try await pipeline.finish(at: time(epoch, 1), interruption: nil)
        expectEqual(session.totalFrames, 48000)
        expectEqual(try amplitude(session, at: 0.1), 0.21, accuracy: 0.0001)
        expectEqual(try amplitude(session, at: 0.3), 0.1, accuracy: 0.0001)
        expectEqual(try amplitude(session, at: 0.5), 0.4, accuracy: 0.0001)
        expectEqual(try amplitude(session, at: 0.8), 0.42, accuracy: 0.0001)
        expectEqual(session.info.sourceModes, ["both", "system", "microphone", "both"])
        let output = try session.export()
        let entry = try requireValue(RecordingLibrary.scan(directories: [output.deletingLastPathComponent()], sessionsRoot: root).entries.first)
        expectEqual(entry.modeTitle, "来源已切换")
    }

    func testMicrophoneSwitchDiscardsOldDevicePrefill() async throws {
        let root = try temporary(), epoch = CMClockGetTime(CMClockGetHostTimeClock())
        let session = try RecordingSession(root: root, destination: root, mode: .microphone)
        let pipeline = CapturePipeline(session: session, mode: .microphone, epoch: epoch)
        let old = UUID(), new = UUID()
        await pipeline.activate(.microphone, token: old)
        let data = try buffer(0.2, frames: 48000, at: epoch)
        pipeline.queue.sync { pipeline.receive(data, source: .microphone, clock: nil, token: old) }
        await pipeline.beginTransition(at: time(epoch, 0.2))
        try await pipeline.resetSource(.microphone, at: time(epoch, 0.2))
        await pipeline.activate(.microphone, token: new)
        let next = try buffer(0.5, at: time(epoch, 0.25)), stale = try buffer(0.9, at: time(epoch, 0.25))
        pipeline.queue.sync {
            pipeline.receive(stale, source: .microphone, clock: nil, token: old)
            pipeline.receive(next, source: .microphone, clock: nil, token: new)
        }
        _ = try await pipeline.finish(at: time(epoch, 0.5), interruption: nil)
        expectEqual(try amplitude(session, at: 0.1), 0.2, accuracy: 0.0001)
        expectEqual(try amplitude(session, at: 0.3), 0.5, accuracy: 0.0001)
        expectEqual(try amplitude(session, at: 0.4), 0, accuracy: 0.0001)
    }

    func testModeChangeWhilePausedAndPermissionDelta() async throws {
        var gate = SourceGenerationGate(mode: .system)
        let old = UUID(); gate.activate(.microphone, token: old)
        gate.updateMode(.both); expectFalse(gate.accepts(.microphone, token: old))
        expectEqual(CaptureMode.system.newlyEnabled(comparedTo: .both), [])
        expectEqual(CaptureMode.microphone.newlyEnabled(comparedTo: .system), [.microphone])
        expectEqual(CaptureMode.both.newlyEnabled(comparedTo: .microphone), [.system])
        let root = try temporary(), epoch = CMClockGetTime(CMClockGetHostTimeClock())
        let session = try RecordingSession(root: root, destination: root, mode: .system)
        let pipeline = CapturePipeline(session: session, mode: .system, epoch: epoch)
        try await pipeline.pause(at: time(epoch, 0.1))
        try await pipeline.updateMode(.microphone, at: time(epoch, 0.9))
        expectEqual(session.totalFrames, 4800)
        expectEqual(session.info.state, "paused")
        _ = try await pipeline.finish(at: time(epoch, 2), interruption: nil)
        expectEqual(session.totalFrames, 4800)
    }

    func testTrashSyntheticFixtureAndRestore() throws {
        let root = try temporary()
        let original = root.appendingPathComponent("轻录删除自检-\(UUID().uuidString).caf")
        let contents = Data([1, 2, 3, 4])
        try contents.write(to: original)
        let trashed = try RecordingLibrary.moveToTrash(original)
        defer {
            if FileManager.default.fileExists(atPath: trashed.path), !FileManager.default.fileExists(atPath: original.path) {
                try? FileManager.default.moveItem(at: trashed, to: original)
            }
        }
        expectFalse(FileManager.default.fileExists(atPath: original.path))
        expectTrue(FileManager.default.fileExists(atPath: trashed.path))
        expectEqual(try Data(contentsOf: trashed), contents)
        expectTrue(RecordingLibrary.scan(directories: [root], sessionsRoot: root).entries.isEmpty)
        try FileManager.default.moveItem(at: trashed, to: original)
        expectEqual(try Data(contentsOf: original), contents)
        expectEqual(RecordingLibrary.scan(directories: [root], sessionsRoot: root).entries.count, 1)
    }

    func testTrashRejectsFoldersAndNonAudioFiles() throws {
        let root = try temporary()
        let text = root.appendingPathComponent("keep.txt")
        try Data([1]).write(to: text)
        expectThrows(try RecordingLibrary.moveToTrash(text))
        expectThrows(try RecordingLibrary.moveToTrash(root))
        expectThrows(try RecordingLibrary.moveToTrash(root.appendingPathComponent("missing.m4a")))
        expectTrue(FileManager.default.fileExists(atPath: text.path))
    }
}
