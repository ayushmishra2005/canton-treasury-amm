#!/usr/bin/env python3
"""Read-only lineage verification of one legacy pool before a Secure V1 migration.

Usage: verify-legacy-lineage.py MANIFEST READERS [--report REPORT.json]

MANIFEST is the trusted anchor manifest (`MIGRATION.md`, "Lineage verification"). READERS lists
the parties whose own participants are read, as {"readers": [{"party": ..., "url": ...}]} with
the participant's JSON Ledger API v2 base URL. Every request is a read: the parties endpoint, the
ledger end, the pruning boundary, the update stream and the active contracts, each scoped to the
reader's own party. Nothing is submitted.

Exit codes: 0 VERIFIED, 2 BLOCKED, 3 INCOMPLETE EVIDENCE, 1 unusable input. BLOCKED outranks
INCOMPLETE EVIDENCE, which outranks VERIFIED. VERIFIED states only that the evidence read agrees
with the anchor; the report lists what it still takes on trust.
"""

import json
import sys
import urllib.error
import urllib.request
from decimal import Decimal

VERIFIED, BLOCKED, INCOMPLETE = "VERIFIED", "BLOCKED", "INCOMPLETE EVIDENCE"
EXIT_CODES = {VERIFIED: 0, BLOCKED: 2, INCOMPLETE: 3}
POOL, POSITION, SETUP, HOLDING = (
    "CantonTreasuryAmm.Pool:Pool", "CantonTreasuryAmm.LiquidityPosition:LiquidityPosition",
    "CantonTreasuryAmm.Pool:PoolSetup", "CantonTreasuryAmm.Token:Holding")
LEGACY_PACKAGE_NAME = "canton-treasury-amm"
TRANSITIONS = {"SwapExactInput", "AddLiquidity", "RemoveLiquidity"}
ATOMS = Decimal("10000000000")
PAGE_SIZE = 200
TIMEOUT_SECONDS = 30

# Always trusted, whatever the verdict.
BASE_ASSUMPTIONS = [
    "Each reader's participant serves its party's complete, unaltered projection of the ledger; a "
    "participant that omits or invents events, or a synchronizer that sequences a different "
    "history, defeats every check.",
    "The anchor attestors recorded the genesis contract ID independently when the pool was opened, "
    "and are not colluding with the operator and governance.",
    "The legacy package with the expected ID is the reviewed legacy code; the verifier checks "
    "package IDs, not what the package does.",
    "The verdict describes the ledger at the offsets in the evidence. Anything that happens after "
    "them, including between this verification and a cutover, is not covered.",
    "The verifier reports discrepancies; it cannot restore reserves, revoke positions or stop the "
    "operator, governance or an issuer from using authority the legacy templates give them.",
]


class Unavailable(Exception):
    pass


def atoms(value):
    return int(Decimal(value) * ATOMS)


def call(url, path, body=None):
    request = urllib.request.Request(
        url.rstrip("/") + path, method="GET" if body is None else "POST",
        data=None if body is None else json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise Unavailable(f"{url}{path}: {error}: {error.read(500).decode(errors='replace')}") from error
    except (urllib.error.URLError, OSError, ValueError) as error:
        raise Unavailable(f"{url}{path}: {error}") from error


def event_format(party, templates=None):
    if templates is None:
        filters = [{"identifierFilter": {"WildcardFilter": {"value": {"includeCreatedEventBlob": False}}}}]
    else:
        filters = [{"identifierFilter": {"TemplateFilter": {"value": {"templateId": t, "includeCreatedEventBlob": False}}}}
                   for t in templates]
    return {"filtersByParty": {party: {"cumulative": filters}}, "verbose": True}


class View:
    """One party's projection, read from its own participant at one pinned ledger end: its whole
    history, and its active legacy pools, positions and holdings (the JSON API caps list sizes)."""

    def __init__(self, party, url):
        self.party, self.url = party, url
        details = call(url, f"/v2/parties/{urllib.request.quote(party, safe='')}").get("partyDetails", [])
        self.hosted = any(d.get("party") == party and d.get("isLocal") for d in details)
        if not self.hosted:
            return
        self.end = call(url, "/v2/state/ledger-end")["offset"]
        self.pruned = call(url, "/v2/state/latest-pruned-offsets").get("participantPrunedUpToInclusive", 0)
        self.transactions = self._history()
        self.active = {}
        if self.end > 0:
            # Template filters take package names; each returned event names its package ID.
            templates = [f"#{LEGACY_PACKAGE_NAME}:{entity}" for entity in (POOL, POSITION, HOLDING)]
            entries = call(url, "/v2/state/active-contracts",
                           {"activeAtOffset": self.end, "eventFormat": event_format(party, templates)})
            for entry in entries:
                active = entry.get("contractEntry", {}).get("JsActiveContract")
                if active:
                    self.active[active["createdEvent"]["contractId"]] = active["createdEvent"]
        self.created, self.consumed = {}, {}
        for tx in self.transactions:
            for wrapped in tx.get("events", []):
                (kind, event), = wrapped.items()
                if kind == "CreatedEvent":
                    self.created[event["contractId"]] = (tx, event)
                elif kind == "ExercisedEvent" and event["consuming"]:
                    self.consumed[event["contractId"]] = (tx, event)
                elif kind == "ArchivedEvent":
                    self.consumed[event["contractId"]] = (tx, dict(event, choice="Archive", lastDescendantNodeId=event["nodeId"]))

    def _history(self):
        """Every transaction from the pruning boundary to the pinned ledger end. The page cursor
        does not close by itself, so paging stops at the end offset read before it."""
        body = {"beginOffsetExclusive": self.pruned, "endOffsetInclusive": self.end, "maxPageSize": PAGE_SIZE,
                "updateFormat": {"includeTransactions": {
                    "eventFormat": event_format(self.party), "transactionShape": "TRANSACTION_SHAPE_LEDGER_EFFECTS"}}}
        transactions, reached = [], self.pruned
        while reached < self.end:
            page = call(self.url, "/v2/updates/get-updates-page", body)
            for update in page.get("updates", []):
                transaction = update.get("update", {}).get("Transaction")
                if transaction:
                    transactions.append(transaction["value"])
            highest, token = page.get("highestPageOffsetInclusive", reached), page.get("nextPageToken")
            if highest >= self.end:
                break
            if highest <= reached or not token:
                raise Unavailable(f"{self.url}: the update stream stopped at offset {highest} before ledger end {self.end}")
            reached, body = highest, dict(body, pageToken=token)
        return transactions

    def events(self, entity):
        for tx in self.transactions:
            for wrapped in tx.get("events", []):
                (kind, event), = wrapped.items()
                if event["templateId"].split(":", 1)[1] == entity:
                    yield tx, kind, event

    def subtree(self, tx, exercise):
        """The events strictly below `exercise` in this projection of `tx`."""
        low, high = exercise["nodeId"], exercise["lastDescendantNodeId"]
        for wrapped in tx.get("events", []):
            (kind, event), = wrapped.items()
            if low < event["nodeId"] <= high:
                yield kind, event


class Verification:
    def __init__(self, manifest, readers):
        self.manifest, self.readers = manifest, readers
        self.reasons, self.evidence, self.assumptions = [], {}, list(BASE_ASSUMPTIONS)

    def finding(self, outcome, code, detail):
        self.reasons.append({"outcome": outcome, "code": code, "detail": detail})

    def verdict(self):
        outcomes = {reason["outcome"] for reason in self.reasons}
        return BLOCKED if BLOCKED in outcomes else INCOMPLETE if INCOMPLETE in outcomes else VERIFIED

    def run(self):
        try:
            self._run()
        except Unavailable as error:
            self.finding(INCOMPLETE, "READER_UNAVAILABLE", str(error))
        except (KeyError, TypeError, ValueError) as error:
            self.finding(INCOMPLETE, "UNEXPECTED_RESPONSE", f"{type(error).__name__}: {error}")
        verdict = self.verdict()
        return {"verdict": verdict, "anchorStatus": self.anchor_status(), "reasons": self.reasons, "evidence": self.evidence,
                "trustedAssumptions": self.assumptions if verdict == VERIFIED else BASE_ASSUMPTIONS}

    def anchor_status(self):
        codes = {reason["code"] for reason in self.reasons}
        if "ANCHOR_MISSING" in codes:
            return "missing"
        if codes & {"ANCHOR_CONFLICT", "ANCHOR_NOT_GENESIS", "CONFLICTING_GENESIS", "CONFLICTING_VIEWS"}:
            return "conflicting"
        if "genesis" in self.evidence and not codes & {"ANCHOR_UNVERIFIED", "ANCHOR_PROVENANCE"}:
            return "independently verified"
        return "claimed but unverified"

    def _run(self):
        m = self.manifest
        missing = [k for k in ("legacyPackageId", "pool", "anchor", "snapshot", "knownActiveStateCid", "positions", "provenance") if k not in m]
        if missing:
            self.finding(INCOMPLETE, "MANIFEST_INCOMPLETE", f"missing {', '.join(missing)}")
            return
        package, pool_id, auditors = m["legacyPackageId"], m["pool"]["poolId"], m["pool"]["auditors"]
        core = {pool_id["operator"], pool_id["governance"]}
        issuers = {"treasury": pool_id["treasuryInstrument"]["issuer"], "stable": pool_id["stableInstrument"]["issuer"]}
        if set(m.get("authorizedParties", [])) != core:
            self.finding(BLOCKED, "AUTHORIZED_PARTIES_MISMATCH", "the manifest's authorized parties are not exactly the pool's operator and governance")
        instruments = m.get("reserveInstruments", {})
        if instruments.get("treasury") != pool_id["treasuryInstrument"] or instruments.get("stable") != pool_id["stableInstrument"]:
            self.finding(BLOCKED, "RESERVE_INSTRUMENTS_MISMATCH", "the manifest's reserve instruments differ from the pool identity")

        anchor = m["anchor"]
        genesis_cid, attestors = anchor.get("genesisCid"), anchor.get("attestedBy", [])
        if not genesis_cid or not attestors:
            self.finding(INCOMPLETE, "ANCHOR_MISSING", "no genesis contract ID with attestors; the pool has no trusted starting reference")
            return
        independent = [p for p in attestors if p not in core]
        if not independent:
            self.finding(INCOMPLETE, "ANCHOR_UNVERIFIED", "the anchor is attested only by the operator or governance, whose state it is meant to check")
        recorded_by = m["provenance"].get("recordedBy")
        if recorded_by not in independent:
            self.finding(INCOMPLETE, "ANCHOR_PROVENANCE", "the anchor was not recorded by one of its independent attestors")

        views = {}
        for reader in self.readers:
            view = View(reader["party"], reader["url"])
            if not view.hosted:
                self.finding(INCOMPLETE, "READER_NOT_HOSTED", f"{reader['party']} is not hosted on {reader['url']}; its view was not used")
                continue
            views[view.party] = view
            self.evidence.setdefault("readers", []).append(
                {"party": view.party, "url": view.url, "ledgerEnd": view.end, "prunedUpToInclusive": view.pruned})

        stakeholders = [views[p] for p in auditors if p in views and p not in core]
        if not stakeholders:
            self.finding(INCOMPLETE, "NO_INDEPENDENT_VIEW", "no reader is an independent stakeholder of the pool, so its history cannot be read independently")
            return
        if independent and not any(p in [v.party for v in stakeholders] for p in independent):
            self.finding(INCOMPLETE, "ANCHOR_UNVERIFIED", "no independent attestor of the anchor is a pool stakeholder with a reader")

        lineages = [self._lineage(view, package, pool_id, auditors, genesis_cid) for view in stakeholders]
        if any(lineage is None for lineage in lineages):
            return
        if len({tuple(l["states"]) for l in lineages}) != 1:
            self.finding(BLOCKED, "CONFLICTING_VIEWS", "independent stakeholders report different lineages")
            return
        # A broken lineage has no current state to reconcile, but its history up to the break is
        # still checked for positions and reserves moved outside it.
        lineage, view = lineages[0], stakeholders[0]
        if not lineage["broken"]:
            self._snapshot(lineage, m)
        self._positions(view, lineage, package, pool_id, m)
        self._provider_views(views, package, pool_id, m)
        self._reserves(views, issuers, lineage, package, pool_id)
        self.assumptions.append(
            f"Pool history was read from {', '.join(v.party for v in stakeholders)}; parties that are not pool "
            "stakeholders cannot see pool states, so this check depends on those readers remaining stakeholders.")
        if any(v.pruned > 0 for v in views.values()):
            self.assumptions.append("Some readers have pruned history before the genesis; contracts archived before then were not inspected.")

    def _lineage(self, view, package, pool_id, auditors, genesis_cid):
        def pool_like(event):
            return event.get("createArgument", {}).get("poolId") == pool_id

        # Contracts carrying this pool's identity from anything but the legacy package.
        for tx, kind, event in ((tx, k, e) for tx in view.transactions for w in tx["events"] for k, e in w.items()):
            if kind == "CreatedEvent" and pool_like(event) and not event["templateId"].startswith(package + ":"):
                self.finding(BLOCKED, "UNEXPECTED_PACKAGE", f"{event['templateId']} {event['contractId']} carries this pool's identity")
        if genesis_cid not in view.created:
            pruned = view.pruned > 0
            self.finding(INCOMPLETE, "HISTORY_PRUNED" if pruned else "ANCHOR_NOT_VISIBLE",
                         f"{view.party} has no creation of the anchor {genesis_cid}"
                         + (f"; its participant has pruned up to offset {view.pruned}" if pruned else ""))
            return None
        tx, genesis = view.created[genesis_cid]
        geneses = {}
        for gtx, kind, event in view.events(SETUP):
            if kind == "ExercisedEvent" and event["choice"] == "Initialize" and event["consuming"] and event["templateId"].startswith(package + ":"):
                for sub_kind, sub in view.subtree(gtx, event):
                    if sub_kind == "CreatedEvent" and sub["templateId"] == f"{package}:{POOL}" and pool_like(sub):
                        geneses[sub["contractId"]] = gtx["updateId"]
        arg = genesis["createArgument"]
        problems = []
        if genesis["templateId"] != f"{package}:{POOL}":
            problems.append(f"template {genesis['templateId']}")
        if arg.get("poolId") != pool_id:
            problems.append("a different pool identity")
        if sorted(arg.get("auditors", [])) != sorted(auditors):
            problems.append("different auditors")
        if arg.get("stateVersion") != "0" or atoms(arg["treasuryFeeAmount"]) or atoms(arg["stableFeeAmount"]):
            problems.append("a non-initial version or fees")
        if set(genesis["signatories"]) != {pool_id["operator"], pool_id["governance"]}:
            problems.append("signatories other than the operator and governance")
        if problems:
            self.finding(BLOCKED, "ANCHOR_CONFLICT", f"the anchor {genesis_cid} has " + ", ".join(problems))
        if genesis_cid not in geneses:
            self.finding(BLOCKED, "ANCHOR_NOT_GENESIS", f"the anchor {genesis_cid} was not created by Initialize of a legacy PoolSetup")
        if problems or genesis_cid not in geneses:
            return None
        for other in set(geneses) - {genesis_cid}:
            self.finding(BLOCKED, "CONFLICTING_GENESIS", f"{other} is a second Initialize of the same pool identity")

        states, transitions, current = [genesis_cid], [], genesis_cid
        scopes = [(gtx["updateId"], ev) for gtx, k, ev in view.events(SETUP)
                  if k == "ExercisedEvent" and ev["choice"] == "Initialize" and gtx["updateId"] == geneses[genesis_cid]]
        broken = False
        while current in view.consumed:
            ctx, exercise = view.consumed[current]
            version = int(view.created[current][1]["createArgument"]["stateVersion"])
            if exercise["choice"] not in TRANSITIONS:
                self.finding(BLOCKED, "LINEAGE_BROKEN", f"state {current} (version {version}) was consumed by {exercise['choice']}, not by a pool transition")
                broken = True
                break
            successors = [e for k, e in view.subtree(ctx, exercise)
                          if k == "CreatedEvent" and e["templateId"] == f"{package}:{POOL}" and pool_like(e)]
            if len(successors) != 1 or successors[0]["createArgument"]["stateVersion"] != str(version + 1) \
                    or exercise.get("exerciseResult", {}).get("poolCid") != successors[0]["contractId"]:
                self.finding(BLOCKED, "LINEAGE_BROKEN", f"{exercise['choice']} on {current} did not create exactly one successor at version {version + 1}")
                broken = True
                break
            transitions.append({"updateId": ctx["updateId"], "offset": ctx["offset"], "choice": exercise["choice"],
                                "from": current, "to": successors[0]["contractId"]})
            scopes.append((ctx["updateId"], exercise))
            current = successors[0]["contractId"]
            states.append(current)
        for cid, (_, event) in view.created.items():
            if event["templateId"].endswith(":" + POOL) and pool_like(event) and cid not in states:
                active = cid in view.active
                self.finding(BLOCKED, "DUPLICATE_ACTIVE_STATE" if active and not broken else "UNACCOUNTED_STATE",
                             f"pool state {cid} ({'active' if active else 'archived'}) is not in the anchored lineage")
        if not broken and current not in view.active:
            self.finding(INCOMPLETE, "STATE_NOT_ACTIVE", f"the lineage's last state {current} is not in {view.party}'s active contracts")
        self.evidence.update({"genesis": {"contractId": genesis_cid, "updateId": geneses[genesis_cid], "offset": tx["offset"]},
                              "lineage": transitions, "currentStateCid": current})
        return {"states": states, "transitions": transitions, "scopes": scopes, "current": current, "broken": broken,
                "stateArgs": {cid: view.created[cid][1]["createArgument"] for cid in states},
                "currentState": view.created[current][1]["createArgument"],
                "updateIds": {geneses[genesis_cid]} | {t["updateId"] for t in transitions}}

    def _snapshot(self, lineage, m):
        states, current = lineage["states"], lineage["current"]
        known, snapshot = m["knownActiveStateCid"], m["snapshot"].get("poolCid")
        if known != current:
            if known in states:
                self.finding(INCOMPLETE, "STATE_CHANGED", f"the inventory's state {known} has been succeeded by {current}; re-take the inventory")
            else:
                self.finding(BLOCKED, "KNOWN_STATE_NOT_IN_LINEAGE", f"the inventory's state {known} is not in the anchored lineage")
        if snapshot not in states:
            self.finding(BLOCKED, "SNAPSHOT_NOT_IN_LINEAGE", f"the snapshot state {snapshot} is not in the anchored lineage")
        else:
            self.evidence["postSnapshotTransitions"] = [t for t in lineage["transitions"][states.index(snapshot):]]

    def _positions(self, view, lineage, package, pool_id, m):
        def in_scope(tx, event, choices):
            return any(update_id == tx["updateId"] and exercise["choice"] in choices
                       and exercise["nodeId"] < event["nodeId"] <= exercise["lastDescendantNodeId"]
                       for update_id, exercise in lineage["scopes"])

        for tx, kind, event in view.events(POSITION):
            arg_pool = (view.created.get(event["contractId"], (None, {}))[1].get("createArgument", {}).get("poolId"))
            if kind == "CreatedEvent":
                if event["createArgument"]["poolId"] != pool_id or not event["templateId"].startswith(package + ":"):
                    continue
                if not in_scope(tx, event, {"Initialize", "AddLiquidity", "RemoveLiquidity"}):
                    self.finding(BLOCKED, "POSITION_OUTSIDE_LINEAGE", f"position {event['contractId']} was created outside a pool transition")
            elif kind == "ExercisedEvent" and event["consuming"] and arg_pool == pool_id:
                if not in_scope(tx, event, {"RemoveLiquidity"}):
                    self.finding(BLOCKED, "POSITION_OUTSIDE_LINEAGE", f"position {event['contractId']} was consumed by {event['choice']} outside a pool withdrawal")
        active = {cid: event["createArgument"] for cid, event in view.active.items()
                  if event["templateId"] == f"{package}:{POSITION}" and event["createArgument"]["poolId"] == pool_id}
        for cid in active:
            if cid not in view.created:
                self.finding(BLOCKED, "POSITION_OUTSIDE_LINEAGE", f"active position {cid} has no creation in the readable history")
        if lineage["broken"]:
            return
        state = lineage["currentState"]
        held = sum(atoms(p["shares"]) for p in active.values())
        if held + atoms(state["lockedShares"]) != atoms(state["totalShares"]):
            self.finding(BLOCKED, "SUPPLY_MISMATCH", f"active positions hold {held} share atoms and {atoms(state['lockedShares'])} are locked, but the state records {atoms(state['totalShares'])}")
        observed = sorted((p["provider"], atoms(p["shares"])) for p in active.values())
        confirmed = sorted((p["provider"], int(p["shares"])) for p in m["positions"])
        if observed != confirmed:
            self.finding(BLOCKED, "POSITION_MISMATCH", f"active positions {observed} differ from the providers' confirmations {confirmed}")
        if m.get("requireComplete") and active:
            self.finding(BLOCKED, "MIGRATION_INCOMPLETE", f"{len(active)} legacy position(s) are still outstanding")
        self.evidence["activePositions"] = [{"provider": p, "shareAtoms": s} for p, s in observed]

    def _provider_views(self, views, package, pool_id, m):
        """Each confirming provider with a reader must hold exactly what it confirmed."""
        for provider in sorted({p["provider"] for p in m["positions"]}):
            view = views.get(provider)
            if view is None:
                continue
            held = sorted(atoms(e["createArgument"]["shares"]) for e in view.active.values()
                          if e["templateId"] == f"{package}:{POSITION}" and e["createArgument"]["poolId"] == pool_id
                          and e["createArgument"]["provider"] == provider)
            confirmed = sorted(int(p["shares"]) for p in m["positions"] if p["provider"] == provider)
            if held != confirmed:
                self.finding(BLOCKED, "POSITION_MISMATCH", f"{provider} holds {held} on its own participant but confirmed {confirmed}")

    def _reserves(self, views, issuers, lineage, package, pool_id):
        state = lineage["currentState"]
        for leg, issuer in issuers.items():
            view = views.get(issuer)
            if view is None:
                self.finding(INCOMPLETE, "RESERVE_EVIDENCE_MISSING", f"no reader for the {leg} issuer {issuer}")
                continue
            holders = {}
            for cid, arg in lineage["stateArgs"].items():
                holders.setdefault(arg[f"{leg}ReserveHoldingCid"], set()).add(cid)
            consuming_updates = {t["from"]: t["updateId"] for t in lineage["transitions"]}
            for reserve, states in holders.items():
                if reserve not in view.created:
                    self.finding(INCOMPLETE if view.pruned > 0 else BLOCKED, "RESERVE_ORIGIN_UNKNOWN",
                                 f"the {leg} issuer has no creation of reserve {reserve}")
                    continue
                created_in = view.created[reserve][0]["updateId"]
                if created_in not in lineage["updateIds"]:
                    self.finding(BLOCKED, "RESERVE_OUTSIDE_LINEAGE", f"{leg} reserve {reserve} was created outside the anchored lineage")
                if reserve in view.consumed:
                    ctx, exercise = view.consumed[reserve]
                    if ctx["updateId"] not in {consuming_updates.get(s) for s in states}:
                        self.finding(BLOCKED, "RESERVE_DIVERTED", f"{leg} reserve {reserve} was consumed by {exercise['choice']} outside a transition of its pool state")
            if lineage["broken"]:
                continue
            reserve = state[f"{leg}ReserveHoldingCid"]
            holding = view.active.get(reserve)
            instrument = pool_id[f"{leg}Instrument"]
            if holding is None:
                self.finding(BLOCKED, "RESERVE_INACTIVE", f"the current {leg} reserve {reserve} is not active")
            elif holding["templateId"] != f"{package}:{HOLDING}" or holding["createArgument"]["instrument"] != instrument \
                    or holding["createArgument"]["owner"] != pool_id["operator"] \
                    or atoms(holding["createArgument"]["amount"]) != atoms(state[f"{leg}ReserveAmount"]):
                self.finding(BLOCKED, "RESERVE_MISMATCH", f"the current {leg} reserve {reserve} does not hold the recorded amount for the operator")
            self.evidence.setdefault("reserves", {})[leg] = {"holdingCid": reserve, "amountAtoms": atoms(state[f"{leg}ReserveAmount"]), "readBy": issuer}


def human(report):
    lines = [f"Legacy lineage verification: {report['verdict']}", f"  Anchor: {report['anchorStatus']}"]
    for reason in report["reasons"]:
        lines.append(f"  [{reason['outcome']}] {reason['code']}: {reason['detail']}")
    if report["verdict"] == VERIFIED:
        lines.append(f"  Lineage: genesis {report['evidence']['genesis']['contractId']} through "
                     f"{len(report['evidence']['lineage'])} pool transition(s) to {report['evidence']['currentStateCid']}")
        lines.append(f"  Post-snapshot transitions: {len(report['evidence'].get('postSnapshotTransitions', []))}")
        lines.append("  Still trusted:")
        lines.extend(f"    - {assumption}" for assumption in report["trustedAssumptions"])
    return "\n".join(lines)


def main(argv):
    args = argv[1:]
    report_path = None
    if "--report" in args:
        index = args.index("--report")
        report_path = args[index + 1] if index + 1 < len(args) else None
        del args[index:index + 2]
    if len(args) != 2 or ("--report" in argv and not report_path):
        print(__doc__, file=sys.stderr)
        return 1
    try:
        manifest = json.load(open(args[0]))
        readers = json.load(open(args[1]))["readers"]
    except (OSError, ValueError, KeyError) as error:
        print(f"Unusable input: {error}", file=sys.stderr)
        return 1
    report = Verification(manifest, readers).run()
    if report_path:
        with open(report_path, "w") as out:
            json.dump(report, out, indent=2)
    print(human(report))
    return EXIT_CODES[report["verdict"]]


if __name__ == "__main__":
    sys.exit(main(sys.argv))
