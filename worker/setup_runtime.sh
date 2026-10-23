#!/usr/bin/env bash
set -euo pipefail
umask 077
cd -- "$(dirname -- "$0")"
python - <<'PY'
import shutil
if shutil.disk_usage('.').free < 4 * 1024**3:
    raise SystemExit('Need at least 4 GiB free for dependencies, model and 1 GiB input/output reserve')
PY
python -m venv .venv
.venv/bin/python -m pip install --disable-pip-version-check -r requirements.lock
.venv/bin/python runtime.py install-model
.venv/bin/python runtime.py check --load-model

