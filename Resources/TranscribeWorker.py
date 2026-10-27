#!/usr/bin/env python3
"""Local, opt-in FunASR transcription worker. One process serves one job."""
import argparse
import datetime
import gc
import json
import math
import os
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

PREFIX = 'LIGHTREC_EVENT '
MODEL_NAMES = {
    'asr': 'iic--speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch',
    'vad': 'iic--speech_fsmn_vad_zh-cn-16k-common-pytorch',
    'punc': 'iic--punc_ct-transformer_cn-en-common-vocab471067-large',
    'speaker': 'iic--speech_campplus_sv_zh-cn_16k-common',
}
active_child = None

class Cancelled(Exception):
    pass

def stop_handler(_signum, _frame):
    if active_child and active_child.poll() is None:
        active_child.terminate()
    raise Cancelled()

def emit(kind, **fields):
    print(PREFIX + json.dumps({'kind': kind, **fields}, ensure_ascii=False), flush=True)

def atomic_json(path, value):
    path = Path(path)
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent, prefix='.write-', delete=False) as f:
        name = f.name
        json.dump(value, f, ensure_ascii=False, indent=2)
        f.write('\n')
        f.flush()
        os.fsync(f.fileno())
    os.replace(name, path)

def model_paths(root, diarize):
    base = Path(root) / '.cache' / 'modelscope' / 'models'
    keys = ('asr', 'vad', 'punc', 'speaker') if diarize else ('asr', 'vad', 'punc')
    paths = {key: base / MODEL_NAMES[key] / 'snapshots' / 'master' for key in keys}
    missing = [key for key, path in paths.items()
               if not (path / 'config.yaml').is_file()
               or not (path / ('campplus_cn_common.bin' if key == 'speaker' else 'model.pt')).is_file()]
    if missing:
        raise RuntimeError('本地模型不完整：' + ', '.join(missing) + '。请检查转写环境。')
    return {key: str(value) for key, value in paths.items()}

def clock(ms):
    seconds = max(0, int(ms)) // 1000
    return f'{seconds // 3600:02}:{seconds // 60 % 60:02}:{seconds % 60:02}'

def normalize_result(result, offset_ms, chunk_index, duration_ms, diarize):
    """Convert chunk-local FunASR offsets to recording offsets without joining speaker identities."""
    result = result or {}
    text = str(result.get('text') or '').strip()
    sentences = []
    for sentence in result.get('sentence_info') or []:
        start = max(0, int(sentence.get('start', 0)) + offset_ms)
        end = min(duration_ms, max(start, int(sentence.get('end', 0)) + offset_ms))
        if start > duration_ms:
            continue
        item = {'start_ms': start, 'end_ms': end, 'text': str(sentence.get('text') or sentence.get('sentence') or '').strip()}
        if diarize and sentence.get('spk') is not None:
            spk = sentence['spk']
            label = str(spk + 1) if isinstance(spk, int) else str(spk)
            item['speaker'] = f'片段{chunk_index + 1}·说话人{label}'
        sentences.append(item)
    words = []
    for pair in result.get('timestamp') or result.get('timestamps') or []:
        if not isinstance(pair, (tuple, list)) or len(pair) < 2:
            continue
        start = max(0, int(pair[0]) + offset_ms)
        end = min(duration_ms, max(start, int(pair[1]) + offset_ms))
        if start <= duration_ms:
            words.append([start, end])
    return text, sentences, words

def make_result(audio, fingerprint, duration, count, total, texts, sentences, words, diarize):
    return {'schema': 1, 'audio_file': str(audio), 'duration_seconds': duration,
            'source_size_bytes': fingerprint[0], 'source_mtime_ns': fingerprint[1],
            'completed_chunks': count, 'total_chunks': total, 'complete': count == total,
            'model': 'FunASR Paraformer', 'language': 'zh', 'speaker_labels': diarize,
            'text': '\n'.join(texts), 'sentences': sentences, 'timestamps': words,
            'updated_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}

def chunk_count(frames, sample_rate, chunk_seconds):
    """Avoid a tiny last chunk: merge tails shorter than five seconds into the preceding chunk."""
    chunk_frames = sample_rate * chunk_seconds
    count = math.ceil(frames / chunk_frames)
    remainder = frames % chunk_frames
    if count > 1 and 0 < remainder < min(sample_rate * 5, chunk_frames // 2):
        count -= 1
    return count

def run_conversion(audio, output):
    global active_child
    active_child = subprocess.Popen(['/usr/bin/afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', str(audio), str(output)],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        _, err = active_child.communicate()
        if active_child.returncode != 0:
            raise RuntimeError('无法读取音频：' + err.decode('utf-8', errors='replace')[-600:])
    finally:
        if active_child.poll() is None:
            active_child.terminate()
            try:
                active_child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                active_child.kill()
                active_child.wait()
        active_child = None

def ensure_unchanged(audio, fingerprint):
    stat = audio.stat()
    if (stat.st_size, stat.st_mtime_ns) != fingerprint:
        raise RuntimeError('源音频在转写期间发生变化，请确认文件保存完成后重试。')

def transcribe_pass(audio, pcm, job, paths, chunk_seconds, diarize, fingerprint):
    import soundfile as sf
    from funasr import AutoModel
    emit('status', message='正在加载说话人模型…' if diarize else '正在加载本地模型…')
    config = {'model': paths['asr'], 'vad_model': paths['vad'], 'punc_model': paths['punc'],
              'device': 'cpu', 'ncpu': 2, 'disable_update': True, 'disable_pbar': True}
    if diarize:
        config['spk_model'] = paths['speaker']
    model = AutoModel(**config)
    texts, sentences, words = [], [], []
    prefix = 'speaker' if diarize else 'baseline'
    with sf.SoundFile(str(pcm)) as f:
        if f.samplerate != 16000 or f.channels != 1 or f.frames <= 0:
            raise RuntimeError('音频解码结果无效。')
        duration = f.frames / f.samplerate
        chunk_frames = chunk_seconds * f.samplerate
        total = chunk_count(f.frames, f.samplerate, chunk_seconds)
        for index in range(total):
            ensure_unchanged(audio, fingerprint)
            emit('progress', phase=prefix, completed=index, total=total)
            count = f.frames - index * chunk_frames if index == total - 1 else chunk_frames
            block = f.read(count, dtype='float32')
            chunk = job / 'chunk.wav'
            sf.write(str(chunk), block, f.samplerate, subtype='PCM_16')
            try:
                # Truly silent PCM can make some VAD versions divide by zero.
                # Do not classify merely quiet audio as silence.
                output = [] if hasattr(block, 'any') and not block.any() else model.generate(input=str(chunk), sentence_timestamp=True)
            finally:
                chunk.unlink(missing_ok=True)
            result = output[0] if output else {}
            ensure_unchanged(audio, fingerprint)
            text, additions, offsets = normalize_result(result, index * chunk_seconds * 1000, index, round(duration * 1000), diarize)
            if diarize and text and not any(sentence.get('speaker') for sentence in additions):
                raise RuntimeError('说话人识别没有返回可用标签，普通转写已保留。')
            texts.append(text)
            sentences.extend(additions)
            words.extend(offsets)
            current = make_result(audio, fingerprint, duration, index + 1, total, texts, sentences, words, diarize)
            # A checkpoint is not the final result until the whole pass has committed.
            current['complete'] = False
            atomic_json(job / (prefix + '.partial.json'), current)
            emit('progress', phase=prefix, completed=index + 1, total=total)
    current['complete'] = True
    atomic_json(job / (prefix + '.json'), current)
    del model
    gc.collect()
    return current

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--audio', required=True)
    parser.add_argument('--engine-root', required=True)
    parser.add_argument('--job-dir', required=True)
    parser.add_argument('--speaker', action='store_true')
    parser.add_argument('--chunk-seconds', type=int, default=600)
    args = parser.parse_args()
    if not 1 <= args.chunk_seconds <= 600:
        parser.error('chunk-seconds must be between 1 and 600')
    # Preserve the selected path, including symlinks, so the app can locate its result.
    audio = Path(os.path.abspath(args.audio))
    if not audio.is_file():
        raise RuntimeError('音频文件不存在或不可读取。')
    stat = audio.stat()
    fingerprint = (stat.st_size, stat.st_mtime_ns)
    if stat.st_size == 0:
        raise RuntimeError('音频文件为空。')
    job = Path(args.job_dir).resolve(strict=True)
    pcm = job / 'decoded.wav'
    signal.signal(signal.SIGTERM, stop_handler)
    signal.signal(signal.SIGINT, stop_handler)
    manifest = {'schema': 1, 'audio_file': str(audio), 'speaker_requested': args.speaker,
                'status': 'preparing', 'created_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    atomic_json(job / 'manifest.json', manifest)
    try:
        paths = model_paths(args.engine_root, args.speaker)
        emit('status', message='正在准备音频…')
        run_conversion(audio, pcm)
        ensure_unchanged(audio, fingerprint)
        manifest['status'] = 'baseline'
        atomic_json(job / 'manifest.json', manifest)
        baseline = transcribe_pass(audio, pcm, job, paths, args.chunk_seconds, False, fingerprint)
        if args.speaker and baseline['text'].strip():
            manifest['status'] = 'speaker'
            atomic_json(job / 'manifest.json', manifest)
            transcribe_pass(audio, pcm, job, paths, args.chunk_seconds, True, fingerprint)
        manifest['status'] = 'complete'
        atomic_json(job / 'manifest.json', manifest)
        emit('done', empty=not bool(baseline['text'].strip()))
    except Cancelled:
        manifest['status'] = 'cancelled'
        atomic_json(job / 'manifest.json', manifest)
        emit('cancelled')
        return 130
    except Exception as exc:
        manifest['status'] = 'failed'
        manifest['error'] = str(exc)
        atomic_json(job / 'manifest.json', manifest)
        emit('error', message=str(exc))
        return 1
    finally:
        pcm.unlink(missing_ok=True)
        (job / 'chunk.wav').unlink(missing_ok=True)
    return 0

if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as exc:
        emit('error', message=str(exc))
        sys.exit(1)
