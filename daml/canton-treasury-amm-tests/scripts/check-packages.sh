#!/usr/bin/env bash
# Package integrity for the deployable DARs, run after `dpm build --all`:
# - the legacy package keeps the ID of the deployed legacy release, so existing contracts stay
#   bound to it and an upload of this build is a no-op next to it;
# - Secure V1 is a separate package that depends on exactly that legacy package, and its version
#   and ID are the reviewed ones (any source change, including a comment, changes the ID and
#   needs review). 0.2.0 is the upgrade successor of 0.1.0
#   (e4546c3f60ef59f07edb4ad1c61676ed46fe66eb8c998a1277aa29bc43b958c8, the Stage 3.1 commit);
#   that check needs the 0.1.0 DAR rebuilt from history and is recorded in RELEASE_READINESS.md;
# - neither deployable DAR depends on daml-script, and the type-level upgrade check passes;
# - the vendored Token Standard DARs in lib/ have the package IDs listed in README.md.
set -euo pipefail
# The SDK every daml.yaml pins; outside a package directory dpm would resolve its own default.
export DPM_SDK_VERSION=3.5.5

cd "$(dirname "$0")/../.."

legacy_id=d8cadd3c038655678a71e052616b054a07ad53600e2feb719456f629c2772aa6
secure_id=4abe290579f46ac931b72106e64d99f5c659708d3636b2698d115609ad81a2a9
legacy_dar=canton-treasury-amm/.daml/dist/canton-treasury-amm-0.1.0.dar
secure_dar=canton-treasury-amm-secure-v1/.daml/dist/canton-treasury-amm-secure-v1-0.2.0.dar
prototype_dar=canton-treasury-amm-live-reserve-prototype/.daml/dist/canton-treasury-amm-live-reserve-prototype-0.1.0.dar

check_dar() {
  local dar=$1 name=$2 version=$3 main_id=$4
  dpm damlc inspect-dar "$dar" --json | python3 -c '
import json, sys
dar, name, version, main_id, legacy_id = sys.argv[1:]
info = json.load(sys.stdin)
packages = info["packages"]
actual_id = info["main_package_id"]
main_name, main_version = packages[actual_id]["name"], packages[actual_id]["version"]
problems = []
if (main_name, main_version) != (name, version):
    problems.append(f"main package is {main_name} {main_version}")
if main_id != "-" and actual_id != main_id:
    problems.append(f"main package ID {actual_id} is not the reviewed {main_id}")
legacy = [pid for pid, p in packages.items() if p.get("name") == "canton-treasury-amm"]
if legacy != [legacy_id]:
    problems.append(f"canton-treasury-amm resolves to {legacy}, not {legacy_id}")
script = sorted({p.get("name") for p in packages.values() if str(p.get("name", "")).startswith("daml-script")})
if script:
    problems.append(f"depends on {script}")
if problems:
    sys.exit(f"{dar}: " + "; ".join(problems))
print(f"{dar}: {name} {version} {actual_id}, legacy dependency {legacy_id}")
' "$dar" "$name" "$version" "$main_id" "$legacy_id"
}

check_vendored_dar() {
  local dar=$1 main_id=$2 actual_id
  actual_id=$(dpm damlc inspect-dar "$dar" --json | python3 -c 'import json, sys; print(json.load(sys.stdin)["main_package_id"])')
  [ "$actual_id" = "$main_id" ] || { echo "$dar: main package ID $actual_id is not the reviewed $main_id" >&2; exit 1; }
  echo "$dar: $actual_id"
}

check_vendored_dar ../lib/splice-api-token-metadata-v1-1.0.0.dar 4ded6b668cb3b64f7a88a30874cd41c75829f5e064b3fbbadf41ec7e8363354f
check_vendored_dar ../lib/splice-api-token-holding-v1-1.0.0.dar 718a0f77e505a8de22f188bd4c87fe74101274e9d4cb1bfac7d09aec7158d35b
check_dar "$legacy_dar" canton-treasury-amm 0.1.0 "$legacy_id"
check_dar "$secure_dar" canton-treasury-amm-secure-v1 0.2.0 "$secure_id"
check_dar "$prototype_dar" canton-treasury-amm-live-reserve-prototype 0.1.0 -

dpm upgrade-check --both "$legacy_dar" "$secure_dar" > "${TMPDIR:-/tmp}/upgrade-check.log" 2>&1 || {
  cat "${TMPDIR:-/tmp}/upgrade-check.log" >&2
  echo "Upgrade check of the legacy and Secure V1 DARs failed" >&2
  exit 1
}
echo "Upgrade check passed for $legacy_dar and $secure_dar."
