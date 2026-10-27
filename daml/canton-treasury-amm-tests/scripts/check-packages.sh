#!/usr/bin/env bash
# Package integrity for the deployable DARs, run after `dpm build --all`:
# - the legacy package keeps the ID of the deployed legacy release, so existing contracts stay
#   bound to it and an upload of this build is a no-op next to it;
# - Secure V1 is a separate package that depends on exactly that legacy package, and its ID is
#   the reviewed one (any source change, including a comment, changes it and needs review);
# - neither deployable DAR depends on daml-script, and the type-level upgrade check passes.
set -euo pipefail

cd "$(dirname "$0")/../.."

legacy_id=d8cadd3c038655678a71e052616b054a07ad53600e2feb719456f629c2772aa6
secure_id=e4546c3f60ef59f07edb4ad1c61676ed46fe66eb8c998a1277aa29bc43b958c8
legacy_dar=canton-treasury-amm/.daml/dist/canton-treasury-amm-0.1.0.dar
secure_dar=canton-treasury-amm-secure-v1/.daml/dist/canton-treasury-amm-secure-v1-0.1.0.dar
prototype_dar=canton-treasury-amm-live-reserve-prototype/.daml/dist/canton-treasury-amm-live-reserve-prototype-0.1.0.dar

check_dar() {
  local dar=$1 name=$2 main_id=$3
  dpm damlc inspect-dar "$dar" --json | python3 -c '
import json, sys
dar, name, main_id, legacy_id = sys.argv[1:]
info = json.load(sys.stdin)
packages = info["packages"]
actual_id = info["main_package_id"]
main_name, main_version = packages[actual_id]["name"], packages[actual_id]["version"]
problems = []
if (main_name, main_version) != (name, "0.1.0"):
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
print(f"{dar}: {name} {actual_id}, legacy dependency {legacy_id}")
' "$dar" "$name" "$main_id" "$legacy_id"
}

check_dar "$legacy_dar" canton-treasury-amm "$legacy_id"
check_dar "$secure_dar" canton-treasury-amm-secure-v1 "$secure_id"
check_dar "$prototype_dar" canton-treasury-amm-live-reserve-prototype -

dpm upgrade-check --both "$legacy_dar" "$secure_dar" > "${TMPDIR:-/tmp}/upgrade-check.log" 2>&1 || {
  cat "${TMPDIR:-/tmp}/upgrade-check.log" >&2
  echo "Upgrade check of the legacy and Secure V1 DARs failed" >&2
  exit 1
}
echo "Upgrade check passed for $legacy_dar and $secure_dar."
