import AVFoundation
import CoreMedia

public struct DecodedPCM {
    public let sampleRate: Double
    public let channels: [[Float]]
    public var peak: Float {
        channels.reduce(Float(0)) { current, values in max(current, values.reduce(0) { max($0, abs($1)) }) }
    }
}

/// Normalizes native interleaved/noninterleaved and integer/float audio buffers.
/// Decode while the CMSampleBuffer's AudioBufferList is valid; never retain its borrowed memory.
public final class PCMDecoder {
    private var converters: [AudioSource: AVAudioConverter] = [:]
    public init() {}

    public func decode(_ buffer: CMSampleBuffer, source: AudioSource) throws -> DecodedPCM {
        guard buffer.isValid, CMSampleBufferDataIsReady(buffer), let description = buffer.formatDescription else {
            throw RecordingError.invalidAudio
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard format.channelCount > 0, format.channelCount <= 32, format.sampleRate > 0 else {
            throw RecordingError.invalidAudio
        }
        return try buffer.withAudioBufferList { list, _ in
            guard let input = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer),
                  let target = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: format.channelCount),
                  let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: input.frameLength) else {
                throw RecordingError.invalidAudio
            }
            let converter: AVAudioConverter
            if let cached = converters[source], cached.inputFormat == format { converter = cached }
            else {
                guard let created = AVAudioConverter(from: format, to: target) else { throw RecordingError.invalidAudio }
                converter = created; converters[source] = created
            }
            try converter.convert(to: output, from: input)
            let count = Int(output.frameLength)
            guard count > 0, let floats = output.floatChannelData else { throw RecordingError.invalidAudio }
            let channels = (0..<min(Int(output.format.channelCount), 2)).map {
                Array(UnsafeBufferPointer(start: floats[$0], count: count))
            }
            return DecodedPCM(sampleRate: format.sampleRate, channels: channels)
        }
    }
}
