#!/usr/bin/env bash
# Run native WebKit QA in its own display, session bus and window manager.
# The installed application and all WebDriver assertions remain unchanged.
set -euo pipefail

if [[ $(uname -s) != Linux || $(id -u) == 0 ]]; then
  echo 'Native Linux QA must run as an ordinary Linux user.' >&2
  exit 1
fi

app_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd -- "$app_directory"
for dependency in node xvfb-run dbus-run-session openbox wmctrl timeout ps tee tr mktemp; do
  command -v "$dependency" >/dev/null || {
    echo "Missing native QA dependency: $dependency" >&2
    exit 1
  }
done

if [[ ${1:-} == --display-session ]]; then
  [[ $# == 2 && -n ${DISPLAY:-} && -n ${DBUS_SESSION_BUS_ADDRESS:-} ]] || {
    echo 'The native display session was not initialized.' >&2
    exit 1
  }
  run_directory=$2
  [[ $run_directory == "$app_directory/test-results/native-display/"* && -d $run_directory ]] || {
    echo 'Invalid native QA log directory.' >&2
    exit 1
  }
  wm_pid=''
  cleanup() {
    local result=$?
    trap - EXIT INT TERM
    if [[ -n $wm_pid ]]; then
      # Only the Openbox process started by this shell is eligible for cleanup.
      if [[ $(ps -o ppid= -p "$wm_pid" 2>/dev/null | tr -d ' ') == "$$" ]]; then
        kill -TERM "$wm_pid" 2>/dev/null || true
      fi
      wait "$wm_pid" 2>/dev/null || true
    fi
    return "$result"
  }
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  openbox --sm-disable >"$run_directory/openbox.log" 2>&1 &
  wm_pid=$!
  if ! timeout 5s bash -c '
    while :; do
      information=$(wmctrl -m 2>&1) || { sleep 0.1; continue; }
      case "$information" in
        *"Name: Openbox"*) printf "%s\n" "$information"; exit 0 ;;
      esac
      sleep 0.1
    done
  ' >"$run_directory/window-manager.log" 2>&1; then
    echo 'Openbox did not become ready within 5 seconds.' >&2
    cat "$run_directory/openbox.log" "$run_directory/window-manager.log" >&2
    exit 1
  fi
  printf 'Native QA display=%s; private session bus ready; Openbox PID=%s\n' "$DISPLAY" "$wm_pid"
  cat "$run_directory/window-manager.log"
  result=0
  node node_modules/@wdio/cli/bin/wdio.js run wdio.conf.mjs \
    2>&1 | tee "$run_directory/webdriver.log" || result=$?
  exit "$result"
fi

[[ $# == 0 ]] || { echo 'This script takes no arguments.' >&2; exit 1; }
variant=${XGECU_E2E_VARIANT:-installed}
[[ $variant =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'Invalid native QA variant.' >&2; exit 1; }
mkdir -p -- test-results/native-display
run_directory=$(mktemp -d "$app_directory/test-results/native-display/${variant}-XXXXXX")
printf 'Native QA session logs: %s\n' "$run_directory"
result=0
xvfb-run -a --error-file="$run_directory/xvfb.log" \
  --server-args='-screen 0 1600x1200x24 -nolisten tcp' \
  dbus-run-session -- bash "$app_directory/scripts/run-linux-native.sh" \
  --display-session "$run_directory" 2>&1 | tee "$run_directory/session.log" || result=$?
exit "$result"
