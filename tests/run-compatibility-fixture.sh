#!/bin/bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_home=$(mktemp -d)
trap 'rm -rf "$test_home"' EXIT
mkdir -p "$test_home/.config/omarchy"
printf '%s' '{"version":1,"bar":{"layout":{"left":[{"id":"matjam.omajam","source":"bar"}]}},"plugins":[{"id":"matjam.omajam","source":"service"}]}' > "$test_home/.config/omarchy/shell.json"

set +e
OMAJAM_TEST_DIR="$test_home" QT_QPA_PLATFORM=offscreen timeout 20s qs --path "$repo_dir/CompatibilityFixture.qml" >"$test_home/qs.log" 2>&1
qs_status=$?
set -e

if [[ ! -f $test_home/result || $(<"$test_home/result") != PASS ]]; then
  cat "$test_home/qs.log" >&2
  exit 1
fi
[[ $qs_status -eq 143 ]]
