import importlib.util
import json
import os
import sys
import subprocess
import tempfile
import types
import unittest
import wave
from pathlib import Path
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1] / 'Resources/TranscribeWorker.py'
spec = importlib.util.spec_from_file_location('transcribe_worker', SOURCE)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)

class FakeSoundFile:
    def __init__(self, path):
        self.input = wave.open(path, 'rb')
        self.samplerate = self.input.getframerate()
        self.channels = self.input.getnchannels()
        self.frames = self.input.getnframes()
    def __enter__(self): return self
    def __exit__(self, *_): self.input.close()
    def read(self, count, dtype=None): return self.input.readframes(count)

def fake_write(path, samples, rate, subtype=None):
    with wave.open(path, 'wb') as f:
        f.setnchannels(1); f.setsampwidth(2); f.setframerate(rate); f.writeframes(samples)

class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='lightrec-beta-test-')
        self.root = Path(self.temp.name)
        self.audio = self.root / 'original.m4a'
        self.audio.write_bytes(b'original content')
        self.before = self.audio.read_bytes()
        self.pcm = self.root / 'decoded.wav'
        with wave.open(str(self.pcm), 'wb') as f:
            f.setnchannels(1); f.setsampwidth(2); f.setframerate(16000)
            f.writeframes(b'\0\0' * (16000 * 6 + 16))
        stat = self.audio.stat()
        self.fingerprint = (stat.st_size, stat.st_mtime_ns)
        self.paths = {'asr': 'a', 'vad': 'v', 'punc': 'p', 'speaker': 's'}
    def tearDown(self): self.temp.cleanup()
    def run_pass(self, model, diarize=False):
        fake_sf = types.SimpleNamespace(SoundFile=FakeSoundFile, write=fake_write)
        fake_fun = types.SimpleNamespace(AutoModel=lambda **_: model)
        with mock.patch.dict(sys.modules, {'soundfile': fake_sf, 'funasr': fake_fun}):
            return worker.transcribe_pass(self.audio, self.pcm, self.root, self.paths, 3, diarize, self.fingerprint)
    def test_merge_short_tail(self):
        self.assertEqual(worker.chunk_count(16000 * 6 + 16, 16000, 3), 2)
        self.assertEqual(worker.chunk_count(16000 * 12, 16000, 3), 4)
        self.assertEqual(worker.chunk_count(16000, 16000, 600), 1)
    def test_timestamps_are_global_and_source_is_preserved(self):
        class Model:
            def generate(self, **_):
                return [{'text': '文字', 'timestamp': [[0, 1000]], 'sentence_info': [{'text': '文字', 'start': 0, 'end': 1000}]}]
        result = self.run_pass(Model())
        self.assertTrue(result['complete'])
        self.assertEqual(result['completed_chunks'], 2)
        self.assertEqual(result['timestamps'], [[0, 1000], [3000, 4000]])
        self.assertEqual([s['start_ms'] for s in result['sentences']], [0, 3000])
        self.assertEqual(self.audio.read_bytes(), self.before)
        self.assertFalse((self.root / 'chunk.wav').exists())
    def test_failure_preserves_partial_and_never_marks_complete(self):
        class Model:
            def __init__(self): self.calls = 0
            def generate(self, **_):
                self.calls += 1
                if self.calls == 2: raise RuntimeError('simulated model failure')
                return [{'text': '第一段', 'timestamp': [[0, 900]]}]
        with self.assertRaises(RuntimeError): self.run_pass(Model())
        result = json.loads((self.root / 'baseline.partial.json').read_text())
        self.assertEqual(result['completed_chunks'], 1)
        self.assertFalse(result['complete'])
        self.assertFalse((self.root / 'baseline.json').exists())
        self.assertFalse((self.root / 'chunk.wav').exists())
        self.assertEqual(self.audio.read_bytes(), self.before)
    def test_changed_source_is_rejected_without_a_completed_result(self):
        audio = self.audio
        class Model:
            def generate(self, **_):
                audio.write_bytes(b'externally replaced')
                return [{'text': '文字'}]
        with self.assertRaisesRegex(RuntimeError, '源音频'): self.run_pass(Model())
        self.assertFalse((self.root / 'baseline.json').exists())
    def test_speaker_labels_are_scoped_to_each_chunk(self):
        class Model:
            def generate(self, **_):
                return [{'text': '文字', 'sentence_info': [{'text': '文字', 'start': 0, 'end': 900, 'spk': 0}]}]
        result = self.run_pass(Model(), diarize=True)
        self.assertEqual([s['speaker'] for s in result['sentences']], ['片段1·说话人1', '片段2·说话人1'])
        self.assertEqual(self.audio.read_bytes(), self.before)
    def test_truly_silent_pcm_finishes_without_inference(self):
        class SilentBlock(bytes):
            def any(self): return False
        class SilentFile(FakeSoundFile):
            def read(self, count, dtype=None): return SilentBlock(super().read(count, dtype=dtype))
        class Model:
            def generate(self, **_): raise AssertionError('silent audio must not invoke VAD')
        fake_sf = types.SimpleNamespace(SoundFile=SilentFile, write=fake_write)
        fake_fun = types.SimpleNamespace(AutoModel=lambda **_: Model())
        with mock.patch.dict(sys.modules, {'soundfile': fake_sf, 'funasr': fake_fun}):
            result = worker.transcribe_pass(self.audio, self.pcm, self.root, self.paths, 3, False, self.fingerprint)
        self.assertTrue(result['complete'])
        self.assertEqual(result['text'].strip(), '')
        self.assertEqual(self.audio.read_bytes(), self.before)

    def test_engine_builder_packages_required_models_without_sample_audio(self):
        engine = self.root / 'engine'
        site = engine / '.venv/lib/python3.11/site-packages'
        (site / 'funasr').mkdir(parents=True)
        module = site / 'funasr/__init__.py'
        module.write_text('name = "fixture"\n')
        helper = site / 'torch/bin/torch_shm_manager'
        helper.parent.mkdir(parents=True)
        helper.write_text('fixture')
        for kind, name in worker.MODEL_NAMES.items():
            model = engine / '.cache/modelscope/models' / name / 'snapshots/master'
            model.mkdir(parents=True)
            (model / 'config.yaml').write_text('fixture')
            (model / ('campplus_cn_common.bin' if kind == 'speaker' else 'model.pt')).write_text('fixture')
            (model / 'sample.wav').write_bytes(b'not for distribution')
        standalone = self.root / 'python'
        (standalone / 'bin').mkdir(parents=True)
        interpreter = standalone / 'bin/python3.11'
        interpreter.write_text('#!/bin/sh\nexit 0\n')
        interpreter.chmod(0o755)
        audit = self.root / 'audit.json'
        audit.write_text(json.dumps({'funasr': str(module)}))
        output = self.root / 'portable'
        script = SOURCE.parents[1] / 'scripts/prepare-funasr-engine.py'
        command = [sys.executable, str(script), '--python-root', str(standalone), '--source-engine', str(engine),
                   '--module-audit', str(audit), '--output', str(output), '--jobs', '2']
        subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
        self.assertTrue((output / 'python/lib/python3.11/site-packages/funasr/__init__.py').is_file())
        self.assertTrue((output / '.cache/modelscope/models' / worker.MODEL_NAMES['speaker'] / 'snapshots/master/campplus_cn_common.bin').is_file())
        self.assertFalse(list(output.rglob('*.wav')))
        self.assertNotEqual(subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode, 0)

    def test_speaker_pass_without_labels_does_not_claim_success(self):
        class Model:
            def generate(self, **_): return [{'text': '文字', 'sentence_info': [{'text': '文字', 'start': 0, 'end': 900}]}]
        with self.assertRaisesRegex(RuntimeError, '没有返回可用标签'):
            self.run_pass(Model(), diarize=True)
        self.assertFalse((self.root / 'speaker.json').exists())

if __name__ == '__main__':
    unittest.main()
