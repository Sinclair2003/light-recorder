#!/usr/bin/env python3
"""Read back final offline evidence, installed app, archive and source hashes."""
import hashlib
import json
import plistlib
import shutil
import struct
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from zipfile import ZipFile

root = Path(__file__).resolve().parent.parent
app = Path.home() / 'Applications' / '轻录.app'
archive_path = root / 'dist/轻录-mac.zip'
report_path = root / 'artifacts/final-test-report.json'
report = json.loads(report_path.read_text())
required = {'recording_mode_and_input_fallback', 'reconnect_generation_and_backoff', 'pipeline_mode_isolation',
            'pause_timeline_excludes_intervals', 'pipeline_pause_resume_same_file', 'finish_paused_and_checkpoint_recovery',
            'live_mode_switch_audio_boundaries', 'live_microphone_switch_filters_old_device',
            'paused_mode_change_and_permission_delta', 'trash_synthetic_fixture_and_restore', 'trash_rejects_unsafe_targets',
            'source_clock_glitch_requests_reconnect',
            'pipeline_reconnect_same_timeline', 'microphone_absence_requests_reconnect', 'recording_library_and_metadata',
            'older_session_schema', 'playback_pause_seek_resume_MUTED_SYNTHETIC', 'native_pcm_formats',
            'mix_mono_stereo', 'silence_preserves_time', 'resample_44100_to_48000', 'clipping_and_ring_wrap',
            'duplicate_buffers', 'invalid_audio_and_backlog', 'pre_roll_trim', 'four_hour_timeline_OFFLINE',
            'pcm_segments_to_aac', 'active_segment_crash_recovery', 'missing_segment_preserves_cache',
            'export_retry_new_destination', 'invalid_and_empty_recording', 'four_hour_disk_aac_OFFLINE'}
assert {item['name'] for item in report['results']} == required
assert all(item['status'] == 'passed' for item in report['results'])
assert report['evidence'] == 'synthetic_offline_only_no_microphone_or_system_capture'
subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
with ZipFile(archive_path) as archive:
    assert archive.testzip() is None
    assert all(item.filename.startswith('轻录.app/') and item.flag_bits & 0x800 for item in archive.infolist())
    installed_binary = (app / 'Contents/MacOS/SimpleRecorder').read_bytes()
    assert archive.read('轻录.app/Contents/MacOS/SimpleRecorder') == installed_binary
    for resource in ['AppIcon.png', 'LightRecorder.icns']:
        original = (root / 'Resources' / resource).read_bytes()
        assert (app / 'Contents/Resources' / resource).read_bytes() == original
        assert archive.read('轻录.app/Contents/Resources/' + resource) == original
    assert archive.read('轻录.app/Contents/Resources/TranscribeWorker.py') == (root / 'Resources/TranscribeWorker.py').read_bytes()
    assert '轻录.app/Contents/Resources/FunASREngine/python/bin/python3.11' in archive.namelist()
with tempfile.TemporaryDirectory(prefix='light-recorder-package-check-') as directory:
    subprocess.run(['ditto', '-x', '-k', str(archive_path), directory], check=True)
    extracted = Path(directory) / '轻录.app'
    assert (extracted / 'Contents/MacOS/SimpleRecorder').stat().st_mode & 0o111
    subprocess.run(['codesign', '--verify', '--strict', str(extracted)], check=True)
    # Bundle signing changes the Mach-O signature; compare unsigned temporary copies.
    normalized = []
    for index, source in enumerate([app / 'Contents/MacOS/SimpleRecorder', root / '.build/release/SimpleRecorder']):
        copy = Path(directory) / f'unsigned-{index}'
        shutil.copyfile(source, copy)
        subprocess.run(['codesign', '--remove-signature', str(copy)], check=True)
        data = bytearray(copy.read_bytes())
        # Re-signing can also resize the virtual reservation for __LINKEDIT.
        # Removing a signature does not restore this field; all other bytes must match.
        offset = 32
        for _ in range(struct.unpack_from('<I', data, 16)[0]):
            command, size = struct.unpack_from('<II', data, offset)
            if command == 0x19 and data[offset + 8:offset + 24].rstrip(b'\0') == b'__LINKEDIT':
                struct.pack_into('<Q', data, offset + 32, 0)
            offset += size
        normalized.append(data)
    assert normalized[0] == normalized[1]
with (app / 'Contents/Info.plist').open('rb') as handle:
    identity = plistlib.load(handle)
assert identity['CFBundleIdentifier'] == 'cn.local.lightrecorder'
assert identity['CFBundleShortVersionString'] == '0.5.1'
engine = app / 'Contents/Resources/FunASREngine'
assert (engine / 'python/bin/python3.11').is_file()
assert (engine / '.cache/modelscope/models').is_dir()
subprocess.run(['python3', '-m', 'unittest', 'discover', '-s', 'Tests', '-p', 'TranscriptionWorkerTests.py'], cwd=root, check=True)
paths = [root / 'Package.swift', *sorted((root / 'Sources').rglob('*.swift')),
         *sorted((root / 'Tests').rglob('*.swift')), *sorted((root / 'scripts').glob('*')),
         root / 'Resources/Info.plist', root / 'Resources/LightRecorder.icns', root / 'Resources/AppIcon.png',
         root / 'Resources/TranscribeWorker.py', root / 'Tests/TranscriptionWorkerTests.py']
manifest = {
    'created_at': datetime.now(timezone.utc).isoformat(),
    'evidence': report['evidence'],
    'actual_capture_acceptance': 'pending_user_initiated_recording',
    'installed_app': str(app), 'archive': str(archive_path),
    'version': identity['CFBundleShortVersionString'],
    'offline_checks_passed': len(report['results']),
    'offline_report_note': 'Existing recorder-core synthetic baseline; no new 4-hour recording test implied.',
    'transcription_worker_unit_tests': 'passed',
    'standalone_transcription_runtime': 'included',
    'installed_and_extracted_signatures': 'codesign --verify --strict passed',
    'archive_integrity_and_utf8_names': 'passed',
    'installed_binary_matches_archive': True,
    'installed_binary_matches_current_build_without_signature': True,
    'sha256': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths if p.is_file()},
    'binary_sha256': hashlib.sha256(installed_binary).hexdigest(),
    'archive_sha256': hashlib.sha256(archive_path.read_bytes()).hexdigest(),
}
verification = root / 'docs/verification'
verification.mkdir(exist_ok=True, parents=True)
shutil.copyfile(report_path, verification / 'final-test-report.json')
shutil.copyfile(root / 'artifacts/final-test-run.log', verification / 'final-test-run.log')
(verification / 'release-manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
print('PASS: prior recorder offline baseline, transcription worker checks, installed/extracted signature and bundle consistency.')
print('Actual microphone/system capture remains pending user-started acceptance.')
