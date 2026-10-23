"""List staged source hashes without machine paths or private provenance.

Run after staging source changes, then stage SOURCE_MANIFEST.json itself.
The manifest excludes itself to avoid circular hashes.
"""
import hashlib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
raw = subprocess.check_output(['git', 'ls-files', '-s', '-z'], cwd=ROOT)
files = []
for entry in raw.split(b'\0'):
    if not entry:
        continue
    metadata, path_bytes = entry.split(b'\t', 1)
    mode, blob, stage = metadata.decode().split()
    path = path_bytes.decode('utf8')
    if path == 'SOURCE_MANIFEST.json':
        continue
    if stage != '0':
        raise SystemExit('Resolve merge conflicts before creating a manifest')
    content = subprocess.check_output(['git', 'cat-file', 'blob', blob], cwd=ROOT)
    files.append({'path': path, 'component': path.split('/')[0] if '/' in path else 'project',
                  'bytes': len(content), 'sha256': hashlib.sha256(content).hexdigest(),
                  'git_blob_sha': blob})
document = {'schema': 1, 'scope': 'Staged source files; excludes this manifest and all ignored/private files.',
            'hash_basis': 'Git blob content with repository line endings', 'files': files}
(ROOT/'SOURCE_MANIFEST.json').write_text(json.dumps(document, ensure_ascii=False, indent=2)+'\n', encoding='utf8')
print(f'Manifest written for {len(files)} staged source files')
