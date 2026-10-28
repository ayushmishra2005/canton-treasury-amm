#!/usr/bin/env python3
"""Runs `verify-legacy-lineage.py` against the pools of `mpLineageScenarios` on the local
multi-participant network and checks each verdict and its reason codes.

Usage: check-legacy-lineage.py OUT LEGACY_PACKAGE_ID [--after-pruning]

OUT is the run's log directory with `lineage.json` and `participants-hosted.json`. Each party is
read on its own participant's JSON Ledger API (gRPC port + 2), except where a case says otherwise.
Local test network only: its JSON API has no authentication, which a production reader must have.
With --after-pruning only the genuine pool is checked, and must no longer verify.
"""

import json
import os
import subprocess
import sys

VERIFIED, BLOCKED, INCOMPLETE = "VERIFIED", "BLOCKED", "INCOMPLETE EVIDENCE"
EXIT_CODES = {VERIFIED: 0, BLOCKED: 2, INCOMPLETE: 3}


def main(argv):
    if len(argv) not in (3, 4) or (len(argv) == 4 and argv[3] != "--after-pruning"):
        print(__doc__, file=sys.stderr)
        return 1
    out, package, after_pruning = argv[1], argv[2], len(argv) == 4
    evidence = json.load(open(f"{out}/lineage.json"))
    hosted = json.load(open(f"{out}/participants-hosted.json"))
    parties = evidence["parties"]
    cases = {case["name"]: case for case in evidence["cases"]}
    verifier = os.path.join(os.path.dirname(os.path.abspath(__file__)), "verify-legacy-lineage.py")

    def url_of(participant):
        return f"http://localhost:{hosted['participants'][participant]['port'] + 2}"

    def reader(role, participant=None):
        party = parties[role]
        return {"party": party, "url": url_of(participant or hosted["party_participants"][party])}

    all_readers = [reader(role) for role in ("auditor", "treasuryIssuer", "stableIssuer", "provider", "trader")]

    def manifest(case, **changes):
        pool_id = case["poolId"]
        base = {
            "legacyPackageId": package,
            "pool": {"poolId": pool_id, "auditors": case["auditors"]},
            "authorizedParties": [pool_id["operator"], pool_id["governance"]],
            "reserveInstruments": {"treasury": pool_id["treasuryInstrument"], "stable": pool_id["stableInstrument"]},
            "anchor": {"genesisCid": case["genesisCid"], "attestedBy": [parties["auditor"]]},
            "snapshot": {"poolCid": case["snapshotCid"]},
            "knownActiveStateCid": case["currentCid"],
            "positions": case["positions"],
            "provenance": {"recordedBy": parties["auditor"], "method": "observed Initialize on the auditor's own participant when the pool opened"},
            "requireComplete": False,
        }
        base.update(changes)
        return base

    def anchored_by(role, cid):
        return {"anchor": {"genesisCid": cid, "attestedBy": [parties[role]]},
                "provenance": {"recordedBy": parties[role], "method": "test: attested by " + role}}

    genuine, recreated, legitimate = cases["genuine"], cases["recreated"], cases["legitimate"]
    checks = [
        ("genuine", manifest(genuine), all_readers, VERIFIED, set()),
        ("genuine with an unexpected package ID", manifest(genuine, legacyPackageId="00" * 32), all_readers, BLOCKED, {"UNEXPECTED_PACKAGE"}),
        ("genuine anchor attested only by the operator", manifest(genuine, **anchored_by("operator", genuine["genesisCid"])), all_readers, INCOMPLETE, {"ANCHOR_UNVERIFIED", "ANCHOR_PROVENANCE"}),
        ("genuine without an anchor", manifest(genuine, anchor={}), all_readers, INCOMPLETE, {"ANCHOR_MISSING"}),
        ("genuine read through a participant not hosting the auditor", manifest(genuine),
         [reader("auditor", "trader")] + all_readers[1:], INCOMPLETE, {"READER_NOT_HOSTED", "NO_INDEPENDENT_VIEW"}),
        ("genuine without the issuers' views", manifest(genuine), [all_readers[0]] + all_readers[3:], INCOMPLETE, {"RESERVE_EVIDENCE_MISSING"}),
        ("genuine with an unconfirmed position", manifest(genuine, positions=genuine["positions"][:1]), all_readers, BLOCKED, {"POSITION_MISMATCH"}),
        ("faithful re-creation", manifest(recreated), all_readers, BLOCKED, {"LINEAGE_BROKEN", "UNACCOUNTED_STATE"}),
        ("re-creation as the anchor, attested by the operator", manifest(recreated, **anchored_by("operator", recreated["currentCid"])),
         all_readers, BLOCKED, {"ANCHOR_NOT_GENESIS", "ANCHOR_CONFLICT", "ANCHOR_UNVERIFIED"}),
        ("re-creation as the anchor, attested by the auditor", manifest(recreated, **anchored_by("auditor", recreated["currentCid"])),
         all_readers, BLOCKED, {"ANCHOR_NOT_GENESIS", "ANCHOR_CONFLICT"}),
        ("reserve diversion", manifest(cases["diverted"]), all_readers, BLOCKED, {"RESERVE_DIVERTED", "RESERVE_INACTIVE"}),
        ("forged position with a matching supply", manifest(cases["forged"]), all_readers, BLOCKED, {"LINEAGE_BROKEN", "UNACCOUNTED_STATE", "POSITION_OUTSIDE_LINEAGE"}),
        ("duplicate active state", manifest(cases["duplicated"]), all_readers, BLOCKED, {"DUPLICATE_ACTIVE_STATE"}),
        ("standalone position burn", manifest(cases["burned"]), all_readers, BLOCKED, {"POSITION_OUTSIDE_LINEAGE", "SUPPLY_MISMATCH"}),
        ("standalone burn of a whole position", manifest(cases["fullyBurned"]), all_readers, BLOCKED, {"POSITION_OUTSIDE_LINEAGE", "SUPPLY_MISMATCH"}),
        ("re-created genesis as the anchor, attested by the auditor",
         manifest(cases["regenesis"], **anchored_by("auditor", cases["regenesis"]["currentCid"])), all_readers, BLOCKED, {"ANCHOR_NOT_GENESIS"}),
        ("re-created genesis with the original anchor", manifest(cases["regenesis"]), all_readers, BLOCKED, {"LINEAGE_BROKEN", "UNACCOUNTED_STATE"}),
        ("pool no independent party observes", manifest(cases["unobserved"], **anchored_by("treasuryIssuer", cases["unobserved"]["genesisCid"])),
         all_readers, INCOMPLETE, {"NO_INDEPENDENT_VIEW"}),
        ("legitimate changes after the snapshot", manifest(legitimate), all_readers, VERIFIED, set()),
        ("inventory older than the current state", manifest(legitimate, knownActiveStateCid=legitimate["snapshotCid"]), all_readers, INCOMPLETE, {"STATE_CHANGED"}),
        ("snapshot from another pool's history", manifest(legitimate, snapshot={"poolCid": recreated["currentCid"]}), all_readers, BLOCKED, {"SNAPSHOT_NOT_IN_LINEAGE"}),
        ("partial migration, completion required", manifest(cases["partial"], requireComplete=True), all_readers, BLOCKED, {"MIGRATION_INCOMPLETE"}),
        ("partial migration, inventory only", manifest(cases["partial"]), all_readers, VERIFIED, set()),
        ("complete migration, completion required", manifest(cases["complete"], requireComplete=True), all_readers, VERIFIED, set()),
    ]
    if after_pruning:
        checks = [("genuine after the auditor's participant was pruned", manifest(genuine), all_readers, INCOMPLETE, {"HISTORY_PRUNED"})]

    anchor_statuses = {
        "genuine": "independently verified",
        "genuine anchor attested only by the operator": "claimed but unverified",
        "genuine without an anchor": "missing",
        "re-creation as the anchor, attested by the auditor": "conflicting",
        "re-created genesis as the anchor, attested by the auditor": "conflicting",
        "genuine after the auditor's participant was pruned": "claimed but unverified",
    }
    failures = 0
    for index, (name, case_manifest, readers, expected, codes) in enumerate(checks):
        stem = f"{out}/lineage-{'pruned' if after_pruning else index:>02}"
        json.dump(case_manifest, open(f"{stem}-manifest.json", "w"), indent=2)
        json.dump({"readers": readers}, open(f"{stem}-readers.json", "w"), indent=2)
        result = subprocess.run([sys.executable, verifier, f"{stem}-manifest.json", f"{stem}-readers.json", "--report", f"{stem}-report.json"],
                                capture_output=True, text=True, check=False)
        with open(f"{stem}-verifier.txt", "w") as log:
            log.write(result.stdout + result.stderr)
        try:
            report = json.load(open(f"{stem}-report.json"))
        except (OSError, ValueError):
            report = {"verdict": None, "reasons": []}
        found = {reason["code"] for reason in report["reasons"]}
        ok = (report["verdict"] == expected and result.returncode == EXIT_CODES[expected] and codes <= found
              and (expected != VERIFIED or not found))
        post = len(report.get("evidence", {}).get("postSnapshotTransitions", []))
        if name == "legitimate changes after the snapshot" and post != 3:
            ok = False
        if name in anchor_statuses and report.get("anchorStatus") != anchor_statuses[name]:
            ok = False
        print(f"LINEAGE {'ok' if ok else 'FAILED'}: {name}: {report['verdict']} {sorted(found)}, anchor {report.get('anchorStatus')}"
              + (f", {post} post-snapshot transition(s)" if expected == VERIFIED else ""))
        if not ok:
            failures += 1
            print(f"  expected {expected} with {sorted(codes)}, exit {EXIT_CODES[expected]}; got exit {result.returncode}", file=sys.stderr)
            print(result.stdout + result.stderr, file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
