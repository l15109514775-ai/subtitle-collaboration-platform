#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
command -v docker >/dev/null || { echo 'Docker is required. Install from https://docs.docker.com/engine/install/ubuntu/ first.' >&2; exit 1; }
docker compose version >/dev/null
mkdir -p data
chmod 700 data
docker compose config --quiet
docker compose pull
docker compose up -d
for attempt in $(seq 1 60); do
  if curl --fail --silent --output /dev/null http://127.0.0.1:6185/; then
    echo 'AstrBot is responding on 127.0.0.1:6185. Connect using an SSH tunnel.'
    exit 0
  fi
  sleep 5
done
echo 'Dashboard did not become ready. Inspect: docker compose logs --tail 100' >&2
exit 1
