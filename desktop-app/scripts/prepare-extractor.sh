#!/usr/bin/env bash
set -euo pipefail
app=$(cd "$(dirname "$0")/.." && pwd)
stage="$app/src-tauri/resources/extractor"
mkdir -p "$stage/lib" "$stage/notices"
cp /usr/bin/bsdtar "$stage/bsdtar"
chmod 755 "$stage/bsdtar"
while IFS= read -r lib; do
  name=$(basename "$lib")
  case "$name" in libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|ld-linux*) continue ;; esac
  cp -L "$lib" "$stage/lib/$name"
  # ldd may name /lib aliases on merged-/usr systems. Dpkg owns the real path.
  real=$(readlink -f "$lib")
  owner=$(dpkg-query -S "$real" 2>/dev/null || dpkg-query -S "$lib")
  package=$(printf '%s\n' "$owner" | head -1 | cut -d: -f1)
  test -n "$package"
  test -s "/usr/share/doc/$package/copyright"
  cp "/usr/share/doc/$package/copyright" "$stage/notices/$package.txt"
done < <(ldd /usr/bin/bsdtar | awk '$3 ~ /^\// {print $3}')
cp /usr/share/doc/libarchive-tools/copyright "$stage/notices/libarchive-tools.txt"
test -s "$stage/lib/libarchive.so.13"
LD_LIBRARY_PATH="$stage/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$stage/bsdtar" --version
