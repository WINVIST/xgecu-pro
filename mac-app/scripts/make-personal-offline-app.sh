#!/bin/bash
# Package an operator-owned XGecu database into a private copy of the app.
# Run on macOS after the official database was downloaded once. Do not upload
# the resulting app to a public release.
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 SOURCE.app PERSONAL.app [EXTRACTED_DATABASE_DIR]" >&2
  exit 2
fi

source_app=$1
personal_app=$2
database_dir=${3:-"$HOME/Library/Caches/minipro/xgpro-pinned-v1321"}

if [[ ! -d "$source_app/Contents/Resources" || ! -x "$source_app/Contents/Resources/minipro" ]]; then
  echo "Source is not a built XGecuPro.app with its minipro helper." >&2
  exit 1
fi
if [[ -e "$personal_app" || -L "$personal_app" ]]; then
  echo "Personal app destination already exists; choose a new path." >&2
  exit 1
fi
source_absolute=$(cd -P "$source_app" && pwd)
destination_parent=$(cd -P "$(dirname "$personal_app")" && pwd)
destination_absolute="$destination_parent/$(basename "$personal_app")"
if [[ "$destination_absolute" == "$source_absolute/"* ]]; then
  echo "Personal app destination must be outside the source app." >&2
  exit 1
fi
if [[ ! -f "$database_dir/InfoICT76.dll" ]]; then
  echo "No InfoICT76.dll at $database_dir" >&2
  exit 1
fi
if [[ ! -d "$database_dir/algoT76" && ! -f "$database_dir/algorithm.xml" ]]; then
  echo "No algoT76 directory or algorithm.xml next to InfoICT76.dll." >&2
  exit 1
fi

"$source_app/Contents/Resources/minipro" --json --db "$database_dir" \
  describe MX66L1G45G@SOIC16 >/dev/null

ditto "$source_app" "$personal_app"
resources="$personal_app/Contents/Resources"
mkdir "$resources/ChipDatabase"
ditto "$database_dir/InfoICT76.dll" "$resources/ChipDatabase/InfoICT76.dll"
if [[ -d "$database_dir/algoT76" ]]; then
  ditto "$database_dir/algoT76" "$resources/ChipDatabase/algoT76"
fi
if [[ -f "$database_dir/algorithm.xml" ]]; then
  ditto "$database_dir/algorithm.xml" "$resources/ChipDatabase/algorithm.xml"
fi

codesign --force --sign - --timestamp=none "$personal_app"
codesign --verify --deep --strict --verbose=2 "$personal_app"
"$resources/minipro" --json --db "$resources/ChipDatabase" \
  describe MX66L1G45G@SOIC16 >/dev/null
echo "Personal offline app ready: $personal_app"
