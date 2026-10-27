import SwiftUI

struct TranscriptionPanel: View {
    let audio: URL
    @ObservedObject var recorder: RecorderModel
    @ObservedObject var transcription: TranscriptionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(audio.deletingPathExtension().lastPathComponent).font(.headline).lineLimit(1)
                    Text("本地中文转写").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !transcription.engineAvailable {
                HStack {
                    Text("选择本机 FunASR 环境后，可离线转写中文录音。")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("选择环境…") { transcription.selectEngine() }.disabled(transcription.isRunning)
                }
            }
            HStack(spacing: 14) {
                if transcription.isRunning {
                    Button("停止转写") { transcription.cancel() }.disabled(transcription.cancelling)
                } else {
                    Button("开始转写", systemImage: "text.bubble") { transcription.start(audio: audio, recorderBusy: recorder.busy) }
                        .buttonStyle(.borderedProminent).disabled(recorder.busy || !transcription.engineAvailable)
                }
                Toggle("区分说话人", isOn: $transcription.useSpeakerLabels)
                    .disabled(transcription.isRunning).help("说话人编号只在每个音频片段内有效。")
                Spacer()
                if transcription.engineAvailable {
                    Button { transcription.selectEngine() } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless).help("选择 FunASR 环境").disabled(transcription.isRunning)
                }
            }
            if recorder.busy { Text("录音完成后可以开始转写。 ").font(.caption).foregroundStyle(.secondary) }
            if transcription.useSpeakerLabels {
                Text("说话人编号仅在各片段内有效，跨片段不能直接对应。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if transcription.isRunning {
                if transcription.totalChunks > 0 {
                    ProgressView(value: Double(transcription.completedChunks), total: Double(transcription.totalChunks))
                } else { ProgressView().controlSize(.small) }
            }
            Text(transcription.status).font(.callout).foregroundStyle(.secondary)
            if let error = transcription.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            Divider()
            if let transcript = transcription.transcript {
                if transcription.showingPreviousResult {
                    Text("正在显示上一次的转写，当前任务完成后会更新。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if transcription.sourceChanged {
                    Text("源音频已发生变化，这份文字可能不再对应当前文件。")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !transcript.complete {
                    Text("未完成：已保留 \(transcript.completed_chunks)/\(transcript.total_chunks) 段。")
                        .font(.caption).foregroundStyle(.orange)
                }
                ScrollView {
                    Text(transcription.displayedText.isEmpty ? "未检测到可识别的语音。" : transcription.displayedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled).font(.body)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Text("文字由本地模型生成，请核对人名、数字和术语。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("复制") { transcription.copyText() }.disabled(transcription.displayedText.isEmpty)
                    Button("导出 TXT…") { transcription.exportText() }
                    Button("导出 JSON…") { transcription.exportJSON() }
                }
            } else {
                ContentUnavailableView("暂无转写文字", systemImage: "text.bubble")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(.horizontal, 4).frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { transcription.open(audio) }
            .onChange(of: audio) { _, value in transcription.open(value) }
    }
}
