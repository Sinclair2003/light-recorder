import AppKit
import SwiftUI
import RecorderCore
import UniformTypeIdentifiers

struct TranscriptionPage: View {
    @ObservedObject var recorder: RecorderModel
    @ObservedObject var transcription: TranscriptionModel
    @Binding var selection: URL?
    @Binding var importedAudio: [URL]

    private var imported: [URL] {
        importedAudio.filter { audio in
            !recorder.recordings.contains { $0.url.standardizedFileURL == audio.standardizedFileURL }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("选择录音").font(.headline)
                    Spacer()
                    Button { recorder.refreshLibrary() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("刷新录音列表").disabled(recorder.refreshingLibrary)
                }
                Button("导入音频…", systemImage: "doc.badge.plus") { importAudio() }
                    .disabled(transcription.isRunning)
                if recorder.recordings.isEmpty && imported.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform").font(.title2)
                        Text("暂无录音").font(.callout)
                    }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(imported, id: \.self) { audio in
                                audioRow(url: audio, subtitle: "已导入音频")
                            }
                            ForEach(recorder.recordings) { entry in
                                audioRow(url: entry.url, subtitle: [
                                    entry.createdAt.formatted(date: .abbreviated, time: .shortened),
                                    entry.duration.map(audioTimeText)
                                ].compactMap { $0 }.joined(separator: " · "))
                            }
                        }
                    }.frame(maxHeight: .infinity)
                }
            }.frame(width: 285).frame(maxHeight: .infinity)
            Divider()
            if let selection {
                TranscriptionPanel(audio: selection, recorder: recorder, transcription: transcription)
            } else {
                ContentUnavailableView("选择要转写的录音", systemImage: "text.bubble", description: Text("从左侧选择录音，或导入音频。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if let running = transcription.runningAudio { selection = running }
            if let selection, !FileManager.default.fileExists(atPath: selection.path) { self.selection = nil }
            else if let selection { rememberImported(selection) }
        }
    }

    private func audioRow(url: URL, subtitle: String) -> some View {
        let selected = selection?.standardizedFileURL == url.standardizedFileURL
        return Button { selection = url.standardizedFileURL } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(url.deletingPathExtension().lastPathComponent).font(.callout.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(10)
        .background(selected ? Color.blue.opacity(0.1) : Color.secondary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        .disabled(transcription.isRunning && transcription.runningAudio?.standardizedFileURL != url.standardizedFileURL)
        .help(url.path).accessibilityLabel("选择录音 \(url.deletingPathExtension().lastPathComponent)")
    }

    private func importAudio() {
        let panel = NSOpenPanel()
        panel.title = "选择要转写的音频"
        panel.allowedContentTypes = [.audio]
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            let audio = url.standardizedFileURL
            rememberImported(audio)
            selection = audio
        }
    }

    private func rememberImported(_ audio: URL) {
        guard !recorder.recordings.contains(where: { $0.url.standardizedFileURL == audio }),
              !importedAudio.contains(audio) else { return }
        importedAudio.append(audio)
    }
}
