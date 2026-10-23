#!/usr/bin/env bash
set -euo pipefail
if [ "${EUID}" -ne 0 ]; then
  echo 'Run with sudo bash install-docker-ubuntu.sh' >&2
  exit 1
fi
. /etc/os-release
if [ "${ID}" != ubuntu ] || { [ "${VERSION_ID}" != 24.04 ] && [ "${VERSION_ID}" != 22.04 ]; }; then
  echo 'This installer targets Ubuntu 22.04 or 24.04; inspect this host before proceeding.' >&2
  exit 1
fi
if command -v docker >/dev/null; then
  docker version
  docker compose version
  echo 'Existing Docker detected; no packages or configuration changed.'
  exit 0
fi
for package in docker.io docker-compose docker-compose-v2 podman-docker containerd runc; do
  if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
    echo "Existing container package found: $package. Inspect before making changes." >&2
    exit 1
  fi
done
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
if [ -e /etc/apt/sources.list.d/docker.sources ] || [ -e /etc/apt/sources.list.d/docker.list ]; then
  echo 'An existing Docker apt source needs inspection before this installer can run.' >&2
  exit 1
fi
curl --fail --show-error --silent --location --retry 3 https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
docker version
docker compose version
