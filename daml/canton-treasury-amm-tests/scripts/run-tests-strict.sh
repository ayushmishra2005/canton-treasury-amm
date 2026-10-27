#!/usr/bin/env bash
# Runs `dpm test` and fails unless every top-level non-function `Script` declaration in the test
# package ran and passed, so a skipped, renamed or silently dropped test cannot go unnoticed.
# Writes the full test log to the path in $1 (default: a temporary file). With a test module
# path relative to the package (such as daml/CantonTreasuryAmm/Test/Migration.daml) in $2, runs
# and checks that module's declarations.
set -euo pipefail
# The SDK every daml.yaml pins; outside a package directory dpm would resolve its own default.
export DPM_SDK_VERSION=3.5.5

cd "$(dirname "$0")/.."
log=${1:-$(mktemp)}
scope=${2:-daml}

if [ "$scope" = daml ]; then
  dpm test > "$log" 2>&1 || { cat "$log"; echo "dpm test failed; log: $log" >&2; exit 1; }
else
  [ -f "$scope" ] || { echo "No test module $scope" >&2; exit 1; }
  dpm test --files "$scope" > "$log" 2>&1 || { cat "$log"; echo "dpm test failed; log: $log" >&2; exit 1; }
fi

declared=$(grep -rHoE --include='*.daml' "^[a-z][A-Za-z0-9_']* : Script [^-]*$" "$scope" \
  | sed -E "s#^(daml/[^:]+):([A-Za-z0-9_']+) : .*#\1:\2#" | LC_ALL=C sort)
passed=$(grep -oE "^daml/[^:]+:[A-Za-z0-9_']+: ok," "$log" | sed 's#: ok,$##' | LC_ALL=C sort)
if [ "$scope" != daml ]; then
  # `dpm test --files` also runs the modules the given one imports; a failure there still fails
  # the run above, but only the given module's declarations are compared.
  passed=$(echo "$passed" | grep -F "$scope:") || { echo "No test in $scope passed; log: $log" >&2; exit 1; }
fi

if grep -qE "^daml/[^:]+:[A-Za-z0-9_']+: failed" "$log"; then
  grep -E "^daml/[^:]+:[A-Za-z0-9_']+: failed" "$log" >&2
  echo "Failing tests reported; log: $log" >&2
  exit 1
fi
if [ "$declared" != "$passed" ]; then
  echo "Declared and passed tests differ (< declared only, > passed only); log: $log" >&2
  diff <(echo "$declared") <(echo "$passed") >&2 || exit 1
fi
echo "All $(echo "$passed" | wc -l | tr -d ' ') declared tests ran and passed; log: $log"
