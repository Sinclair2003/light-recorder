import SwiftUI
import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreAudio
import IOKit.pwr_mgt
import RecorderCore

enum RecorderPhase { case idle, starting, recording, pausing, paused, resuming, stopping, saving }

@MainActor
final class RecorderModel: ObservableObject {
    @Published var phase: RecorderPhase = .idle
    @Published var mode: CaptureMode = .both { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "captureMode") } }
    @Published var duration: Double = 0
    @Published var systemLevel: Float = 0
    @Published var micLevel: Float = 0
    @Published var progress: Double = 0
    @Published var message = "选择录音来源，点击开始即可。"
    @Published var errorMessage: String?
    @Published var routeNotice: String?
    @Published var microphoneStatus = "自动优先使用内置麦克风"
    @Published var lastFile: URL?
    @Published var microphones: [AVCaptureDevice] = []
    @Published var microphoneID = "" { didSet { UserDefaults.standard.set(microphoneID, forKey: "preferredMicrophone") } }
    @Published var recoveries: [RecoverableSession] = []
    @Published var destination: URL
    @Published var recordings: [RecordingEntry] = []
    @Published var libraryWarning: String?
    @Published var refreshingLibrary = false
    @Published private(set) var changingControls = false
    @Published private(set) var deletingRecording = false
    @Published private var sourceProblems: [AudioSource: String] = [:]
    let playback = PlaybackController()
    private(set) var sessionsRoot: URL
    private var pipeline: CapturePipeline?
    private var systemCapture: SystemAudioCapture?
    private var microphoneCapture: MicrophoneCapture?
    private var assertion: IOPMAssertionID = 0
    private var deviceTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var sleepObserver: NSObjectProtocol?
    private var knownDirectories: [String]
    @Published private(set) var reconciling = false
    private var controlOperation: UUID?
    private var micNeedsRestart = false
    private var systemNeedsRestart = false
    private var nextMicRetry = Date.distantPast
    private var nextSystemRetry = Date.distantPast
    private var micBackoff = ReconnectBackoff()
    private var systemBackoff = ReconnectBackoff()
    private var outputDevice: AudioObjectID = 0
    private var previousRouteNotice: String?
    private var pendingLibrarySelection: URL?
    private var libraryNeedsRefresh = false
    var busy: Bool { phase != .idle }
    var recording: Bool { phase == .recording }
    var paused: Bool { phase == .paused }
    var hasSession: Bool { recording || paused || phase == .pausing || phase == .resuming }
    var canConfigure: Bool { (phase == .idle || recording || paused) && !changingControls && !reconciling && !deletingRecording }
    private var sourceUpdatesAllowed: Bool { recording || phase == .resuming }
    var reconnecting: Bool { !sourceProblems.isEmpty }
    var timeText: String { audioTimeText(duration) }
    var phaseText: String {
        switch phase {
        case .idle: return "准备就绪"
        case .starting: return "正在准备"
        case .recording: return reconnecting ? "正在录音 · 声源重连中" : "正在录音"
        case .pausing: return "正在暂停"
        case .paused: return "已暂停"
        case .resuming: return "正在继续录音"
        case .stopping: return "正在结束采集"
        case .saving: return "正在保存"
        }
    }

    init() {
        let fm = FileManager.default
        let music = fm.urls(for: .musicDirectory, in: .userDomainMask).first!
        destination = UserDefaults.standard.string(forKey: "destination").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? music.appendingPathComponent("轻录", isDirectory: true)
        knownDirectories = UserDefaults.standard.stringArray(forKey: "recordingDirectories") ?? []
        sessionsRoot = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LightRecorder/Sessions", isDirectory: true)
        mode = UserDefaults.standard.string(forKey: "captureMode").flatMap(CaptureMode.init(rawValue:)) ?? .both
        microphoneID = UserDefaults.standard.string(forKey: "preferredMicrophone") ?? ""
        rememberDestination()
        refreshDevices(); refreshRecoveries(); refreshLibrary()
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard self?.recording == true else { return }
                await self?.stop(interruption: "电脑进入睡眠，已保存进入睡眠前成功采集的内容。")
            }
        }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshDevices()
                    await self?.reconcileSources()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshLibrary() }
        })
    }

    func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        microphones = discovery.devices.filter { $0.isConnected }
    }

    private func chosenMicrophone() -> InputCandidate? {
        InputRouting.choose(preferredID: microphoneID, available: microphones.map {
            InputCandidate(id: $0.uniqueID, name: $0.localizedName, isBuiltIn: UInt32(bitPattern: $0.transportType) == kAudioDeviceTransportTypeBuiltIn)
        }, defaultID: AVCaptureDevice.default(for: .audio)?.uniqueID)
    }

    func refreshRecoveries() { recoveries = RecordingSession.recoverable(in: sessionsRoot) }

    private func rememberDestination() {
        if !knownDirectories.contains(destination.path) { knownDirectories.append(destination.path) }
        UserDefaults.standard.set(knownDirectories, forKey: "recordingDirectories")
    }

    func refreshLibrary(select url: URL? = nil) {
        if let url { pendingLibrarySelection = url }
        guard !refreshingLibrary else { libraryNeedsRefresh = true; return }
        refreshingLibrary = true
        let directories = knownDirectories.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let root = sessionsRoot
        Task {
            let scan = await Task.detached(priority: .utility) { RecordingLibrary.scan(directories: directories, sessionsRoot: root) }.value
            recordings = scan.entries; libraryWarning = scan.warnings.isEmpty ? nil : scan.warnings.joined(separator: "\n")
            refreshingLibrary = false
            if libraryNeedsRefresh { libraryNeedsRefresh = false; refreshLibrary(); return }
            if let selected = pendingLibrarySelection, !busy { pendingLibrarySelection = nil; _ = playback.load(selected) }
            else if let current = playback.url, !recordings.contains(where: { $0.url == current }), !busy { playback.clear() }
        }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "保存到这里"; panel.message = "选择录音保存文件夹；已有音频也会显示在列表中"
        if panel.runModal() == .OK, let url = panel.url {
            destination = url; rememberDestination()
            UserDefaults.standard.set(url.path, forKey: "destination")
            refreshLibrary()
        }
    }

    func start() async {
        guard phase == .idle, !deletingRecording else { return }
        playback.pause()
        let selectedMode = mode
        phase = .starting; errorMessage = nil; lastFile = nil; duration = 0
        systemLevel = 0; micLevel = 0; routeNotice = nil; sourceProblems = [:]; previousRouteNotice = nil
        do {
            try await authorize(selectedMode.sources)
            refreshDevices()
            try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            guard try RecordingSession.freeBytes(at: sessionsRoot) > 512 * 1_024 * 1_024 else { throw RecordingError.diskSpace }
            let session = try RecordingSession(root: sessionsRoot, destination: destination, mode: selectedMode)
            let processor = CapturePipeline(session: session, mode: selectedMode)
            pipeline = processor
            processor.onMeter = { [weak self, weak processor] system, mic, elapsed in
                Task { @MainActor in
                    guard let self, let processor, self.pipeline === processor, self.recording else { return }
                    self.systemLevel = system; self.micLevel = mic; self.duration = elapsed
                }
            }
            processor.onFailure = { [weak self, weak processor] reason in
                Task { @MainActor in
                    guard let self, let processor, self.pipeline === processor else { return }
                    await self.stop(interruption: reason)
                }
            }
            processor.onSourceIssue = { [weak self, weak processor] source, reason in
                Task { @MainActor in
                    guard let self, let processor, self.pipeline === processor,
                          self.phase == .recording || self.phase == .starting || self.phase == .resuming else { return }
                    guard self.mode.sources.contains(source) else { return }
                    self.reportSourceProblem(source, reason)
                    if source == .microphone { self.micNeedsRestart = true; self.nextMicRetry = .distantPast }
                    else { self.systemNeedsRestart = true; self.nextSystemRetry = .distantPast }
                    await self.reconcileSources()
                }
            }
            holdAwake(); processor.begin()
            if selectedMode.needsSystem {
                let source = SystemAudioCapture(pipeline: processor); systemCapture = source
                try await source.start()
                guard phase == .starting, pipeline === processor else { await source.stop(); return }
            }
            if selectedMode.needsMicrophone, let device = chosenMicrophone() {
                let source = MicrophoneCapture(deviceID: device.id, pipeline: processor); microphoneCapture = source
                try await source.start(); microphoneStatus = device.name
                guard phase == .starting, pipeline === processor else { await source.stop(); return }
            } else if selectedMode.needsMicrophone {
                reportSourceProblem(.microphone, "等待麦克风连接；本次录音会继续计时并自动恢复。")
            }
            phase = .recording; outputDevice = defaultOutputDeviceID()
            micNeedsRestart = false; systemNeedsRestart = false
            micBackoff.succeeded(); systemBackoff.succeeded()
            message = "\(selectedMode.title) · 关闭窗口后继续录制。"
            startDeviceTimer()
        } catch {
            let processor = pipeline
            await stopSources()
            if let processor { _ = try? await processor.finish(at: CMClockGetTime(CMClockGetHostTimeClock()), interruption: "启动未成功：\(error.localizedDescription)") }
            cleanupCapture(); phase = .idle
            message = "录音未开始，请检查后重试。"; errorMessage = error.localizedDescription
            refreshRecoveries()
        }
    }

    private func authorize(_ sources: Set<AudioSource>) async throws {
        if sources.contains(.microphone) {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw UserFacingError("未获得麦克风权限，原设置保持不变。请在系统设置的麦克风权限中允许“轻录”。")
            }
        }
        if sources.contains(.system) {
            do { _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
            catch { throw UserFacingError("未获得系统声音录制权限，原设置保持不变。请在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”中允许“轻录”。\n\(error.localizedDescription)") }
        }
    }

    private func beginControl() -> UUID {
        let id = UUID(); controlOperation = id; changingControls = true; errorMessage = nil; return id
    }

    private func endControl(_ id: UUID) {
        if controlOperation == id { controlOperation = nil; changingControls = false }
    }

    func changeMode(_ target: CaptureMode) async {
        guard canConfigure, target != mode else { return }
        if phase == .idle { mode = target; return }
        guard let processor = pipeline else { return }
        let id = beginControl(); defer { endControl(id) }
        let previous = mode
        do { try await authorize(target.newlyEnabled(comparedTo: previous)) }
        catch { errorMessage = error.localizedDescription; return }
        guard pipeline === processor, recording || paused else { return }
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        do {
            if recording {
                await processor.beginTransition(at: time)
                if !target.needsMicrophone {
                    let source = microphoneCapture; microphoneCapture = nil; await source?.stop()
                }
                if !target.needsSystem {
                    let source = systemCapture; systemCapture = nil; await source?.stop()
                }
            }
            guard pipeline === processor, recording || paused else { return }
            try await processor.updateMode(target, at: time)
            mode = target
            for source in AudioSource.allCases where !target.sources.contains(source) { sourceProblems.removeValue(forKey: source) }
            if !target.needsMicrophone { micNeedsRestart = false; micLevel = 0 }
            if !target.needsSystem { systemNeedsRestart = false; systemLevel = 0 }
            nextMicRetry = .distantPast; nextSystemRetry = .distantPast
            if recording { await reconcileSources(force: true) }
            routeNotice = paused ? "已设置继续录音时的来源：\(target.title)。" : "来源已切换：\(target.title)。本次录音继续。"
            message = paused ? "暂停期间不采集声音；继续后使用新的来源。" : "\(target.title) · 继续保存到同一个录音文件。"
        } catch {
            errorMessage = error.localizedDescription
            await stop(interruption: "切换来源时保存失败：\(error.localizedDescription)")
        }
    }

    func changeMicrophone(_ targetID: String) async {
        guard canConfigure, targetID != microphoneID else { return }
        if phase == .idle { microphoneID = targetID; return }
        guard let processor = pipeline else { return }
        let id = beginControl(); defer { endControl(id) }
        if mode.needsMicrophone {
            do { try await authorize([.microphone]) }
            catch { errorMessage = error.localizedDescription; return }
        }
        guard pipeline === processor, recording || paused else { return }
        do {
            let time = CMClockGetTime(CMClockGetHostTimeClock())
            if recording, mode.needsMicrophone {
                await processor.beginTransition(at: time)
                let source = microphoneCapture; microphoneCapture = nil; await source?.stop()
                try await processor.resetSource(.microphone, at: time)
            }
            microphoneID = targetID; nextMicRetry = .distantPast; micNeedsRestart = false
            if recording { await reconcileSources(force: true) }
            recordRouteNotice(paused ? "麦克风选择已更新，继续录音后生效。" : "麦克风选择已更新，本次录音继续；切换处可能短暂静音。")
        } catch {
            errorMessage = error.localizedDescription
            await stop(interruption: "切换麦克风时保存失败：\(error.localizedDescription)")
        }
    }

    func pause() async {
        guard recording, !changingControls, !reconciling, let processor = pipeline else { return }
        phase = .pausing; deviceTimer?.invalidate(); deviceTimer = nil
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        await processor.freeze(at: time)
        await stopSources()
        do {
            duration = try await processor.pause(at: time)
            processor.note("暂停录音。")
            releaseAwake(); systemLevel = 0; micLevel = 0; sourceProblems = [:]
            phase = .paused; message = "已暂停，暂停时段不计入音频；点击继续接着录，或结束并保存。"
            routeNotice = nil
        } catch {
            phase = .recording
            await stop(interruption: "暂停时保存失败：\(error.localizedDescription)")
        }
    }

    func resume() async {
        guard paused, canConfigure, let processor = pipeline else { return }
        let id = beginControl(); defer { endControl(id) }
        phase = .resuming
        do { try await authorize(mode.sources) }
        catch { phase = .paused; errorMessage = error.localizedDescription; return }
        guard pipeline === processor, phase == .resuming else { return }
        do {
            try await processor.resume(at: CMClockGetTime(CMClockGetHostTimeClock()))
            holdAwake(); processor.note("继续录音。")
            nextMicRetry = .distantPast; nextSystemRetry = .distantPast
            micBackoff.succeeded(); systemBackoff.succeeded()
            await reconcileSources(force: true)
            guard pipeline === processor, phase == .resuming else { return }
            phase = .recording; startDeviceTimer()
            message = "已继续录音，保存到同一个文件；暂停时段已排除。"
        } catch { phase = .paused; errorMessage = error.localizedDescription }
    }

    private func startDeviceTimer() {
        deviceTimer?.invalidate()
        deviceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.reconcileSources() }
        }
    }

    private func reportSourceProblem(_ source: AudioSource, _ text: String) {
        sourceProblems[source] = text; recordRouteNotice(text)
    }

    private func recordRouteNotice(_ text: String) {
        routeNotice = text
        if previousRouteNotice != text { pipeline?.note(text); previousRouteNotice = text }
    }

    private func reconcileSources(force: Bool = false) async {
        guard sourceUpdatesAllowed, !reconciling, (!changingControls || force), let processor = pipeline else { return }
        reconciling = true
        defer { if pipeline === processor { reconciling = false } }
        refreshDevices()
        let now = Date()
        if mode.needsMicrophone {
            let selected = chosenMicrophone()
            if selected?.id != microphoneCapture?.deviceID || micNeedsRestart || microphoneCapture == nil {
                if now >= nextMicRetry {
                    let old = microphoneCapture; microphoneCapture = nil; micNeedsRestart = false
                    await old?.stop()
                    guard sourceUpdatesAllowed, pipeline === processor else { return }
                    if let selected {
                        recordRouteNotice("正在连接\(selected.name)；录音继续，切换瞬间可能短暂静音。")
                        let source = MicrophoneCapture(deviceID: selected.id, pipeline: processor)
                        microphoneCapture = source
                        do {
                            try await source.start()
                            guard sourceUpdatesAllowed, pipeline === processor, mode.needsMicrophone else { await source.stop(); return }
                            microphoneCapture = source; microphoneStatus = selected.name
                            sourceProblems.removeValue(forKey: .microphone); micBackoff.succeeded(); nextMicRetry = .distantPast
                            recordRouteNotice("麦克风已连接：\(selected.name)。本次录音继续。")
                        } catch {
                            await source.stop()
                            if microphoneCapture === source { microphoneCapture = nil }
                            guard sourceUpdatesAllowed, pipeline === processor else { return }
                            nextMicRetry = Date().addingTimeInterval(micBackoff.failed())
                            reportSourceProblem(.microphone, "麦克风重连中，录音继续：\(error.localizedDescription)")
                        }
                    } else {
                        microphoneStatus = "等待设备连接"
                        reportSourceProblem(.microphone, "暂无可用麦克风；本次录音继续计时，连接后会自动恢复。")
                        nextMicRetry = Date().addingTimeInterval(1)
                    }
                }
            }
        }
        guard sourceUpdatesAllowed, pipeline === processor else { return }
        if mode.needsSystem {
            let currentOutput = defaultOutputDeviceID()
            if currentOutput != outputDevice {
                outputDevice = currentOutput
                recordRouteNotice("声音输出设备已变化，正在适配；本次录音继续。")
                do { try await systemCapture?.refreshRoute() }
                catch { systemNeedsRestart = true }
            }
            guard sourceUpdatesAllowed, pipeline === processor else { return }
            if (systemNeedsRestart || systemCapture == nil), now >= nextSystemRetry {
                let old = systemCapture; systemCapture = nil; systemNeedsRestart = false
                await old?.stop()
                guard sourceUpdatesAllowed, pipeline === processor else { return }
                let source = SystemAudioCapture(pipeline: processor)
                systemCapture = source
                do {
                    try await source.start()
                    guard sourceUpdatesAllowed, pipeline === processor, mode.needsSystem else { await source.stop(); return }
                    systemCapture = source; sourceProblems.removeValue(forKey: .system)
                    systemBackoff.succeeded(); nextSystemRetry = .distantPast
                    recordRouteNotice("系统声音已恢复，本次录音继续；重连瞬间可能短暂静音。")
                } catch {
                    await source.stop()
                    if systemCapture === source { systemCapture = nil }
                    guard sourceUpdatesAllowed, pipeline === processor else { return }
                    nextSystemRetry = Date().addingTimeInterval(systemBackoff.failed())
                    reportSourceProblem(.system, "系统声音重连中，录音继续：\(error.localizedDescription)")
                }
            }
        }
    }

    func stop(interruption: String? = nil) async {
        guard phase == .recording || phase == .paused || phase == .starting || phase == .resuming, let processor = pipeline else { return }
        phase = .stopping
        let cutoff = CMClockGetTime(CMClockGetHostTimeClock())
        deviceTimer?.invalidate(); deviceTimer = nil
        await processor.freeze(at: cutoff)
        await stopSources()
        do {
            let session = try await processor.finish(at: cutoff, interruption: interruption)
            cleanupCapture(); await export(session)
        } catch {
            cleanupCapture(); phase = .idle
            message = "保存未完成，已保留录音缓存。"; errorMessage = error.localizedDescription
            refreshRecoveries()
        }
    }

    private func stopSources() async {
        let mic = microphoneCapture; microphoneCapture = nil
        let system = systemCapture; systemCapture = nil
        await mic?.stop(); await system?.stop()
    }

    func recover(_ candidate: RecoverableSession) async {
        guard phase == .idle else { return }
        playback.pause()
        do {
            let session = try RecordingSession(recovering: candidate)
            try session.setDestination(destination); duration = candidate.seconds
            await export(session)
        } catch { errorMessage = error.localizedDescription }
    }

    private func export(_ session: RecordingSession) async {
        phase = .saving; progress = 0; message = "正在生成完整音频，请稍候…"
        do {
            let model = self
            let url = try await Task.detached(priority: .userInitiated) {
                try session.export { value in Task { @MainActor in model.progress = value } }
            }.value
            lastFile = url
            if let interruption = session.info.interruption { message = "已保存中断前的内容。\n\(interruption)" }
            else if !(session.info.notices ?? []).isEmpty { message = "录音已保存；暂停、切换等提示可在列表中查看。" }
            else { message = "录音已保存，可在列表中选择播放。" }
            errorMessage = nil; refreshLibrary(select: url)
        } catch {
            message = "导出失败，录音缓存已保留。可选择其他保存位置后重试。"
            errorMessage = error.localizedDescription
        }
        phase = .idle; systemLevel = 0; micLevel = 0; sourceProblems = [:]
        refreshRecoveries()
    }

    private func holdAwake() {
        _ = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "轻录正在录音" as CFString, &assertion)
    }

    private func cleanupCapture() {
        deviceTimer?.invalidate(); deviceTimer = nil
        releaseAwake()
        pipeline = nil; reconciling = false; controlOperation = nil; changingControls = false
    }

    private func releaseAwake() {
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
    }

    func trashRecording(_ entry: RecordingEntry) async {
        guard !busy, !deletingRecording else { return }
        deletingRecording = true; defer { deletingRecording = false }
        if playback.url == entry.url { playback.clear() }
        if pendingLibrarySelection == entry.url { pendingLibrarySelection = nil }
        do {
            _ = try await Task.detached(priority: .userInitiated) { try RecordingLibrary.moveToTrash(entry.url) }.value
            if lastFile == entry.url { lastFile = nil }
            message = "录音已移到废纸篓，可在 Finder 中恢复。"; errorMessage = nil
        } catch { errorMessage = "无法移到废纸篓，未永久删除文件：\(error.localizedDescription)" }
        refreshLibrary()
    }

    func selectRecording(_ entry: RecordingEntry) { guard !busy else { return }; _ = playback.load(entry.url) }
    func togglePlayback(_ entry: RecordingEntry) {
        guard !busy else { return }
        if playback.url != entry.url, !playback.load(entry.url) { return }
        playback.toggle()
    }
    func reveal(_ entry: RecordingEntry) { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
    func openPrivacy() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!) }
}

struct UserFacingError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}
