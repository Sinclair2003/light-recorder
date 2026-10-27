import SwiftUI
import AppKit
import RecorderCore

@main
struct LightRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var recorder = RecorderModel()

    var body: some Scene {
        WindowGroup("轻录", id: "recorder") {
            RecorderView().environmentObject(recorder)
                .onAppear { delegate.recorder = recorder }
        }
        .defaultSize(width: 940, height: 740)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("打开录音文件夹") { NSWorkspace.shared.open(recorder.destination) }
            }
        }
        MenuBarExtra {
            MenuBarContent(recorder: recorder)
        } label: {
            if recorder.recording {
                Label("\(recorder.timeText)", systemImage: "record.circle.fill")
            } else if recorder.paused {
                Label("已暂停 \(recorder.timeText)", systemImage: "pause.circle.fill")
            } else {
                Label(recorder.phase == .saving ? "正在保存" : "轻录", systemImage: "waveform")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var recorder: RecorderModel?
    private var terminating = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recorder, recorder.busy else { return .terminateNow }
        if recorder.phase == .recording || recorder.paused, !terminating {
            terminating = true
            Task { @MainActor in
                await recorder.stop()
                terminating = false
                // A failed export stays visible and recoverable instead of silently quitting.
                sender.reply(toApplicationShouldTerminate: recorder.errorMessage == nil)
            }
            return .terminateLater
        }
        let alert = NSAlert()
        alert.messageText = "正在准备或保存录音"
        alert.informativeText = "请等待完成后退出。录音缓存会持续保留。"
        alert.runModal()
        return .terminateCancel
    }
}

struct MenuBarContent: View {
    @ObservedObject var recorder: RecorderModel
    @Environment(\.openWindow) var openWindow

    var body: some View {
        Text("轻录 · \(recorder.phaseText)")
        Text(recorder.mode.title)
        if recorder.hasSession { Text(recorder.timeText) }
        Button("显示录音窗口") {
            openWindow(id: "recorder")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Divider()
        if recorder.hasSession {
            Button(recorder.paused ? "继续录音" : "暂停录音") {
                Task { if recorder.paused { await recorder.resume() } else { await recorder.pause() } }
            }.disabled(!recorder.canConfigure)
            Button("结束并保存") { Task { await recorder.stop() } }
                .disabled((!recorder.recording && !recorder.paused) || recorder.changingControls)
        } else {
            Button("开始录音") { Task { await recorder.start() } }.disabled(recorder.busy || recorder.deletingRecording)
        }
        Picker("录音来源", selection: Binding(get: { recorder.mode }, set: { value in Task { await recorder.changeMode(value) } })) {
            ForEach(CaptureMode.allCases) { mode in Text(mode.title).tag(mode) }
        }.disabled(!recorder.canConfigure)
        Button("打开录音文件夹") { NSWorkspace.shared.open(recorder.destination) }
        Divider()
        Button("退出轻录") { NSApplication.shared.terminate(nil) }
    }
}
