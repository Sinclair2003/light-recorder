import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import RecorderCore
import UniformTypeIdentifiers

struct TranscriptSentence: Decodable {
    let start_ms: Int
    let end_ms: Int
    let text: String
    let speaker: String?
}

struct TranscriptDocument: Decodable {
    let audio_file: String
    let duration_seconds: Double
    let source_size_bytes: Int64?
    let source_mtime_ns: Int64?
    let completed_chunks: Int
    let total_chunks: Int
    let complete: Bool
    let speaker_labels: Bool
    let text: String
    let sentences: [TranscriptSentence]
}

@MainActor
final class TranscriptionModel: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var cancelling = false
    @Published private(set) var runningAudio: URL?
    @Published private(set) var shownAudio: URL?
    @Published private(set) var status = "准备就绪"
    @Published private(set) var error: String?
    @Published private(set) var completedChunks = 0
    @Published private(set) var totalChunks = 0
    @Published private(set) var transcript: TranscriptDocument?
    @Published private(set) var resultURL: URL?
    @Published private(set) var sourceChanged = false
    @Published var useSpeakerLabels = false
    @Published private(set) var engineRoot: URL?

    private var process: Process?
    private var jobDirectory: URL?
    private var outputBuffer = Data()
    private var errorBuffer = Data()
    private var pendingError: String?
    private var terminationCallback: (() -> Void)?
    private var activeRunID: UUID?
    private let defaultsKey = "transcriptionEngineRoot"
    private let fileManager = FileManager.default
    private let storageRoot: URL
    private static let modelNames = [
        "iic--speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch",
        "iic--speech_fsmn_vad_zh-cn-16k-common-pytorch",
        "iic--punc_ct-transformer_cn-en-common-vocab471067-large",
        "iic--speech_campplus_sv_zh-cn_16k-common"
    ]

    init() {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        storageRoot = applicationSupport.appendingPathComponent("LightRecorder/Transcriptions", isDirectory: true)
        if let configured = UserDefaults.standard.string(forKey: defaultsKey),
           Self.engineIsValid(URL(fileURLWithPath: configured, isDirectory: true), speaker: false) {
            engineRoot = URL(fileURLWithPath: configured, isDirectory: true)
        } else if let bundled = Bundle.main.resourceURL?.appendingPathComponent("FunASREngine", isDirectory: true),
                  Self.engineIsValid(bundled, speaker: false) {
            engineRoot = bundled
        }
    }

    var engineAvailable: Bool { engineRoot.map { Self.engineIsValid($0, speaker: useSpeakerLabels) } ?? false }
    var showingPreviousResult: Bool {
        guard isRunning, let resultURL, let jobDirectory else { return false }
        return resultURL.deletingLastPathComponent() != jobDirectory
    }
    var displayedText: String {
        guard let transcript else { return "" }
        if transcript.speaker_labels, !transcript.sentences.isEmpty {
            return transcript.sentences.map { item in
                let time = audioTimeText(Double(item.start_ms) / 1000)
                let who = item.speaker.map { " · \($0)" } ?? ""
                return "[\(time)\(who)] \(item.text)"
            }.joined(separator: "\n")
        }
        return transcript.text
    }

    func open(_ url: URL) {
        shownAudio = url.standardizedFileURL
        if !isRunning { status = "准备就绪"; error = nil }
        loadLatest(for: url)
    }

    func selectEngine() {
        let panel = NSOpenPanel()
        panel.title = "选择 FunASR 本地环境"
        panel.message = "选择包含 .venv 和 .cache/modelscope 的 FunASR 文件夹。"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard Self.engineIsValid(url, speaker: false) else {
            error = "这个文件夹没有完整的 FunASR 环境或中文模型。"
            return
        }
        engineRoot = url.standardizedFileURL
        UserDefaults.standard.set(engineRoot?.path, forKey: defaultsKey)
        error = nil
    }

    func start(audio: URL, recorderBusy: Bool) {
        guard !isRunning, !recorderBusy else { return }
        guard let root = engineRoot, Self.engineIsValid(root, speaker: useSpeakerLabels) else {
            error = useSpeakerLabels ? "找不到完整的 FunASR 环境或说话人模型，请先选择本地环境。" : "请先选择已安装的 FunASR 本地环境。"
            return
        }
        guard let worker = Bundle.main.url(forResource: "TranscribeWorker", withExtension: "py"),
              fileManager.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            error = "转写组件不可用，请重新安装轻录。"; return
        }
        let source = audio.standardizedFileURL
        do {
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { throw CocoaError(.fileReadInvalidFileName) }
            let job = directory(for: source).appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(at: job, withIntermediateDirectories: true)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            var arguments = ["-p", "(version 1) (allow default) (deny network*)", Self.python(in: root).path,
                             "-u", worker.path, "--audio", source.path, "--engine-root", root.path, "--job-dir", job.path]
            if useSpeakerLabels { arguments.append("--speaker") }
            task.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "PYTHONPATH")
            // Inputs are decoded by macOS afconvert; do not depend on Homebrew ffmpeg.
            environment["PATH"] = "/usr/bin:/bin"
            environment["PYTHONNOUSERSITE"] = "1"
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            environment["PYTHONUNBUFFERED"] = "1"
            environment["OMP_NUM_THREADS"] = "2"
            environment["OPENBLAS_NUM_THREADS"] = "2"
            environment["HF_HUB_OFFLINE"] = "1"
            environment["TRANSFORMERS_OFFLINE"] = "1"
            environment["MODELSCOPE_OFFLINE"] = "1"
            let numbaCache = fileManager.temporaryDirectory.appendingPathComponent("LightRecorder-Numba", isDirectory: true)
            try fileManager.createDirectory(at: numbaCache, withIntermediateDirectories: true)
            environment["NUMBA_CACHE_DIR"] = numbaCache.path
            task.environment = environment
            let output = Pipe(), errors = Pipe()
            let runID = UUID()
            task.standardOutput = output; task.standardError = errors
            outputBuffer = Data(); errorBuffer = Data(); pendingError = nil
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let bytes = handle.availableData
                if bytes.isEmpty { handle.readabilityHandler = nil; return }
                Task { @MainActor [weak self] in self?.consume(bytes, runID: runID) }
            }
            errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let bytes = handle.availableData
                if bytes.isEmpty { handle.readabilityHandler = nil; return }
                Task { @MainActor [weak self] in
                    guard self?.activeRunID == runID else { return }
                    self?.errorBuffer.append(bytes)
                    if let self, self.errorBuffer.count > 32_768 { self.errorBuffer = Data(self.errorBuffer.suffix(32_768)) }
                }
            }
            task.terminationHandler = { [weak self] finished in
                output.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor [weak self] in self?.finish(status: finished.terminationStatus, runID: runID) }
            }
            try task.run()
            shownAudio = source; runningAudio = source; jobDirectory = job; process = task; activeRunID = runID
            isRunning = true; cancelling = false; completedChunks = 0; totalChunks = 0
            status = "正在准备转写…"; error = nil
        } catch {
            self.error = "无法启动转写：\(error.localizedDescription)"
        }
    }

    func cancel() {
        guard isRunning, !cancelling else { return }
        cancelling = true; status = "正在停止转写…"
        guard let task = process else { return }
        task.terminate()
        Task { @MainActor [weak self, weak task] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, let task, self.cancelling, self.process === task, task.isRunning else { return }
            // Some native libraries defer SIGTERM during initialization.
            Darwin.kill(task.processIdentifier, SIGKILL)
        }
    }

    func cancelThen(_ action: @escaping () -> Void) {
        guard isRunning else { action(); return }
        terminationCallback = action
        cancel()
    }

    func exportText() {
        guard let audio = shownAudio, transcript != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = audio.deletingPathExtension().lastPathComponent + "-转写.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try displayedText.write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = "导出失败：\(error.localizedDescription)" }
    }

    func exportJSON() {
        guard let audio = shownAudio, let resultURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = audio.deletingPathExtension().lastPathComponent + "-转写.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(contentsOf: resultURL).write(to: url, options: .atomic) }
        catch { self.error = "导出失败：\(error.localizedDescription)" }
    }

    func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(displayedText, forType: .string)
    }

    func hasSavedTranscript(for url: URL) -> Bool {
        let root = directory(for: url)
        let jobs = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return jobs.contains { job in
            ["baseline.json", "baseline.partial.json", "speaker.json", "speaker.partial.json"].contains {
                fileManager.fileExists(atPath: job.appendingPathComponent($0).path)
            }
        }
    }

    private func consume(_ data: Data, runID: UUID) {
        guard activeRunID == runID else { return }
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 10) {
            let line = String(data: outputBuffer[..<newline], encoding: .utf8) ?? ""
            outputBuffer.removeSubrange(...newline)
            guard line.hasPrefix("LIGHTREC_EVENT "),
                  let eventData = line.dropFirst("LIGHTREC_EVENT ".count).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any],
                  let kind = event["kind"] as? String else { continue }
            if kind == "status", let message = event["message"] as? String, !cancelling {
                status = message
                if message.contains("加载") { completedChunks = 0; totalChunks = 0 }
            }
            if kind == "error", let message = event["message"] as? String { pendingError = message }
            if kind == "progress", let complete = event["completed"] as? Int, let total = event["total"] as? Int {
                completedChunks = complete; totalChunks = total
                let phase = event["phase"] as? String == "speaker" ? "正在区分说话人" : "正在转写"
                if !cancelling { status = "\(phase) · 已完成 \(complete)/\(total) 段" }
                if let audio = runningAudio { loadLatest(for: audio, preferredJob: jobDirectory) }
            }
        }
        if outputBuffer.count > 262_144 { outputBuffer = Data(outputBuffer.suffix(65_536)) }
    }

    private func finish(status code: Int32, runID: UUID) {
        guard activeRunID == runID else { return }
        let wasCancelled = cancelling
        let completedAudio = runningAudio
        let job = jobDirectory
        if pendingError == nil, let job,
           let data = try? Data(contentsOf: job.appendingPathComponent("manifest.json")),
           let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            pendingError = manifest["error"] as? String
        }
        let hasSavedWords = job.map { directory in
            ["baseline.json", "baseline.partial.json"].contains { fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }
        } ?? false
        if let job {
            try? fileManager.removeItem(at: job.appendingPathComponent("decoded.wav"))
            try? fileManager.removeItem(at: job.appendingPathComponent("chunk.wav"))
        }
        isRunning = false; cancelling = false; process = nil; runningAudio = nil; jobDirectory = nil; activeRunID = nil
        if let completedAudio, shownAudio == completedAudio { loadLatest(for: completedAudio, preferredJob: job) }
        if code == 0 {
            status = transcript?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? "转写完成" : "未检测到可识别的语音"
            error = nil
        } else if wasCancelled || code == 130 {
            status = hasSavedWords ? "已停止转写，已完成的文字已保留" : "已停止转写"
        } else if let job, fileManager.fileExists(atPath: job.appendingPathComponent("baseline.json").path) {
            status = "普通转写已完成"
            error = "说话人识别未完成，普通转写已保留。\(pendingError.map { " " + $0 } ?? "")"
        } else {
            status = "转写未完成，已有文字已保留"
            error = pendingError ?? "转写进程退出（\(code)），请检查模型环境后重试。"
        }
        let callback = terminationCallback; terminationCallback = nil; callback?()
    }

    private func directory(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return storageRoot.appendingPathComponent(digest, isDirectory: true)
    }

    private func loadLatest(for url: URL, preferredJob: URL? = nil) {
        let root = directory(for: url)
        let jobs = ((try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? [])
            .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
        let ordered = (preferredJob.map { [$0] } ?? []) + jobs.filter { $0 != preferredJob }
        for job in ordered {
            for name in ["speaker.json", "baseline.json", "speaker.partial.json", "baseline.partial.json"] {
                let candidate = job.appendingPathComponent(name)
                if let data = try? Data(contentsOf: candidate), let document = try? JSONDecoder().decode(TranscriptDocument.self, from: data), document.audio_file == url.standardizedFileURL.path {
                    let attributes = try? fileManager.attributesOfItem(atPath: url.path)
                    let bytes = (attributes?[.size] as? NSNumber)?.int64Value
                    let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970
                    sourceChanged = (document.source_size_bytes != nil && bytes != document.source_size_bytes)
                        || (document.source_mtime_ns != nil && modified.map { abs($0 - Double(document.source_mtime_ns!) / 1_000_000_000) > 0.01 } != false)
                    transcript = document; resultURL = candidate; return
                }
            }
        }
        transcript = nil; resultURL = nil; sourceChanged = false
    }

    private static func python(in root: URL) -> URL {
        let bundled = root.appendingPathComponent("python/bin/python3.11")
        return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : root.appendingPathComponent(".venv/bin/python")
    }
    private static func engineIsValid(_ root: URL, speaker: Bool) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: python(in: root).path) else { return false }
        let models = root.appendingPathComponent(".cache/modelscope/models", isDirectory: true)
        return (speaker ? modelNames : Array(modelNames.prefix(3))).allSatisfy { name in
            let path = models.appendingPathComponent(name + "/snapshots/master", isDirectory: true)
            let weights = name.contains("campplus") ? "campplus_cn_common.bin" : "model.pt"
            return FileManager.default.fileExists(atPath: path.appendingPathComponent(weights).path)
                && FileManager.default.fileExists(atPath: path.appendingPathComponent("config.yaml").path)
        }
    }
}
