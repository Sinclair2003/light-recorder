import Foundation
import RecorderCore

final class TimelineMixerTests: CheckSuite {
    func testMixMonoAndStereoOnSameTimeline() throws {
        let mixer = TimelineMixer()
        try mixer.append(source: .system, time: 0, rate: 48_000, channels: [[0.2, 0.4], [0.6, 0.8]])
        try mixer.append(source: .microphone, time: 0, rate: 48_000, channels: [[0.1, 0.3]])
        var samples: [Float] = []
        try mixer.drain(through: 2) { samples += $0 }
        for (actual, expected) in zip(samples, [Float(0.21), 0.49, 0.49, 0.77]) {
            expectEqual(actual, expected, accuracy: 0.0001)
        }
    }

    func testSilenceAndSourceGapPreserveDuration() throws {
        let mixer = TimelineMixer()
        try mixer.append(source: .microphone, time: 0.1, rate: 48_000, channels: [[Float](repeating: 0.5, count: 4800)])
        var nonzero = 0; var total = 0
        try mixer.drain(through: 14_400) { block in
            nonzero += block.filter { $0 != 0 }.count
            total += block.count
        }
        expectEqual(total, 28_800)
        expectEqual(nonzero, 9_600)
        expectEqual(mixer.cursor, 14_400)
    }

    func test44100HzResamplesTo48000WithoutChangingPitch() throws {
        let mixer = TimelineMixer()
        let input = (0..<4410).map { Float(sin(Double($0) * 2 * .pi * 1000 / 44_100)) }
        try mixer.append(source: .microphone, time: 0, rate: 44_100, channels: [input])
        var samples: [Float] = []
        try mixer.drain(through: 4800) { samples += $0 }
        for i in 1..<4798 {
            expectEqual(samples[i * 2], Float(sin(Double(i) * 2 * .pi * 1000 / 48_000)) * 0.7, accuracy: 0.003)
        }
    }

    func testClippingAndRingWrapAreBounded() throws {
        let mixer = TimelineMixer(bufferSeconds: 1)
        var maxAmplitude: Float = 0
        for tenth in 0..<30 {
            for source in AudioSource.allCases {
                try mixer.append(source: source, time: Double(tenth) / 10, rate: 48_000, channels: [[Float](repeating: 1, count: 4800)])
            }
            try mixer.drain(through: Int64((tenth + 1) * 4800)) { values in
                expectTrue(values.allSatisfy { $0 == 1 })
                maxAmplitude = max(maxAmplitude, values.max()!)
            }
        }
        expectEqual(maxAmplitude, 1)
        var trailing: [Float] = []
        try mixer.drain(through: 148_800) { trailing += $0 }
        expectTrue(trailing.allSatisfy { $0 == 0 })
    }

    func testDuplicateSamplesAreNotMixedTwice() throws {
        let mixer = TimelineMixer()
        let audio = [[Float](repeating: 0.5, count: 4800)]
        try mixer.append(source: .system, time: 0, rate: 48_000, channels: audio)
        try mixer.append(source: .system, time: 0, rate: 48_000, channels: audio)
        try mixer.drain(through: 4800) { values in expectTrue(values.allSatisfy { abs($0 - 0.35) < 0.0001 }) }
    }

    func testMalformedAndBacklogAreReported() throws {
        let mixer = TimelineMixer()
        expectThrows(try mixer.append(source: .system, time: .nan, rate: 48000, channels: [[0]]))
        expectThrows(try mixer.append(source: .system, time: 5, rate: 48000, channels: [[0]]))
        try mixer.drain(through: 4800) { _ in }
        try mixer.append(source: .microphone, time: 0, rate: 48000, channels: [[Float](repeating: 0, count: 4800)])
        expectEqual(mixer.lateFrames, 4800)
    }

    func testPreRollIsTrimmedWithoutFalseInterruption() throws {
        let mixer = TimelineMixer()
        try mixer.append(source: .microphone, time: -0.2, rate: 48_000, channels: [[Float](repeating: 0.5, count: 14_400)])
        expectEqual(mixer.lateFrames, 0)
        var count = 0
        try mixer.drain(through: 4800) { values in
            count += values.count
            expectTrue(values.allSatisfy { abs($0 - 0.35) < 0.0001 })
        }
        expectEqual(count, 9600)
    }

    func testFourHourSyntheticTimeline() throws {
        guard ProcessInfo.processInfo.environment["RECORDER_LONG_TEST"] == "1" else {
            throw SkippedCheck("Set RECORDER_LONG_TEST=1 for four-hour offline timeline validation")
        }
        let mixer = TimelineMixer()
        let input = [[Float](repeating: 0.125, count: 4800)]
        let mic = [[Float](repeating: 0.125, count: 4410)]
        var frames: Int64 = 0
        var mismatch = false
        let start = Date()
        for tenth in 0..<144_000 {
            let timestamp = Double(tenth) / 10
            try mixer.append(source: .system, time: timestamp, rate: 48000, channels: input)
            try mixer.append(source: .microphone, time: timestamp, rate: 44100, channels: mic)
            try mixer.drain(through: Int64(tenth + 1) * 4800) { block in
                frames += Int64(block.count / 2)
                if !block.allSatisfy({ abs($0 - 0.175) < 0.0001 }) { mismatch = true }
            }
        }
        expectFalse(mismatch)
        expectEqual(frames, 691_200_000)
        expectEqual(mixer.lateFrames, 0)
        print("OFFLINE_ONLY duration=14400s frames=\(frames) runtime=\(Date().timeIntervalSince(start))s")
    }
}
