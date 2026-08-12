#!/bin/bash

# Check this repository against the rules the Omarchy plugin marketplace
# applies when it builds its catalog.
#
# `omarchy plugin validate` covers what the *shell* needs to load a plugin. It
# says nothing about what the *marketplace* needs to list one: a root README,
# a root license, lowercase ids, and field lengths. Those are enforced in the
# marketplace's build-catalog.mjs, and a repo can pass the first check and be
# rejected by the second. This covers the gap, so a listing failure shows up
# on a pull request rather than at submission.
#
# Run it anywhere: ./.github/scripts/marketplace-check.sh

set -uo pipefail

cd "$(dirname -- "${BASH_SOURCE[0]}")/../.." || exit 1

MANIFEST="manifest.json"
failures=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; failures=$((failures + 1)); }
note() { printf '  \033[33mNOTE\033[0m  %s\n' "$1"; }

check() {
  local label="$1" condition="$2"
  if [[ $condition == "true" ]]; then pass "$label"; else fail "$label"; fi
}

echo "Marketplace listing checks"

if [[ ! -f $MANIFEST ]]; then
  fail "manifest.json exists at the repository root"
  exit 1
fi
jq -e . "$MANIFEST" >/dev/null 2>&1 || { fail "manifest.json is valid JSON"; exit 1; }

check "manifest.json is valid JSON" true
check "schemaVersion is exactly 1" \
  "$(jq -r '.schemaVersion == 1' "$MANIFEST")"

# Required strings, non-empty and free of control characters.
for field in id name version author description; do
  check "$field is a non-empty string without control characters" \
    "$(jq -r --arg f "$field" '
      (.[$f] | type) == "string"
        and ((.[$f] | gsub("^\\s+|\\s+$"; "")) | length) > 0
        # Codepoints, not a regex: jq matches with Oniguruma, which spells
        # unicode escapes \x{..} and reads \u as a literal "u".
        and ((.[$f] | explode | any(. < 32 or (. >= 127 and . <= 159))) | not)
    ' "$MANIFEST")"
done

# Length ceilings, from manifestFieldLimits in build-catalog.mjs.
while read -r field limit; do
  actual=$(jq -r --arg f "$field" '(.[$f] // "") | length' "$MANIFEST")
  check "$field is ${actual}/${limit} characters" \
    "$([[ $actual -le $limit ]] && echo true || echo false)"
done <<'LIMITS'
id 128
name 120
version 64
author 120
description 500
license 120
LIMITS

# Community ids must be lowercase and outside the reserved namespace.
check "id is lowercase, well formed, and not in the omarchy.* namespace" \
  "$(jq -r '
    (.id | test("^[a-z0-9][a-z0-9._-]*$"))
      and ((.id | contains("..")) | not)
      and ((.id | startswith("omarchy.")) | not)
  ' "$MANIFEST")"

check "kinds is a non-empty array of supported values" \
  "$(jq -r '
    (.kinds | type) == "array" and (.kinds | length) > 0
      and (.kinds | all(. as $k |
        ["bar","bar-widget","menu","overlay","panel","service"] | index($k) != null))
  ' "$MANIFEST")"

# Every declared kind needs the entry point the shell looks for it under.
while read -r kind key; do
  jq -e --arg k "$kind" '(.kinds | index($k)) != null' "$MANIFEST" >/dev/null 2>&1 || continue
  check "kind '$kind' declares entryPoints.$key" \
    "$(jq -r --arg key "$key" '(.entryPoints | has($key))' "$MANIFEST")"
done <<'KINDS'
bar bar
bar-widget barWidget
menu menu
overlay overlay
panel panel
service service
KINDS

while read -r entry; do
  [[ -n $entry ]] || continue
  ok=true
  [[ $entry == /* ]] && ok=false
  [[ $entry == *".."* ]] && ok=false
  [[ -f $entry ]] || ok=false
  check "entry point '$entry' is a safe relative path that exists" "$ok"
done < <(jq -r '.entryPoints // {} | .[]' "$MANIFEST")

# Omarchy's bar reserves three keys on a widget's config entry, and `source` is
# the dangerous one: BarModel.js reads any entry carrying it as "load this
# widget from a custom QML file at this path". A setting of that name therefore
# points the bar's Loader at a file that does not exist, and the widget
# disappears with no error naming the cause. Worse, the offending value lives
# in the user's shell.json rather than in the plugin, so reverting the plugin
# does not bring the widget back. Caught here, where a name is cheap to change.
for reserved in source exec type; do
  in_defaults=$(jq -r --arg k "$reserved" '(.barWidget.defaults // {}) | has($k)' "$MANIFEST")
  in_schema=$(jq -r --arg k "$reserved" '[(.barWidget.schema // [])[].key] | index($k) != null' "$MANIFEST")
  check "no settings key named '$reserved' (reserved by Omarchy's bar)" \
    "$([[ $in_defaults == false && $in_schema == false ]] && echo true || echo false)"
done

# Root documentation. The marketplace rejects a repo missing either.
check "a root README exists" \
  "$(ls -1 | grep -qiE '^readme(\..+)?$' && echo true || echo false)"
check "a root license file exists" \
  "$(ls -1 | grep -qiE '^(licen[cs]e|copying)(\..+)?$' && echo true || echo false)"

# The preview is optional; without one the marketplace substitutes its own.
if ls -1 | grep -qiE '^preview\.(png|jpe?g|webp|avif)$'; then
  pass "a root preview image exists"
else
  note "no root preview — the marketplace will use its fallback image"
fi

# Symlinks are refused anywhere in a plugin folder: once installed, one could
# point at arbitrary files on disk.
link=$(find . -name .git -prune -o -type l -print -quit 2>/dev/null)
check "no symlinks anywhere in the repository" \
  "$([[ -z $link ]] && echo true || echo "false ($link)")"

echo
if (( failures )); then
  echo "$failures check(s) failed — this repository would be rejected for listing."
  exit 1
fi
echo "All marketplace listing checks passed."
