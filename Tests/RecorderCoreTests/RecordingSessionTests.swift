import AVFoundation
import RecorderCore

final class RecordingSessionTests: CheckSuite {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeSine(_ session: RecordingSession, seconds: Int) throws {
        let block = (0..<4800).flatMap { index -> [Float] in
            let amplitude = Float(sin(Double(index) * 2 * .pi * 440 / 48000) * 0.25)
            return [amplitude, amplitude]
        }
        for _ in 0..<(seconds * 10) { try session.write(block) }
    }

    func testSegmentsExportToSinglePlayableM4A() throws {
        let root = try temporary()
        let session = try RecordingSession(root: root, destination: root.appendingPathComponent("output"))
        try writeSine(session, seconds: 25)
        try session.finish()
        let pcms = try FileManager.default.contentsOfDirectory(atPath: session.directory.path).filter { $0.hasSuffix(".pcm") }
        expectEqual(pcms.count, 3)
        let url = try session.export()
        expectEqual(url.pathExtension, "m4a")
        let file = try AVAudioFile(forReading: url)
        expectEqual(Double(file.length) / file.fileFormat.sampleRate, 25, accuracy: 0.05)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)!
        try file.read(into: buffer)
        expectGreaterThan(buffer.frameLength, 0)
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        expectGreaterThan(samples.map(abs).max()!, 0.1)
        expectTrue(RecordingSession.recoverable(in: root).isEmpty)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: session.directory.path).filter { $0.hasSuffix(".pcm") }
        expectTrue(remaining.isEmpty)
    }

    func testInterruptedActiveSegmentRecoversCompleteFrames() throws {
        let root = try temporary()
        var original: RecordingSession? = try RecordingSession(root: root, destination: root)
        let directory = original!.directory
        try writeSine(original!, seconds: 12)
        // A process exit closes the open FD but does not finalize session state.
        original = nil
        let active = directory.appendingPathComponent("000001.pcm")
        let handle = try FileHandle(forWritingTo: active)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([0, 0])); try handle.close()
        let candidate = try requireValue(RecordingSession.recoverable(in: root).first)
        expectEqual(candidate.frames, 576000)
        let recovered = try RecordingSession(recovering: candidate)
        let url = try recovered.export()
        expectTrue(url.lastPathComponent.contains("中断录音"))
        expectEqual(try AVAudioFile(forReading: url).length, 576000, accuracy: 2048)
    }

    func testMissingSegmentNeverSilentlyExportsAndCacheSurvives() throws {
        let root = try temporary()
        let session = try RecordingSession(root: root, destination: root)
        try writeSine(session, seconds: 22); try session.finish()
        try FileManager.default.removeItem(at: session.directory.appendingPathComponent("000001.pcm"))
        expectThrows(try session.export())
        expectTrue(FileManager.default.fileExists(atPath: session.directory.appendingPathComponent("000000.pcm").path))
    }

    func testFailedDestinationCanBeChangedAndRetried() throws {
        let root = try temporary()
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: blocked)
        let session = try RecordingSession(root: root, destination: blocked)
        try writeSine(session, seconds: 1); try session.finish()
        expectThrows(try session.export())
        let candidate = try requireValue(RecordingSession.recoverable(in: root).first)
        let recovered = try RecordingSession(recovering: candidate)
        expectNil(recovered.info.interruption)
        try recovered.setDestination(root.appendingPathComponent("fixed"))
        let url = try recovered.export()
        expectFalse(url.lastPathComponent.contains("中断录音"))
    }

    func testEmptyAndInvalidAudioNeverSucceed() throws {
        let root = try temporary()
        let session = try RecordingSession(root: root, destination: root)
        expectThrows(try session.write([.nan, 0]))
        try session.finish()
        expectThrows(try session.export())
        expectTrue(RecordingSession.recoverable(in: root).isEmpty)
    }

    func testFourHourDiskAndAACExport() throws {
        guard ProcessInfo.processInfo.environment["RECORDER_LONG_EXPORT"] == "1" else {
            throw SkippedCheck("Set RECORDER_LONG_EXPORT=1 for 4-hour synthetic disk/AAC validation")
        }
        let root = try temporary()
        let session = try RecordingSession(root: root, destination: root.appendingPathComponent("output"))
        let start = Date()
        try writeSine(session, seconds: 14400)
        try session.finish()
        let segments = try FileManager.default.contentsOfDirectory(atPath: session.directory.path).filter { $0.hasSuffix(".pcm") }
        expectEqual(segments.count, 1440)
        expectEqual(session.totalFrames, 691_200_000)
        let url = try session.export()
        let audio = try AVAudioFile(forReading: url)
        expectEqual(Double(audio.length) / audio.fileFormat.sampleRate, 14400, accuracy: 0.05)
        let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 48000)!
        // Decode representative samples across the beginning, segment boundaries, middle and end.
        for second in [0, 9, 10, 3600, 7200, 10800, 14399] {
            audio.framePosition = Int64(second * 48000)
            try audio.read(into: buffer)
            expectEqual(buffer.frameLength, 48000)
            let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
            expectGreaterThan(rms, 0.15)
        }
        print("OFFLINE_ONLY 4h export frames=\(audio.length) segments=\(segments.count) fileBytes=\(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) runtime=\(Date().timeIntervalSince(start))s")
    }
}
