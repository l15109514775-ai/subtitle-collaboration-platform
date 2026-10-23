"""Reproducible local runtime setup and non-billable readiness checks.

Uses inherited urllib proxies and default CA trust. Never logs request headers,
environment contents, provider bodies or signed model download URLs.
"""
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import shutil
import ssl
import sys
import urllib.error
import urllib.request

from worker import NoRelayRedirect, digest, read, save

ROOT = Path(__file__).resolve().parent
RESERVE = 1024**3


def install_model():
    lock = read(ROOT / 'model.lock.json')
    destination = Path(lock['destination'])
    # No privilege escalation or alternate model/mirror when provisioning fails.
    destination.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(destination).free < lock['expected_download_bytes_upper_bound'] + RESERVE:
        raise RuntimeError('Insufficient disk: preserve at least 1 GiB for input/output')
    url = f"https://huggingface.co/api/models/{lock['repository']}/revision/{lock['revision']}?blobs=true"
    with urllib.request.urlopen(url, timeout=60) as response:
        metadata = json.loads(response.read(2_000_000))
    if metadata.get('sha') != lock['revision']:
        raise RuntimeError('Model repository revision mismatch')
    siblings = {s['rfilename']: s for s in metadata['siblings']}
    records = []
    for name in lock['files']:
        info = siblings[name]
        size = info.get('size', info.get('lfs', {}).get('size'))
        if not isinstance(size, int) or size <= 0:
            raise RuntimeError('Missing model file size')
        target = destination / name
        partial = target.with_suffix(target.suffix + '.partial')
        if not target.exists():
            if shutil.disk_usage(destination).free < size + RESERVE:
                raise RuntimeError('Insufficient disk for model file plus 1 GiB reserve')
            url = f"https://huggingface.co/{lock['repository']}/resolve/{lock['revision']}/{name}"
            # Public files only; redirects still pass through the managed proxy.
            with urllib.request.urlopen(url, timeout=180) as response, partial.open('wb') as out:
                count = 0
                while block := response.read(4 * 1024**2):
                    count += len(block)
                    if count > size or shutil.disk_usage(destination).free < RESERVE + len(block):
                        raise RuntimeError('Model size/disk safety limit reached')
                    out.write(block)
            partial.replace(target)
        actual = digest(target)
        if target.stat().st_size != size:
            raise RuntimeError('Model file size mismatch; remove invalid file before retry')
        if info.get('lfs'):
            matches = actual == info['lfs']['sha256']
        else:
            blob = b'blob ' + str(size).encode() + b'\0' + target.read_bytes()
            matches = hashlib.sha1(blob).hexdigest() == info['blobId']
        if not matches:
            raise RuntimeError('Model file checksum mismatch; remove invalid file before retry')
        records.append({'name': name, 'bytes': size, 'sha256': actual})
        print(json.dumps({'downloaded_and_verified': name, 'bytes': size}))
    save(destination / 'model-manifest.json', {
        'repository': lock['repository'], 'revision': lock['revision'],
        'files': records, 'total_bytes': sum(r['bytes'] for r in records)})


def model_ready(load=False):
    lock = read(ROOT / 'model.lock.json')
    folder = Path(lock['destination'])
    try:
        manifest = read(folder / 'model-manifest.json')
        if manifest['revision'] != lock['revision'] or manifest['repository'] != lock['repository']:
            return {'ready': False, 'reason': 'model revision mismatch'}
        if {r['name'] for r in manifest['files']} != set(lock['files']):
            return {'ready': False, 'reason': 'model file set mismatch'}
        for record in manifest['files']:
            path = folder / record['name']
            if path.stat().st_size != record['bytes'] or digest(path) != record['sha256']:
                return {'ready': False, 'reason': 'model checksum mismatch'}
        if load:
            from faster_whisper import WhisperModel
            WhisperModel(str(folder), device='cpu', compute_type='int8', cpu_threads=2,
                         num_workers=1, local_files_only=True)
        return {'ready': True, 'revision': manifest['revision'], 'bytes': manifest['total_bytes'],
                'load_verified': load}
    except (OSError, ValueError, KeyError, ImportError):
        return {'ready': False, 'reason': 'model files/runtime missing or invalid'}


def check(load=False, config_path=None):
    packages = {}
    for name in ('faster-whisper', 'ctranslate2', 'av', 'onnxruntime'):
        try:
            packages[name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            packages[name] = None
    result = {'python': sys.version.split()[0], 'dependencies': packages,
              'ffmpeg': bool(shutil.which('ffmpeg')), 'ffprobe': bool(shutil.which('ffprobe')),
              'free_bytes': shutil.disk_usage(ROOT).free,
              'credentials_present': {k: bool(os.environ.get(k)) for k in
                  ('SUBTITLE_GPT_TOKEN', 'SUBTITLE_QWEN_TOKEN', 'DASHSCOPE_API_KEY')},
              'model': model_ready(load)}
    result['local_ready'] = all(packages.values()) and result['ffmpeg'] and result['ffprobe'] and result['model']['ready'] and result['free_bytes'] >= RESERVE
    cfg = read(config_path or ROOT / 'config.example.json')
    try:
        from qwen_asr import readiness
        readiness(cfg)
        result['qwen_configuration_ready'] = True
    except ValueError as error:
        result['qwen_configuration_ready'] = False
        result['qwen_configuration_issue'] = str(error)
    result['billable_execution_enabled'] = bool(cfg.get('billable_execution_approved'))
    result['new_workflow_configuration_ready'] = bool(result['local_ready'] and
        result['credentials_present']['SUBTITLE_GPT_TOKEN'] and result['qwen_configuration_ready'])
    print(json.dumps(result))
    return result['local_ready']


def gpt_models():
    key = os.environ.get('SUBTITLE_GPT_TOKEN')
    if not key:
        print(json.dumps({'credential_present': False})); return False
    opener = urllib.request.build_opener(urllib.request.ProxyHandler(),
        urllib.request.HTTPSHandler(context=ssl.create_default_context()), NoRelayRedirect())
    req = urllib.request.Request('https://text-provider.example.invalid/v1/models',
        headers={'Authorization': 'Bearer ' + key})
    try:
        with opener.open(req, timeout=30) as response:
            data = json.loads(response.read(2_000_000))
            found = any(item.get('id') == 'gpt-6-luna' for item in data.get('data', []))
            print(json.dumps({'http_status': response.status, 'gpt_6_luna_listed': found}))
            return found
    except urllib.error.HTTPError as error:
        print(json.dumps({'http_status': error.code})); return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('install-model', 'check', 'gpt-models'))
    parser.add_argument('--load-model', action='store_true')
    parser.add_argument('--config', help='Private task config for readiness checks; never printed')
    args = parser.parse_args()
    try:
        if args.action == 'install-model': install_model(); return 0
        if args.action == 'gpt-models': return 0 if gpt_models() else 1
        return 0 if check(args.load_model, args.config) else 1
    except Exception as error:
        print(json.dumps({'state': 'blocked', 'error_type': type(error).__name__,
                          'detail': str(error) if type(error) is RuntimeError else 'Check target permissions, approved network policy and configured CA trust'}))
        return 1


if __name__ == '__main__':
    sys.exit(main())

