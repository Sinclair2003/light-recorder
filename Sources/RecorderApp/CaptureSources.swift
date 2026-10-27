import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreAudio
import RecorderCore

final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let token = UUID()
    private let pipeline: CapturePipeline
    private var stream: SCStream?
    private var stopped = false
    init(pipeline: CapturePipeline) { self.pipeline = pipeline }

    @MainActor
    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard !stopped else { throw CancellationError() }
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw UserFacingError("没有可用于系统声音采集的显示器。")
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let capture = SCStream(filter: filter, configuration: Self.configuration(), delegate: self)
        await pipeline.activate(.system, token: token)
        guard !stopped else { await pipeline.deactivate(.system, token: token); throw CancellationError() }
        try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: pipeline.queue)
        stream = capture
        do { try await capture.startCapture(); if stopped { try? await capture.stopCapture(); throw CancellationError() } }
        catch { await pipeline.deactivate(.system, token: token); try? await capture.stopCapture(); stream = nil; throw error }
    }

    @MainActor
    func refreshRoute() async throws { try await stream?.updateConfiguration(Self.configuration()) }

    @MainActor
    func stop() async {
        stopped = true
        let capture = stream; stream = nil
        try? await capture?.stopCapture()
        await pipeline.deactivate(.system, token: token)
    }

    private static func configuration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.capturesAudio = true; config.captureMicrophone = false
        config.sampleRate = 48_000; config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        config.width = 2; config.height = 2; config.showsCursor = false; config.queueDepth = 3
        config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
        return config
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio { pipeline.receive(sampleBuffer, source: .system, clock: stream.synchronizationClock, token: token) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        pipeline.reportSourceError(.system, token: token, message: "系统声音暂时中断，正在重连；本次录音继续。\(error.localizedDescription)")
    }
}

/// Microphone-only mode never initializes ScreenCaptureKit or asks for screen access.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let token = UUID()
    let deviceID: String
    private let pipeline: CapturePipeline
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let control = DispatchQueue(label: "cn.local.lightrecorder.microphone-control")
    private var observer: NSObjectProtocol?
    init(deviceID: String, pipeline: CapturePipeline) { self.deviceID = deviceID; self.pipeline = pipeline }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func start() async throws {
        await pipeline.activate(.microphone, token: token)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            control.async { [self] in
                do {
                    guard let device = AVCaptureDevice(uniqueID: deviceID), device.isConnected else {
                        throw UserFacingError("麦克风暂不可用，等待重新连接。")
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    session.beginConfiguration()
                    guard session.canAddInput(input), session.canAddOutput(output) else {
                        session.commitConfiguration(); throw UserFacingError("无法连接当前麦克风。")
                    }
                    session.addInput(input); session.addOutput(output)
                    output.setSampleBufferDelegate(self, queue: pipeline.queue)
                    session.commitConfiguration()
                    observer = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
                        guard let self else { return }
                        let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
                        self.pipeline.reportSourceError(.microphone, token: self.token,
                            message: "麦克风暂不可用，正在重连；本次录音继续。\(error?.localizedDescription ?? "")")
                    }
                    session.startRunning()
                    guard session.isRunning else { throw UserFacingError("麦克风未能启动，正在等待重连。") }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            control.async { [self] in
                output.setSampleBufferDelegate(nil, queue: nil)
                if session.isRunning { session.stopRunning() }
                if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
                continuation.resume()
            }
        }
        await pipeline.deactivate(.microphone, token: token)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        pipeline.receive(sampleBuffer, source: .microphone, clock: session.synchronizationClock, token: token)
    }
}

func defaultOutputDeviceID() -> AudioObjectID {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var device: AudioObjectID = 0
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    return device
}
