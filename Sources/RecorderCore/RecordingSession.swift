import Foundation
import AVFoundation

public struct SessionInfo: Codable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var destination: String
    public var state: String
    public var interruption: String?
    public var exportedPath: String?
    public var mode: String?
    public var notices: [String]?
    public var sourceModes: [String]?
}

public struct RecoverableSession: Identifiable, Sendable {
    public var id: String { directory.lastPathComponent }
    public let directory: URL
    public let info: SessionInfo
    public let frames: Int64
    public var seconds: Double { Double(frames) / 48_000 }
}

/// Raw little-endian stereo Int16 segments need no container finalization to recover.
/// Only this class's serial owner may mutate it. Export runs after finish().
public final class RecordingSession: @unchecked Sendable {
    public let directory: URL
    public private(set) var info: SessionInfo
    public private(set) var totalFrames: Int64 = 0
    private var segmentIndex = 0
    private var segmentFrames = 0
    private var handle: FileHandle?
    private var finished = false
    private static let segmentLength = 480_000

    deinit { try? handle?.close() }

    public init(root: URL, destination: URL, now: Date = Date(), mode: CaptureMode? = nil) throws {
        let id = UUID()
        directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        info = SessionInfo(id: id, createdAt: now, destination: destination.path, state: "recording")
        info.mode = mode?.rawValue
        info.sourceModes = mode.map { [$0.rawValue] }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try persist()
    }

    public init(recovering candidate: RecoverableSession) throws {
        directory = candidate.directory
        info = candidate.info
        totalFrames = candidate.frames
        if info.state == "recording" || info.state == "paused" {
            info.state = "interrupted"
            info.interruption = "应用意外退出；本文件仅包含成功写入的录音。"
        }
        finished = true
        try persist()
    }

    public func write(_ interleaved: [Float]) throws {
        // FileHandle/Foundation may autorelease bridged NSData. Bound their lifetime even
        // when called from a long-running export, CLI test, or a queue without its own pool.
        try autoreleasepool { try writeChunk(interleaved) }
    }

    private func writeChunk(_ interleaved: [Float]) throws {
        guard !finished, interleaved.count % 2 == 0, interleaved.allSatisfy(\.isFinite) else { throw RecordingError.invalidAudio }
        var offset = 0
        while offset < interleaved.count / 2 {
            if handle == nil {
                let url = directory.appendingPathComponent(String(format: "%06d.pcm", segmentIndex))
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw RecordingError.damagedSegment }
                handle = try FileHandle(forWritingTo: url)
            }
            let count = min(Self.segmentLength - segmentFrames, interleaved.count / 2 - offset)
            var data = Data(count: count * 4)
            data.withUnsafeMutableBytes { raw in
                let ints = raw.bindMemory(to: Int16.self)
                for i in 0..<(count * 2) {
                    let x = max(-1, min(1, interleaved[offset * 2 + i]))
                    ints[i] = Int16((x * 32767).rounded()).littleEndian
                }
            }
            try handle?.write(contentsOf: data)
            offset += count; segmentFrames += count; totalFrames += Int64(count)
            if segmentFrames == Self.segmentLength { try sealSegment() }
        }
    }

    private func sealSegment() throws {
        guard let file = handle else { return }
        try file.synchronize()
        try file.close()
        handle = nil; segmentFrames = 0; segmentIndex += 1
    }

    public func finish(interruption: String? = nil) throws {
        guard !finished else { return }
        try sealSegment()
        info.state = interruption == nil ? "ready" : "interrupted"
        info.interruption = interruption
        finished = true
        try persist()
    }

    public func setDestination(_ url: URL) throws {
        info.destination = url.path
        try persist()
    }

    public func addNotice(_ notice: String) throws {
        var notices = info.notices ?? []
        if notices.last != notice { notices.append(notice) }
        info.notices = notices
        try persist()
    }

    public func checkpoint(paused: Bool) throws {
        guard !finished else { return }
        try handle?.synchronize()
        info.state = paused ? "paused" : "recording"
        try persist()
    }

    public func recordMode(_ mode: CaptureMode) throws {
        var modes = info.sourceModes ?? info.mode.map { [$0] } ?? []
        if modes.last != mode.rawValue { modes.append(mode.rawValue) }
        info.sourceModes = modes
        try persist()
    }

    private func persist() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(info).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
    }

    public static func recoverable(in root: URL) -> [RecoverableSession] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("session.json")),
                  let info = try? decoder.decode(SessionInfo.self, from: data), info.state != "completed" else { return nil }
            let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            guard children.contains(where: { url in
                url.pathExtension == "pcm" && ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
            }) else { return nil } // Failed startup with no audio is not a recoverable recording.
            // Include every complete stereo frame in the active segment after an unexpected exit.
            let frames = (try? segments(in: folder).reduce(Int64(0)) { count, url in
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                return count + Int64(size / 4)
            }) ?? 0
            return RecoverableSession(directory: folder, info: info, frames: frames)
        }.sorted { $0.info.createdAt < $1.info.createdAt }
    }

    private static func segments(in directory: URL) throws -> [URL] {
        let segments = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "pcm" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for (i, file) in segments.enumerated() {
            guard file.lastPathComponent == String(format: "%06d.pcm", i) else { throw RecordingError.missingSegments }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= segmentLength * 4 else { throw RecordingError.damagedSegment }
            if i < segments.count - 1, size != segmentLength * 4 { throw RecordingError.damagedSegment }
        }
        return segments
    }

    public static func freeBytes(at url: URL) throws -> Int64 {
        let values = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        return (values[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }

    /// Never deletes cache on failure; publishes output only after decoding and length validation.
    public func export(progress: @Sendable (Double) -> Void = { _ in }) throws -> URL {
        guard finished else { throw RecordingError.invalidAudio }
        let files = try Self.segments(in: directory)
        let frameCount = try files.reduce(Int64(0)) { total, file in
            total + Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) / 4
        }
        guard frameCount > 0 else { throw RecordingError.emptyRecording }
        let destination = URL(fileURLWithPath: info.destination, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let estimatedBytes = frameCount / 48_000 * 24_000 + 64 * 1_024 * 1_024
        guard try Self.freeBytes(at: destination) > estimatedBytes else { throw RecordingError.diskSpace }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let temporary = destination.appendingPathComponent(".\(info.id.uuidString).partial.m4a")
        if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
        var output: AVAudioFile? = try AVAudioFile(forWriting: temporary, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        do {
            var written: Int64 = 0
            var reportedPercent = -1
            for file in files {
                let input = try FileHandle(forReadingFrom: file)
                defer { try? input.close() }
                while true {
                    let count: Int = try autoreleasepool {
                        guard let data = try input.read(upToCount: 8192 * 4), !data.isEmpty else { return 0 }
                        let count = data.count / 4
                        guard count > 0 else { return 0 }
                        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                        buffer.frameLength = AVAudioFrameCount(count)
                        data.withUnsafeBytes { raw in
                            for i in 0..<count {
                                for ch in 0..<2 {
                                    let value = raw.loadUnaligned(fromByteOffset: (i * 2 + ch) * 2, as: Int16.self)
                                    buffer.floatChannelData![ch][i] = Float(Int16(littleEndian: value)) / 32768
                                }
                            }
                        }
                        try output!.write(from: buffer)
                        return count
                    }
                    if count == 0 { break }
                    written += Int64(count)
                    let percent = Int(Double(written) / Double(frameCount) * 100)
                    if percent > reportedPercent {
                        reportedPercent = percent
                        progress(Double(written) / Double(frameCount))
                    }
                }
            }
            output = nil // closes and finalizes AAC container on macOS 15 as well
            let verified = try AVAudioFile(forReading: temporary)
            guard abs(verified.length - frameCount) <= 2048 else {
                throw RecordingError.exportMismatch(expected: frameCount, actual: verified.length)
            }
            // Decode the last frames too, not just the header.
            verified.framePosition = max(0, verified.length - 4096)
            let check = AVAudioPCMBuffer(pcmFormat: verified.processingFormat, frameCapacity: 4096)!
            try verified.read(into: check)
            guard check.frameLength > 0 else { throw RecordingError.damagedSegment }
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let suffix = info.interruption == nil ? "" : "_中断录音"
            let name = "录音_\(formatter.string(from: info.createdAt))\(suffix)_\(info.id.uuidString.prefix(6)).m4a"
            let final = destination.appendingPathComponent(name)
            try FileManager.default.moveItem(at: temporary, to: final)
            info.state = "completed"; info.exportedPath = final.path
            try persist()
            // Cleanup only after a validated output and durable completion marker.
            for file in files { try? FileManager.default.removeItem(at: file) }
            return final
        } catch {
            output = nil
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
