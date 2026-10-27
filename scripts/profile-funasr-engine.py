#!/usr/bin/env python3
"""Record loaded Python module paths while testing FunASR on a chosen synthetic fixture."""
import argparse
import importlib.util
import json
import sys
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--audio', required=True)
parser.add_argument('--engine-root', required=True)
parser.add_argument('--job-dir', required=True)
parser.add_argument('--audit', required=True)
parser.add_argument('--speaker', action='store_true')
args = parser.parse_args()
worker_file = Path(__file__).resolve().parents[1] / 'Resources/TranscribeWorker.py'
spec = importlib.util.spec_from_file_location('lightrec_worker', worker_file)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)
original = worker.transcribe_pass

def audited(*values, **keywords):
    try:
        return original(*values, **keywords)
    finally:
        modules = {name: getattr(module, '__file__', None) for name, module in sys.modules.items()
                   if getattr(module, '__file__', None)}
        Path(args.audit).write_text(json.dumps(modules, indent=2), encoding='utf-8')

worker.transcribe_pass = audited
sys.argv = [str(worker_file), '--audio', args.audio, '--engine-root', args.engine_root, '--job-dir', args.job_dir]
if args.speaker:
    sys.argv.append('--speaker')
sys.exit(worker.main())
