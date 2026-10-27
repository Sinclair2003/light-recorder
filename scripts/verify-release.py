#!/usr/bin/env python3
"""Read back final offline evidence, installed app, archive and source hashes."""
import hashlib
import json
import plistlib
import shutil
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
with tempfile.TemporaryDirectory(prefix='light-recorder-package-check-') as directory:
    subprocess.run(['ditto', '-x', '-k', str(archive_path), directory], check=True)
    extracted = Path(directory) / '轻录.app'
    assert (extracted / 'Contents/MacOS/SimpleRecorder').stat().st_mode & 0o111
    subprocess.run(['codesign', '--verify', '--strict', str(extracted)], check=True)
with (app / 'Contents/Info.plist').open('rb') as handle:
    identity = plistlib.load(handle)
assert identity['CFBundleIdentifier'] == 'cn.local.lightrecorder'
assert identity['CFBundleShortVersionString'] == '0.3.0'
paths = [root / 'Package.swift', *sorted((root / 'Sources').rglob('*.swift')),
         *sorted((root / 'Tests').rglob('*.swift')), *sorted((root / 'scripts').glob('*')),
         root / 'Resources/Info.plist', root / 'Resources/LightRecorder.icns']
manifest = {
    'created_at': datetime.now(timezone.utc).isoformat(),
    'evidence': report['evidence'],
    'actual_capture_acceptance': 'pending_user_initiated_recording',
    'installed_app': str(app), 'archive': str(archive_path),
    'version': identity['CFBundleShortVersionString'],
    'offline_checks_passed': len(report['results']),
    'installed_and_extracted_signatures': 'codesign --verify --strict passed',
    'archive_integrity_and_utf8_names': 'passed',
    'installed_binary_matches_archive': True,
    'sha256': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths if p.is_file()},
    'binary_sha256': hashlib.sha256(installed_binary).hexdigest(),
    'archive_sha256': hashlib.sha256(archive_path.read_bytes()).hexdigest(),
}
verification = root / 'docs/verification'
verification.mkdir(exist_ok=True, parents=True)
shutil.copyfile(report_path, verification / 'final-test-report.json')
shutil.copyfile(root / 'artifacts/final-test-run.log', verification / 'final-test-run.log')
(verification / 'release-manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
print('PASS: 32 offline checks, installed signature, extracted signature, UTF-8 archive and binary match.')
print('Actual microphone/system capture remains pending user-started acceptance.')
