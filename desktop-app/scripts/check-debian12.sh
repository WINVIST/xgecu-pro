#!/usr/bin/env bash
# Validate the installed packages on Debian 12 without changing the runner's
# network, sandbox, or Docker policy. The disposable container has no USB/FUSE
# devices, Docker socket, additional capabilities, or privileged mode.
set -euo pipefail

if [[ ${GITHUB_ACTIONS:-} != true || $(uname -s) != Linux ]]; then
  echo 'Debian 12 package validation is restricted to Linux GitHub Actions runners.' >&2
  exit 1
fi

workspace=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
host_uid=$(id -u)
host_gid=$(id -g)
if [[ $host_uid == 0 ]]; then
  echo 'Run this validation as the ordinary GitHub Actions runner user.' >&2
  exit 1
fi
node_binary=$(readlink -f -- "$(command -v node)")
driver_binary=$(readlink -f -- "$(command -v tauri-driver)")
[[ -x $node_binary && -x $driver_binary ]]
[[ -f $workspace/desktop-app/node_modules/@wdio/cli/bin/wdio.js ]]
[[ -f $workspace/desktop-app/artifacts/XGecuPro-Linux-x64.deb ]]
[[ -x $workspace/desktop-app/squashfs-root/AppRun ]]
[[ $("$node_binary" -p 'process.versions.node.split(".")[0]') == 24 ]]
command -v docker >/dev/null
docker info >/dev/null

docker run --rm --init --shm-size=256m -i \
  --mount "type=bind,source=$workspace,target=/workspace" \
  --mount "type=bind,source=$node_binary,target=/usr/local/bin/node,readonly" \
  --mount "type=bind,source=$driver_binary,target=/usr/local/bin/tauri-driver,readonly" \
  --env "HOST_UID=$host_uid" --env "HOST_GID=$host_gid" \
  --workdir /workspace/desktop-app debian:12-slim bash -se <<'CONTAINER'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  /workspace/desktop-app/artifacts/XGecuPro-Linux-x64.deb \
  xvfb xauth webkit2gtk-driver ca-certificates fonts-dejavu-core dbus-x11 openbox wmctrl procps

if ! getent group "$HOST_GID" >/dev/null; then
  groupadd --gid "$HOST_GID" xgecu-ci
fi
useradd --uid "$HOST_UID" --gid "$HOST_GID" --create-home --shell /bin/bash xgecu-ci
test "$(runuser -u xgecu-ci -- id -u)" = "$HOST_UID"
test "$(node -p 'process.versions.node.split(".")[0]')" = 24

run_native_tests() {
  local variant=$1 application=$2 appdir=$3
  local result=0
  # WebKit's nested namespace sandbox cannot run with Docker's default
  # isolation. Disable it only for this ephemeral test process, while keeping
  # the container's normal security profile and an unprivileged application UID.
  runuser -u xgecu-ci -- env \
    HOME=/home/xgecu-ci \
    XDG_CACHE_HOME="/home/xgecu-ci/.cache/$variant" \
    XDG_CONFIG_HOME="/home/xgecu-ci/.config/$variant" \
    XDG_DATA_HOME="/home/xgecu-ci/.local/share/$variant" \
    XGECU_E2E_APP="$application" XGECU_E2E_VARIANT="$variant" \
    APPDIR="$appdir" WEBKIT_DMABUF_RENDERER_FORCE_SHM=1 \
    LIBGL_ALWAYS_SOFTWARE=1 \
    WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 \
    bash scripts/run-linux-native.sh || result=$?
  # The shared suite writes its native environment evidence to one fixed name.
  # Preserve a copy for each target alongside its variant-specific screenshots.
  if [[ -f test-results/native-environment.json ]]; then
    runuser -u xgecu-ci -- cp test-results/native-environment.json \
      "test-results/$variant-native-environment.json"
  fi
  if [[ -d test-results/webdriver ]]; then
    runuser -u xgecu-ci -- cp -a test-results/webdriver \
      "test-results/$variant-webdriver"
  fi
  return "$result"
}

run_native_tests Debian12-DEB /usr/bin/XGecuPro ''
run_native_tests Debian12-AppImage /workspace/desktop-app/squashfs-root/AppRun \
  /workspace/desktop-app/squashfs-root
CONTAINER
