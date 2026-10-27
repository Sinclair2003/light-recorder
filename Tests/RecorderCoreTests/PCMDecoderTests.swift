import AVFoundation
import CoreMedia
import RecorderCore

final class PCMDecoderTests: CheckSuite {
    func testNativeBufferDecoding() throws {
        let decoder = PCMDecoder()
        // Common SCK system format and microphone formats, including a mid-stream format change.
        for (common, rate, channels, interleaved) in [
            (AVAudioCommonFormat.pcmFormatFloat32, 48_000.0, AVAudioChannelCount(2), false),
            (.pcmFormatInt16, 16_000.0, 1, true),
            (.pcmFormatFloat32, 44_100.0, 1, false)
        ] {
            let format = AVAudioFormat(commonFormat: common, sampleRate: rate, channels: channels, interleaved: interleaved)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
            buffer.frameLength = 480
            if common == .pcmFormatFloat32 {
                for c in 0..<Int(channels) { for i in 0..<480 { buffer.floatChannelData![c][i] = 0.25 } }
            } else {
                for i in 0..<(480 * Int(channels)) { buffer.int16ChannelData![0][i] = 8192 }
            }
            var sample: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                                            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
            let result = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
                sampleCount: 480, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
            expectEqual(result, noErr)
            let value = try requireValue(sample)
            let setResult = CMSampleBufferSetDataBufferFromAudioBufferList(value,
                blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0, bufferList: buffer.audioBufferList)
            expectEqual(setResult, noErr)
            CMSampleBufferSetDataReady(value)
            let decoded = try decoder.decode(value, source: .microphone)
            expectEqual(decoded.sampleRate, rate)
            expectEqual(decoded.channels.count, Int(channels))
            expectEqual(decoded.channels[0].count, 480)
            expectEqual(decoded.channels[0][100], 0.25, accuracy: 0.0001)
        }
    }
}
