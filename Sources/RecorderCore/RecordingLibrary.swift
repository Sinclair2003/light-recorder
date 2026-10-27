import Foundation
import AVFoundation

public struct RecordingEntry: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let createdAt: Date
    public let duration: Double?
    public let bytes: Int64
    public let mode: CaptureMode?
    public let modeHistory: [CaptureMode]
    public let notices: [String]
    public let interruption: String?
    public var title: String { url.deletingPathExtension().lastPathComponent }
    public var modeTitle: String? { Set(modeHistory).count > 1 ? "来源已切换" : mode?.title }
}

public struct LibraryScan: Sendable {
    public let entries: [RecordingEntry]
    public let warnings: [String]
}

public enum RecordingLibrary {
    private static let extensions: Set<String> = ["m4a", "wav", "caf", "mp3", "aif", "aiff"]

    /// Never falls back to permanent deletion. Caller handles playback and confirmation.
    public static func moveToTrash(_ url: URL) throws -> URL {
        guard extensions.contains(url.pathExtension.lowercased()),
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        guard let resultingURL else { throw CocoaError(.fileNoSuchFile) }
        return resultingURL as URL
    }
    public static func scan(directories: [URL], sessionsRoot: URL) -> LibraryScan {
        let fm = FileManager.default
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var infos: [String: SessionInfo] = [:]
        var roots = directories
        for folder in (try? fm.contentsOfDirectory(at: sessionsRoot, includingPropertiesForKeys: nil)) ?? [] {
            if let data = try? Data(contentsOf: folder.appendingPathComponent("session.json")),
               let info = try? decoder.decode(SessionInfo.self, from: data), let exported = info.exportedPath {
                infos[URL(fileURLWithPath: exported).standardizedFileURL.path] = info
                roots.append(URL(fileURLWithPath: exported).deletingLastPathComponent())
            }
        }
        var seen: Set<String> = []
        var entries: [RecordingEntry] = []
        var warnings: [String] = []
        var scannedDirectories: Set<String> = []
        for directory in roots {
            guard scannedDirectories.insert(directory.standardizedFileURL.path).inserted else { continue }
            guard fm.fileExists(atPath: directory.path) else { continue }
            do {
                for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey], options: .skipsHiddenFiles) {
                    let url = file.standardizedFileURL
                    guard extensions.contains(url.pathExtension.lowercased()), seen.insert(url.path).inserted,
                          (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                    let values = try url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
                    let info = infos[url.path]
                    let duration: Double? = autoreleasepool {
                        guard let audio = try? AVAudioFile(forReading: url), audio.fileFormat.sampleRate > 0 else { return nil }
                        return Double(audio.length) / audio.fileFormat.sampleRate
                    }
                    entries.append(RecordingEntry(url: url, createdAt: info?.createdAt ?? values.creationDate ?? values.contentModificationDate ?? .distantPast,
                        duration: duration, bytes: Int64(values.fileSize ?? 0), mode: info?.mode.flatMap(CaptureMode.init(rawValue:)),
                        modeHistory: (info?.sourceModes ?? info?.mode.map { [$0] } ?? []).compactMap(CaptureMode.init(rawValue:)),
                        notices: info?.notices ?? [], interruption: info?.interruption))
                }
            } catch { warnings.append("无法读取 \(directory.lastPathComponent)：\(error.localizedDescription)") }
        }
        return LibraryScan(entries: entries.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
        }, warnings: warnings)
    }
}
