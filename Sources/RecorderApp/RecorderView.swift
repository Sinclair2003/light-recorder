import SwiftUI
import AppKit
import RecorderCore

struct RecorderView: View {
    @EnvironmentObject var recorder: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill").font(.system(size: 42)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("轻录").font(.system(size: 25, weight: .semibold))
                    Text("自由选择声源 · 录音与回放都在这里").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if recorder.hasSession {
                    Label(recorder.paused ? "录音已暂停" : recorder.phaseText, systemImage: recorder.paused ? "pause.circle.fill" : "record.circle.fill")
                        .foregroundStyle(recorder.paused ? .orange : .red)
                }
            }
            HStack(alignment: .top, spacing: 22) {
                ScrollView {
                    recordingPanel.padding(.trailing, 4)
                }.frame(width: 360)
                Divider()
                RecordingLibraryView(recorder: recorder, playback: recorder.playback)
            }
        }
        .padding(24).frame(minWidth: 900, minHeight: 660)
    }

    private var recordingPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("录音来源").font(.headline)
            Picker("录音来源", selection: Binding(get: { recorder.mode }, set: { value in Task { await recorder.changeMode(value) } })) {
                ForEach(CaptureMode.allCases) { mode in Text(mode.title).tag(mode) }
            }.pickerStyle(.segmented).labelsHidden().disabled(!recorder.canConfigure)
                .accessibilityIdentifier("captureMode")

            VStack(spacing: 16) {
                Text(recorder.phaseText).font(.callout).foregroundStyle(.secondary)
                Text(recorder.timeText).font(.system(size: 40, weight: .light, design: .monospaced)).monospacedDigit()
                HStack(spacing: 20) {
                    LevelMeter(title: "系统声音", icon: "speaker.wave.2", level: recorder.systemLevel, color: .blue, enabled: recorder.mode.needsSystem)
                    LevelMeter(title: "麦克风", icon: "mic", level: recorder.micLevel, color: .teal, enabled: recorder.mode.needsMicrophone)
                }
                if recorder.phase == .saving { ProgressView(value: recorder.progress) }
            }
            .padding(20).frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))

            if recorder.mode.needsMicrophone {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("麦克风", systemImage: "mic")
                        Spacer()
                        Button { recorder.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).disabled(!recorder.canConfigure).help("刷新麦克风")
                    }
                    Picker("麦克风", selection: Binding(get: { recorder.microphoneID }, set: { value in Task { await recorder.changeMicrophone(value) } })) {
                        Text("自动（优先内置麦克风）").tag("")
                        ForEach(recorder.microphones, id: \.uniqueID) { device in Text(device.localizedName).tag(device.uniqueID) }
                        if !recorder.microphoneID.isEmpty, !recorder.microphones.contains(where: { $0.uniqueID == recorder.microphoneID }) {
                            Text("所选设备已断开（自动回退）").tag(recorder.microphoneID)
                        }
                    }.labelsHidden().disabled(!recorder.canConfigure)
                    Text(recorder.recording ? "当前：\(recorder.microphoneStatus) · 可直接切换设备" : "设备断开自动回退；录制中也可切换麦克风。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            if recorder.hasSession {
                HStack(spacing: 10) {
                    Button {
                        Task { if recorder.paused { await recorder.resume() } else { await recorder.pause() } }
                    } label: {
                        Label(recorder.paused ? "继续录音" : "暂停录音", systemImage: recorder.paused ? "play.fill" : "pause.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                    }.buttonStyle(.borderedProminent).tint(.blue).disabled(!recorder.canConfigure)
                    Button { Task { await recorder.stop() } } label: {
                        Label("结束并保存", systemImage: "stop.fill").frame(maxWidth: .infinity).padding(.vertical, 10)
                    }.buttonStyle(.borderedProminent).tint(.red)
                        .disabled((!recorder.recording && !recorder.paused) || recorder.changingControls)
                }
            } else {
                Button { Task { await recorder.start() } } label: {
                    Label(recorder.busy ? recorder.phaseText : "开始录音", systemImage: "record.circle")
                        .font(.system(size: 16, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                }.buttonStyle(.borderedProminent).tint(.blue).disabled(recorder.busy || recorder.deletingRecording)
            }
            if recorder.changingControls { ProgressView("正在应用录音设置…").font(.caption) }

            Text(recorder.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let notice = recorder.routeNotice {
                Label(notice, systemImage: recorder.reconnecting ? "arrow.triangle.2.circlepath" : "info.circle")
                    .font(.caption).foregroundStyle(recorder.reconnecting ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
            if let error = recorder.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                Button("打开隐私与安全性设置") { recorder.openPrivacy() }.font(.caption)
            }
            if !recorder.recoveries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("有 \(recorder.recoveries.count) 段录音等待保存").font(.callout.weight(.medium))
                    ForEach(recorder.recoveries) { candidate in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(candidate.info.createdAt.formatted(date: .abbreviated, time: .shortened))
                                Text(audioTimeText(candidate.seconds)).foregroundStyle(.secondary)
                            }.font(.caption)
                            Spacer()
                            Button("恢复保存") { Task { await recorder.recover(candidate) } }.disabled(recorder.busy)
                        }
                    }
                }.padding(10).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("保存位置 · M4A").font(.caption).foregroundStyle(.secondary)
                    Text(recorder.destination.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption).lineLimit(2).textSelection(.enabled)
                }
                Spacer()
                Button("更改…") { recorder.chooseDestination() }.disabled(recorder.busy)
            }
            Text("录音时可以关闭窗口。双路录音建议戴耳机；请勿合盖或主动睡眠。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct RecordingLibraryView: View {
    @ObservedObject var recorder: RecorderModel
    @ObservedObject var playback: PlaybackController
    @State private var pendingDeletion: RecordingEntry?

    private var selected: RecordingEntry? { recorder.recordings.first { $0.url == playback.url } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("我的录音").font(.headline)
                Text("\(recorder.recordings.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { recorder.refreshLibrary() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(recorder.refreshingLibrary).help("刷新录音列表")
                Button("打开文件夹", systemImage: "folder") { NSWorkspace.shared.open(recorder.destination) }.font(.caption)
            }
            if let warning = recorder.libraryWarning { Text(warning).font(.caption).foregroundStyle(.orange) }

            if recorder.recordings.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "waveform").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text(recorder.refreshingLibrary ? "正在读取录音…" : "暂无录音").font(.headline)
                    Text("录音保存后会自动出现在这里。\n也可以更改保存位置，查看该文件夹中的音频。")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(recorder.recordings) { entry in
                            HStack(spacing: 10) {
                                Button { recorder.selectRecording(entry) } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(entry.title).font(.callout.weight(.medium)).lineLimit(1).help(entry.url.path)
                                        HStack(spacing: 8) {
                                            Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                                            Text(entry.duration.map(audioTimeText) ?? "时长不可读")
                                        }.font(.caption).foregroundStyle(.secondary)
                                        HStack(spacing: 8) {
                                            if let mode = entry.modeTitle { Text(mode).foregroundStyle(.secondary) }
                                            if entry.interruption != nil { Label("中断录音", systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                                            else if !entry.notices.isEmpty { Label("有录音提示", systemImage: "info.circle").foregroundStyle(.orange) }
                                        }.font(.caption2)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(recorder.busy || recorder.deletingRecording)
                                Button { recorder.togglePlayback(entry) } label: {
                                    Image(systemName: playback.url == entry.url && playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                        .font(.system(size: 26)).foregroundStyle(.blue)
                                }.buttonStyle(.plain).disabled(recorder.busy || recorder.deletingRecording)
                                    .accessibilityLabel(playback.url == entry.url && playback.isPlaying ? "暂停\(entry.title)" : "播放\(entry.title)")
                                Button { recorder.reveal(entry) } label: { Image(systemName: "folder") }
                                    .buttonStyle(.borderless).help("在 Finder 中显示")
                                Button(role: .destructive) { pendingDeletion = entry } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).disabled(recorder.busy || recorder.deletingRecording)
                                    .help("删除录音（移到废纸篓）").accessibilityLabel("删除\(entry.title)")
                            }
                            .padding(12)
                            .background(playback.url == entry.url ? Color.blue.opacity(0.09) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }.frame(maxHeight: .infinity)
            }

            if let selected, !selected.notices.isEmpty || selected.interruption != nil {
                ScrollView {
                    Text(([selected.interruption].compactMap { $0 } + selected.notices).joined(separator: "\n"))
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(maxHeight: 60)
            }
            PlaybackView(playback: playback, disabled: recorder.busy || recorder.deletingRecording)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("将录音移到废纸篓？", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), presenting: pendingDeletion) { entry in
            Button("移到废纸篓", role: .destructive) { Task { await recorder.trashRecording(entry) } }
            Button("取消", role: .cancel) {}
        } message: { entry in
            Text("“\(entry.title)”会移到废纸篓，可在 Finder 中恢复。如果正在播放，会先停止播放。")
        }
    }
}

struct PlaybackView: View {
    @ObservedObject var playback: PlaybackController
    let disabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(playback.url?.deletingPathExtension().lastPathComponent ?? "选择一段录音开始回放")
                .font(.callout.weight(.medium)).lineLimit(1)
            Slider(value: Binding(get: { playback.position }, set: { playback.seek(to: $0) }), in: 0...max(0.001, playback.duration))
                .disabled(disabled || playback.duration == 0).accessibilityLabel("播放进度")
            HStack {
                Text(audioTimeText(playback.position))
                Spacer()
                Text(audioTimeText(playback.duration))
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button { playback.seek(to: playback.position - 10) } label: { Image(systemName: "gobackward.10") }.help("后退10秒")
                Button { playback.toggle() } label: {
                    Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 32))
                }.accessibilityLabel(playback.isPlaying ? "暂停播放" : "开始播放").foregroundStyle(.blue)
                Button { playback.stop() } label: { Image(systemName: "stop.fill") }.help("停止播放")
                Button { playback.seek(to: playback.position + 10) } label: { Image(systemName: "goforward.10") }.help("前进10秒")
                Spacer()
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(playback.volume) }, set: { playback.volume = Float($0) }), in: 0...1)
                    .frame(width: 85).accessibilityLabel("播放音量")
            }.buttonStyle(.borderless).disabled(disabled || playback.duration == 0)
            if let error = playback.error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if disabled { Text("录音或保存期间暂停回放，避免声音再次进入麦克风。").font(.caption).foregroundStyle(.secondary) }
        }.padding(16).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct LevelMeter: View {
    let title: String
    let icon: String
    let level: Float
    let color: Color
    let enabled: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(enabled ? title : "\(title)（未启用）", systemImage: icon).font(.caption).foregroundStyle(.secondary)
            GeometryReader { proxy in
                Capsule().fill(color.opacity(0.12))
                Capsule().fill(color).frame(width: proxy.size.width * (enabled ? min(1, max(0, Double(level))) : 0))
            }.frame(height: 5)
        }.opacity(enabled ? 1 : 0.45)
    }
}
