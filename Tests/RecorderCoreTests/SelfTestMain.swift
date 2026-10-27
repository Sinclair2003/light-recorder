import Foundation

// A small dependency-free harness for Apple's CommandLineTools (which omit XCTest).
// These are functional audio/disk checks, not substitutes for actual capture acceptance.
var checkFailures: [String] = []

class CheckSuite {
    private var cleanup: [() -> Void] = []
    func addTeardownBlock(_ block: @escaping () -> Void) { cleanup.append(block) }
    func tearDown() { cleanup.reversed().forEach { $0() }; cleanup = [] }
}

struct SkippedCheck: Error { let reason: String; init(_ reason: String) { self.reason = reason } }
struct CheckError: Error { let message: String }

func failure(_ message: String, file: StaticString, line: UInt) {
    checkFailures.append("\(file):\(line) \(message)")
}
func expectTrue(_ condition: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    if !condition() { failure("Expected true", file: file, line: line) }
}
func expectFalse(_ condition: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    if condition() { failure("Expected false", file: file, line: line) }
}
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    if actual != expected { failure("\(actual) != \(expected)", file: file, line: line) }
}
func expectEqual<T: BinaryFloatingPoint>(_ actual: T, _ expected: T, accuracy: T, file: StaticString = #filePath, line: UInt = #line) {
    if abs(actual - expected) > accuracy { failure("\(actual) != \(expected) ±\(accuracy)", file: file, line: line) }
}
func expectEqual(_ actual: Int64, _ expected: Int64, accuracy: Int64, file: StaticString = #filePath, line: UInt = #line) {
    if abs(actual - expected) > accuracy { failure("\(actual) != \(expected) ±\(accuracy)", file: file, line: line) }
}
func expectGreaterThan<T: Comparable>(_ actual: T, _ threshold: T, file: StaticString = #filePath, line: UInt = #line) {
    if actual <= threshold { failure("\(actual) <= \(threshold)", file: file, line: line) }
}
func expectThrows<T>(_ body: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try body(); failure("Expected error but succeeded", file: file, line: line) } catch {}
}
func expectNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    if value != nil { failure("Expected nil", file: file, line: line) }
}
func requireValue<T>(_ value: T?) throws -> T {
    guard let value else { throw CheckError(message: "Expected non-nil value") }; return value
}

struct CheckResult: Codable {
    let name: String
    let status: String
    let seconds: Double
    let details: [String]
}
struct CheckReport: Codable {
    let evidence: String
    let createdAt: Date
    let results: [CheckResult]
}

@main
@MainActor
struct SelfTestMain {
    static func main() async {
        let timeline = TimelineMixerTests()
        let sessions = RecordingSessionTests()
        let decoder = PCMDecoderTests()
        let features = NewFeatureTests()
        let controls = SessionControlTests()
        let tests: [(String, CheckSuite, () async throws -> Void)] = [
            ("pause_timeline_excludes_intervals", controls, controls.testTimelineExcludesPausesAndKeepsHistory),
            ("pipeline_pause_resume_same_file", controls, controls.testPauseResumeDropsPausedAndPrefilledAudio),
            ("finish_paused_and_checkpoint_recovery", controls, controls.testFinishWhilePausedAndRecoverPausedCheckpoint),
            ("live_mode_switch_audio_boundaries", controls, controls.testLiveModeSwitchCutsDisabledAudioAndAdjustsGain),
            ("live_microphone_switch_filters_old_device", controls, controls.testMicrophoneSwitchDiscardsOldDevicePrefill),
            ("paused_mode_change_and_permission_delta", controls, controls.testModeChangeWhilePausedAndPermissionDelta),
            ("trash_synthetic_fixture_and_restore", controls, controls.testTrashSyntheticFixtureAndRestore),
            ("trash_rejects_unsafe_targets", controls, controls.testTrashRejectsFoldersAndNonAudioFiles),
            ("recording_mode_and_input_fallback", features, features.testRoutingAndModePolicy),
            ("reconnect_generation_and_backoff", features, features.testReconnectGenerationAndBackoff),
            ("pipeline_mode_isolation", features, features.testPipelineModeIsolation),
            ("pipeline_reconnect_same_timeline", features, features.testPipelineReconnectKeepsOneTimeline),
            ("microphone_absence_requests_reconnect", features, features.testMissingMicRequestsReconnectInsteadOfEnding),
            ("source_clock_glitch_requests_reconnect", features, features.testSourceClockGlitchReconnectsWithoutEnding),
            ("recording_library_and_metadata", features, features.testLibraryMetadataAndOldRecordings),
            ("older_session_schema", features, features.testOldSessionSchemaStillDecodes),
            ("playback_pause_seek_resume_MUTED_SYNTHETIC", features, features.testPlaybackControlsOnSyntheticAudio),
            ("native_pcm_formats", decoder, decoder.testNativeBufferDecoding),
            ("mix_mono_stereo", timeline, timeline.testMixMonoAndStereoOnSameTimeline),
            ("silence_preserves_time", timeline, timeline.testSilenceAndSourceGapPreserveDuration),
            ("resample_44100_to_48000", timeline, timeline.test44100HzResamplesTo48000WithoutChangingPitch),
            ("clipping_and_ring_wrap", timeline, timeline.testClippingAndRingWrapAreBounded),
            ("duplicate_buffers", timeline, timeline.testDuplicateSamplesAreNotMixedTwice),
            ("invalid_audio_and_backlog", timeline, timeline.testMalformedAndBacklogAreReported),
            ("pre_roll_trim", timeline, timeline.testPreRollIsTrimmedWithoutFalseInterruption),
            ("four_hour_timeline_OFFLINE", timeline, timeline.testFourHourSyntheticTimeline),
            ("pcm_segments_to_aac", sessions, sessions.testSegmentsExportToSinglePlayableM4A),
            ("active_segment_crash_recovery", sessions, sessions.testInterruptedActiveSegmentRecoversCompleteFrames),
            ("missing_segment_preserves_cache", sessions, sessions.testMissingSegmentNeverSilentlyExportsAndCacheSurvives),
            ("export_retry_new_destination", sessions, sessions.testFailedDestinationCanBeChangedAndRetried),
            ("invalid_and_empty_recording", sessions, sessions.testEmptyAndInvalidAudioNeverSucceed),
            ("four_hour_disk_aac_OFFLINE", sessions, sessions.testFourHourDiskAndAACExport)
        ]
        var results: [CheckResult] = []
        for (name, suite, run) in tests {
            checkFailures = []
            let began = Date()
            var status = "passed"
            do { try await run() }
            catch let skip as SkippedCheck { status = "skipped"; checkFailures.append(skip.reason) }
            catch { status = "failed"; checkFailures.append(error.localizedDescription) }
            suite.tearDown()
            if status != "skipped", !checkFailures.isEmpty { status = "failed" }
            let result = CheckResult(name: name, status: status, seconds: Date().timeIntervalSince(began), details: checkFailures)
            results.append(result)
            print("\(status.uppercased()) \(name) (\(String(format: "%.3f", result.seconds))s)")
            checkFailures.prefix(10).forEach { print("  \($0)") }
            fflush(stdout)
        }
        let report = CheckReport(evidence: "synthetic_offline_only_no_microphone_or_system_capture", createdAt: Date(), results: results)
        if let index = CommandLine.arguments.firstIndex(of: "--report"), index + 1 < CommandLine.arguments.count {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(to: url, options: .atomic)
            } catch { print("Cannot write report: \(error)"); exit(2) }
        }
        let failed = results.filter { $0.status == "failed" }.count
        print("\(results.count - failed - results.filter { $0.status == "skipped" }.count) passed, \(failed) failed, \(results.filter { $0.status == "skipped" }.count) skipped. OFFLINE evidence only.")
        if failed > 0 { exit(1) }
    }
}
