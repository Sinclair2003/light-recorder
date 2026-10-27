#!/usr/bin/env python3
"""Assemble a macOS arm64 Python/FunASR runtime from a verified local environment."""
import argparse
import concurrent.futures
import importlib.util
import json
import os
import shutil
import stat
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--python-root', required=True, help='Relocatable Python 3.11 distribution directory')
parser.add_argument('--source-engine', required=True, help='Existing FunASR directory with .venv and model cache')
parser.add_argument('--module-audit', required=True, help='JSON from profile-funasr-engine.py')
parser.add_argument('--output', required=True, help='New directory to create')
parser.add_argument('--jobs', type=int, default=16)
args = parser.parse_args()
python_source = Path(args.python_root).resolve(strict=True)
engine_source = Path(args.source_engine).resolve(strict=True)
audit = json.loads(Path(args.module_audit).read_text(encoding='utf-8'))
output = Path(args.output).absolute()
if output.exists():
    raise SystemExit('Output already exists; choose a new directory.')
site = engine_source / '.venv/lib/python3.11/site-packages'
models = engine_source / '.cache/modelscope/models'
worker_spec = importlib.util.spec_from_file_location('lightrec_worker', Path(__file__).resolve().parents[1] / 'Resources/TranscribeWorker.py')
worker = importlib.util.module_from_spec(worker_spec)
worker_spec.loader.exec_module(worker)
if not (python_source / 'bin/python3.11').is_file() or not site.is_dir() or not models.is_dir():
    raise SystemExit('Python distribution, FunASR packages or model cache is missing.')
worker.model_paths(engine_source, diarize=True)
if not 1 <= args.jobs <= 32:
    raise SystemExit('--jobs must be between 1 and 32.')
output.mkdir(parents=True)
subprocess.run(['/usr/bin/ditto', '--norsrc', '--noextattr', str(python_source), str(output / 'python')], check=True)
target = output / 'python/lib/python3.11/site-packages'
selected = set()
for filename in audit.values():
    if not isinstance(filename, str):
        continue
    try:
        selected.add(Path(filename).resolve(strict=True).relative_to(site.resolve()))
    except (OSError, ValueError):
        continue
if not selected:
    raise SystemExit('Module audit does not reference the selected FunASR environment.')
packages = {p.parts[0] for p in selected}
exclude = {'test', 'tests', 'testing', 'SelfTest', '__pycache__', 'examples', 'example_data', 'benchmarks', 'include', 'cmake', 'doc', 'docs'}
resources = {'.so', '.dylib', '.json', '.yaml', '.yml', '.txt', '.cfg', '.ini', '.dict', '.pem', '.csv', '.model', '.tiktoken', '.bpe', '.bin', '.pyi', '.css', '.js', '.html'}
for name in packages:
    folder = site / name
    if not folder.is_dir():
        continue
    for item in folder.rglob('*'):
        relative = item.relative_to(site)
        if not any(part in exclude for part in relative.parts) and item.is_file() and item.suffix.lower() in resources:
            selected.add(relative)
for name in ('torch', 'torchaudio', 'funasr', 'numpy', 'scipy', 'sympy', 'sklearn', 'numba'):
    for item in (site / name).rglob('*.py'):
        relative = item.relative_to(site)
        if not any(part in exclude for part in relative.parts):
            selected.add(relative)
selected.add(Path('torch/bin/torch_shm_manager'))
for metadata in site.glob('*.dist-info'):
    for item in metadata.rglob('*'):
        if item.is_file() and (item.name in ('METADATA', 'entry_points.txt', 'top_level.txt', 'WHEEL')
                               or item.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE'))):
            selected.add(item.relative_to(site))
items = [(site / relative, target / relative) for relative in selected if (site / relative).is_file()]
for name in worker.MODEL_NAMES.values():
    model = models / name
    folder = model / 'snapshots/master'
    if not folder.is_dir():
        continue
    for item in folder.iterdir():
        if item.is_file() and item.suffix.lower() not in ('.wav', '.mp3', '.png', '.jpg'):
            items.append((item, output / '.cache/modelscope/models' / model.name / 'snapshots/master' / item.name))

def copy(pair):
    src, dst = pair
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dst)
    os.chmod(dst, stat.S_IMODE(src.stat().st_mode))
    return 1

print(f'Copying {len(items)} runtime and model files...', flush=True)
with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
    for count, _ in enumerate(pool.map(copy, items), 1):
        if count % 1000 == 0:
            print(f'Copied {count}/{len(items)}', flush=True)
subprocess.run([str(output / 'python/bin/python3.11'), '-m', 'compileall', '-q', '-j', '2',
                '--invalidation-mode', 'checked-hash', '-s', str(output / 'python'), str(target)], check=True)
print('Prepared:', output)
