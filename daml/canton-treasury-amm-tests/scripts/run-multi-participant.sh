#!/usr/bin/env bash
# Runs the Secure V1 multi-participant validation (`CantonTreasuryAmm.Test.MultiParticipant`) on
# a local, in-memory Canton topology with one participant per role, and leaves every log in the
# output directory. Local only: it starts its own nodes on ports 15001-15093 and connects to
# nothing else. Run after `dpm build --all`. Exits non-zero on any failed phase.
set -euo pipefail
# The SDK every daml.yaml pins; outside a package directory dpm would resolve its own default.
export DPM_SDK_VERSION=3.5.5

cd "$(dirname "$0")/.."

canton_version=3.5.12
canton_jar="${DPM_HOME:-$HOME/.dpm}/cache/components/canton-open-source/$canton_version/lib/canton-open-source-$canton_version.jar"
dar=.daml/dist/canton-treasury-amm-tests-0.1.0.dar
out=${AMM_MP_LOG_DIR:-$(mktemp -d)}
mkdir -p "$out"
echo "Logs: $out"

[ -f "$canton_jar" ] || { echo "Canton $canton_version (the SDK 3.5.5 component) is not installed at $canton_jar" >&2; exit 1; }
[ -f "$dar" ] || { echo "Missing $dar; run dpm build --all first" >&2; exit 1; }
java -jar "$canton_jar" --version > "$out/versions.txt"
dpm version >> "$out/versions.txt"
shasum -a 256 "$dar" ../canton-treasury-amm/.daml/dist/canton-treasury-amm-0.1.0.dar ../canton-treasury-amm-secure-v1/.daml/dist/canton-treasury-amm-secure-v1-0.2.0.dar >> "$out/versions.txt"

AMM_TEST_DAR="$PWD/$dar" java -jar "$canton_jar" daemon --no-tty \
  -c multi-participant/canton.conf \
  --bootstrap multi-participant/bootstrap.canton \
  --log-file-name "$out/canton.log" > "$out/daemon.out" 2>&1 &
canton_pid=$!
stop_canton() {
  local status=$? canton_status=0
  if kill "$canton_pid" 2>/dev/null; then
    wait "$canton_pid" || canton_status=$?
    # 143 is Canton's exit on the SIGTERM sent here.
    if [ "$canton_status" -ne 0 ] && [ "$canton_status" -ne 143 ]; then
      echo "Canton exited with status $canton_status" >&2
      [ "$status" -ne 0 ] || status=$canton_status
    fi
  fi
  echo "Canton stopped; logs: $out"
  exit "$status"
}
trap stop_canton EXIT

for _ in $(seq 1 120); do
  grep -q "AMM multi-participant topology ready" "$out/daemon.out" && break
  kill -0 "$canton_pid" 2>/dev/null || { echo "Canton exited during startup" >&2; cat "$out/daemon.out" >&2; exit 1; }
  sleep 2
done
grep -q "AMM multi-participant topology ready" "$out/daemon.out" || { echo "Canton did not start in time" >&2; exit 1; }
cat "$out/daemon.out"

# Participant configs: no party routing for allocation, each party routed to its own participant,
# and an impersonation config that routes the core signers and Treasury issuer to the trader's.
python3 - "$out" <<'EOF'
import json, sys
out = sys.argv[1]
ports = {"custodian": 15011, "operator": 15021, "governance": 15031, "treasury_issuer": 15041,
         "stable_issuer": 15051, "trader": 15061, "provider": 15071, "auditor": 15081,
         "second_provider": 15091}
participants = {name: {"host": "localhost", "port": port} for name, port in ports.items()}
base = {"default_participant": participants["custodian"], "participants": participants, "party_participants": {}}
json.dump(base, open(f"{out}/participants-allocation.json", "w"), indent=2)
EOF

run_script() {
  local name=$1 config=$2 input=$3 output=$4
  echo "== $name"
  dpm script --dar "$dar" --script-name "CantonTreasuryAmm.Test.MultiParticipant:$name" \
    --participant-config "$out/$config" --input-file "$input" --output-file "$out/$output" \
    > "$out/$name.log" 2>&1
}

set_stable_issuer_connection() {
  AMM_STABLE_ISSUER_CONNECTION=$1 java -jar "$canton_jar" run multi-participant/set-stable-issuer-connection.canton \
    --no-tty -c multi-participant/remote.conf --log-file-name "$out/remote-console.log" \
    > "$out/stable-issuer-$1.log" 2>&1
  cat "$out/stable-issuer-$1.log"
}

echo '{}' > "$out/unit.json"
run_script mpAllocate participants-allocation.json "$out/unit.json" parties.json

python3 - "$out" <<'EOF'
import json, sys
out = sys.argv[1]
base = json.load(open(f"{out}/participants-allocation.json"))
parties = json.load(open(f"{out}/parties.json"))
roles = {"custodian": "custodian", "operator": "operator", "governance": "governance",
         "treasuryIssuer": "treasury_issuer", "stableIssuer": "stable_issuer", "trader": "trader",
         "provider": "provider", "auditor": "auditor"}
hosted = dict(base, party_participants={parties[role]: name for role, name in roles.items()})
json.dump(hosted, open(f"{out}/participants-hosted.json", "w"), indent=2)
routed_to_trader = {"custodian", "operator", "treasuryIssuer", "stableIssuer"}
impersonation = dict(base, party_participants={
    parties[role]: ("trader" if role in routed_to_trader else name) for role, name in roles.items()})
json.dump(impersonation, open(f"{out}/participants-impersonation.json", "w"), indent=2)
EOF

run_script mpVerifyHosting participants-hosted.json "$out/parties.json" hosting.json

if run_script mpSingleSubmissionCharter participants-hosted.json "$out/parties.json" single-submission.json; then
  echo "A four-participant charter was created in one submission" >&2
  exit 1
fi
grep -q "All parties must be on the same participant" "$out/mpSingleSubmissionCharter.log" || {
  echo "mpSingleSubmissionCharter failed for an unexpected reason:" >&2
  cat "$out/mpSingleSubmissionCharter.log" >&2
  exit 1
}
echo "Single-submission charter refused by the script runner: no participant hosts all four core signers."

run_script mpScenarios participants-hosted.json "$out/parties.json" state.json
run_script mpImpersonation participants-impersonation.json "$out/state.json" impersonation.json
cat "$out/impersonation.json"; echo
run_script mpOnboardingAttacks participants-hosted.json "$out/state.json" outage.json

set_stable_issuer_connection disconnect
run_script mpOfflineSwap participants-hosted.json "$out/outage.json" liveness.json
set_stable_issuer_connection reconnect
run_script mpReconnectedSwap participants-hosted.json "$out/liveness.json" reconnected.json

run_script mpPauseLifecycle participants-hosted.json "$out/reconnected.json" paused.json
set_stable_issuer_connection disconnect
run_script mpOfflinePausedExit participants-hosted.json "$out/paused.json" paused-outage.json
set_stable_issuer_connection reconnect
run_script mpResumeAfterOutage participants-hosted.json "$out/paused-outage.json" resumed.json

run_script mpMigrationAllocate participants-hosted.json "$out/state.json" migration-parties.json
python3 - "$out" <<'EOF'
import json, sys
out = sys.argv[1]
hosted = json.load(open(f"{out}/participants-hosted.json"))
second_provider = json.load(open(f"{out}/migration-parties.json"))["secondProvider"]
routing = dict(hosted["party_participants"], **{second_provider: "second_provider"})
json.dump(dict(hosted, party_participants=routing), open(f"{out}/participants-migration.json", "w"), indent=2)
EOF
run_script mpMigrationRehearsal participants-migration.json "$out/migration-parties.json" migration.json

grep -h "HOSTING\|SCENARIO\|IMPERSONATION\|ONBOARDING\|LIVENESS\|PAUSE\|MIGRATION" "$out"/mp*.log
echo "Multi-participant validation passed."
