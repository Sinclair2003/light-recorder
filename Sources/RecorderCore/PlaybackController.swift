import Foundation
import AVFoundation
import Combine

@MainActor
public final class PlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published public private(set) var url: URL?
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var position: Double = 0
    @Published public private(set) var isPlaying = false
    @Published public private(set) var error: String?
    @Published public var volume: Float = 1 { didSet { player?.volume = volume } }
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var stoppedManually = true

    public override init() { super.init() }
    deinit { timer?.invalidate() }

    @discardableResult
    public func load(_ url: URL) -> Bool {
        stop(); player = nil
        self.url = url; duration = 0; position = 0; error = nil
        do {
            let audio = try AVAudioPlayer(contentsOf: url)
            audio.delegate = self; audio.volume = volume
            guard audio.prepareToPlay() else { throw PlaybackError.unavailable }
            player = audio; duration = audio.duration
            return true
        } catch {
            self.error = "无法播放这段录音：\(error.localizedDescription)"
            return false
        }
    }

    public func toggle() { isPlaying ? pause() : play() }

    public func play() {
        guard let player else { return }
        error = nil
        if position >= duration - 0.01 { player.currentTime = 0; position = 0 }
        guard player.play() else { error = "播放未能开始，请检查声音输出设备后重试。"; return }
        stoppedManually = false
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    public func pause() {
        stoppedManually = true
        player?.pause(); position = player?.currentTime ?? position
        isPlaying = false; timer?.invalidate(); timer = nil
    }

    public func stop() {
        stoppedManually = true
        player?.stop(); player?.currentTime = 0
        position = 0; isPlaying = false; timer?.invalidate(); timer = nil
    }

    public func clear() { stop(); player = nil; url = nil; duration = 0; error = nil }

    public func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        position = max(0, min(duration, seconds)); player?.currentTime = position
    }

    public func refresh() {
        guard let player else { return }
        if !isPlaying, !stoppedManually, position >= duration - 0.01 { return }
        if isPlaying, !player.isPlaying {
            position = position >= duration - 0.25 ? duration : player.currentTime
            isPlaying = false; timer?.invalidate(); timer = nil
        } else { position = player.currentTime }
    }

    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player, !self.stoppedManually, !player.isPlaying else { return }
            self.isPlaying = false; self.position = self.duration
            self.timer?.invalidate(); self.timer = nil
            if !flag { self.error = "播放未完整结束，请重试或检查音频文件。" }
        }
    }

    nonisolated public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.pause(); self.error = "音频解码失败：\(error?.localizedDescription ?? "未知错误")"
        }
    }
}

private enum PlaybackError: LocalizedError {
    case unavailable
    var errorDescription: String? { "音频设备暂不可用。" }
}
