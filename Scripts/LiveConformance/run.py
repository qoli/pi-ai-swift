#!/usr/bin/env python3
"""Run pinned upstream assertions twice, then project the evidence onto the full offline inventory."""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SPEC = importlib.util.spec_from_file_location("offline", ROOT / "Scripts/Conformance/run.py")
offline = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(offline)


def read(path):
    return json.loads(path.read_text())


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(root, *args):
    return subprocess.check_output(["git", "-C", root, *args], text=True).strip()


def baseline(directory, upstream):
    source = read(directory / "report.json")
    pin = read(ROOT / "Upstream.lock.json")["revision"]
    if (not source["offlineConformant"] or not offline.offline_conformant(source)
            or source["upstreamRevision"] != pin or git(upstream, "rev-parse", "HEAD") != pin
            or git(upstream, "status", "--porcelain", "--untracked-files=all", "--", "packages/ai", "packages/telemetry")
            or any(source[key] != value for key, value in offline.evidence_digests(ROOT).items())):
        raise ValueError("Baseline must be a complete passing offline run of this source and harness")
    suites = {s["path"]: s["sha256"] for s in source["suites"]}
    expected = {"packages/ai/test/" + s for s in read(ROOT / "Scripts/Conformance/suites.json")["suites"]}
    if expected != suites.keys() or any(sha(upstream / path) != digest for path, digest in suites.items()):
        raise ValueError("Full manifest or test source hash mismatch")
    for case in source["cases"]:
        evidence = case.get("skipEvidence", {}).get("upstream", {})
        for explicit in evidence.get("explicitSkips", []):
            path = case["upstreamTest"]
            line = explicit["line"]
            if (explicit["sourceSHA256"] != suites[path] or line != evidence["location"]["line"]
                    or not re.search(r"\b(?:it|test)\.skip\s*\(", (upstream / path).read_text().splitlines()[line - 1])):
                raise ValueError("Unverified upstream literal skip")
    inventory = Counter((c["upstreamTest"], c["name"]) for c in source["cases"])
    for impl in ("swift", "upstream"):
        collected = Counter((f"packages/ai/test/{Path(f['name']).name}", " > ".join([*a["ancestorTitles"], a["title"]]))
                            for f in read(directory / f"{impl}.json")["testResults"] for a in f["assertionResults"])
        if collected != inventory:
            raise ValueError("Baseline case inventory differs from original Vitest collection")
    harness = hashlib.sha256()
    for file in sorted(HERE.iterdir()):
        if file.is_file():
            harness.update(file.name.encode() + b"\0" + file.read_bytes() + b"\0")
    identity = {key: source[key] for key in ("upstreamRevision", "swiftSourceSHA256", "harnessSHA256")}
    identity.update(baselineSHA256=sha(directory / "report.json"), liveHarnessSHA256=harness.hexdigest(),
                    swiftRevision=git(ROOT, "rev-parse", "HEAD"))
    return source, identity


def json_lines(path):
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def paired(case, baseline_case, upstream, probe, module, key):
    with tempfile.TemporaryDirectory(prefix="pi-live-") as tmp:
        work = Path(tmp)
        env = {k: os.environ[k] for k in ("PATH", "TMPDIR", "LANG") if k in os.environ}
        env.update(HOME=tmp, PI_NO_LOCAL_LLM="1", PI_CONFORMANCE_UPSTREAM=str(upstream),
                   PI_CONFORMANCE_OUTPUT=tmp, PI_CONFORMANCE_PROBE=str(probe), PI_CONFORMANCE_JSON_MODULE=str(module),
                   PI_LIVE_ORIGIN=case["origin"], PI_LIVE_MODEL=case["model"], PI_LIVE_CASE=case["name"])
        env[case["credential"]] = key
        suite = "test/" + case["suite"]
        pattern = "(?:^| )" + re.escape(case["name"].replace(" > ", " ")) + "$"
        reports, wire, codes = {}, {}, {}
        for impl in ("upstream", "swift"):
            env["PI_CONFORMANCE_IMPLEMENTATION"] = impl
            (work / "wire.jsonl").unlink(missing_ok=True)
            command = ["node", str(upstream / "node_modules/vitest/vitest.mjs"), "run", "--config",
                       str(HERE / "vitest.config.mjs"), suite, "--testNamePattern", pattern]
            result = subprocess.run(command, cwd=upstream / "packages/ai", env=env,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            codes[impl] = result.returncode
            report = work / (impl + ".json")
            if not report.exists():
                return {"status": "runner_error", "exitCodes": codes}
            reports[impl] = read(report)
            wire[impl] = json_lines(work / "wire.jsonl")
        traces = {i: json_lines(work / f"{i}-invocations.jsonl") for i in reports}
        _, cases = offline.evaluate(upstream, reports, traces["swift"], codes, traces["upstream"], require_case_instances=True)
        found = [c for c in cases if c["name"] == case["name"] and c["upstreamTest"] == baseline_case["upstreamTest"]]
        if len(found) != 1:
            return {"status": "collection_mismatch", "exitCodes": codes}
        c, location = found[0], baseline_case["skipEvidence"]["upstream"]["location"]
        attempts = {}
        for impl, report in reports.items():
            matching = [a for f in report["testResults"] for a in f["assertionResults"]
                        if " > ".join([*a["ancestorTitles"], a["title"]]) == c["name"]]
            if len(matching) != 1 or matching[0].get("location") != location:
                return {"status": "collection_mismatch", "exitCodes": codes}
            attempts[impl] = matching[0].get("meta", {}).get("liveAttempts", 0)
            if any(a not in matching and a["status"] not in {"skipped", "pending"} for f in report["testResults"]
                   for a in f["assertionResults"]):
                return {"status": "collection_mismatch", "exitCodes": codes}
        reasons = {i: sorted({w["reason"] for w in wire[i] if w.get("reason")}) for i in reports}
        status = c["conformanceStatus"]
        native_ops = [t["operation"] for t in traces["swift"] if t.get("caseInstanceID") == c["swiftCaseInstanceID"]
                      and t.get("entrypoint") == "stream"]
        statuses = {i: [w["status"] for w in wire[i] if w["instance"] == c[i + "CaseInstanceID"]
                        and w["model"] == case["model"] and w["name"] == case["name"] and w["native"] == (i == "swift")]
                    for i in reports}
        if status == "passed":
            if any(codes.values()) or not {"encode", "decode"} <= set(native_ops) or not all(
                    any(s is not None and 200 <= s < 300 for s in values) for values in statuses.values()):
                status = "missing_live_evidence"
            elif max(attempts.values()) > 1:
                status = "flaky"
        return {"status": status, "exitCodes": codes, "attempts": attempts, "upstreamAssertion": c["upstreamStatus"],
                "swiftAssertion": c["status"], "httpStatus": statuses, "providerReasons": reasons, "nativeStreamOperations": native_ops,
                "upstreamOperations": c["upstreamOperations"], "missingSwiftOperations": c["missingSwiftOperations"],
                "swiftDispatchProtocols": c["swiftDispatchProtocols"], "upstreamProtocols": c["upstreamProtocols"]}


def aggregate(source, identity, batches):
    cases = {c["caseID"]: c for c in source["cases"]}
    latest = {}
    for batch in batches:
        if batch["identity"] != identity:
            raise ValueError("Live evidence provenance mismatch")
        for row in batch["results"]:
            key = row["caseID"]
            if key not in cases or cases[key]["conformanceStatus"] != "not_executed":
                raise ValueError("Live case absent from outstanding inventory")
            if row["status"] == "passed" and not (
                    row.get("upstreamAssertion") == row.get("swiftAssertion") == "passed"
                    and row.get("exitCodes") == {"upstream": 0, "swift": 0}
                    and row.get("attempts") == {"upstream": 1, "swift": 1}
                    and {"encode", "decode"} <= set(row.get("nativeStreamOperations", []))
                    and "stream" in row.get("upstreamOperations", []) and row.get("missingSwiftOperations") == []
                    and row.get("upstreamProtocols") and row["upstreamProtocols"] == row.get("swiftDispatchProtocols")
                    and all(any(isinstance(s, int) and 200 <= s < 300 for s in row.get("httpStatus", {}).get(i, []))
                            for i in ("upstream", "swift"))):
                raise ValueError("Missing paired assertion or Native transport evidence")
            if key in latest and latest[key]["observedAt"] == row["observedAt"] and latest[key] != row:
                raise ValueError("Conflicting observations")
            if key not in latest or row["observedAt"] >= latest[key]["observedAt"]:
                latest[key] = row
    rows = []
    suites = {s["path"]: s["sha256"] for s in source["suites"]}
    for key, case in cases.items():
        status = case["conformanceStatus"]
        row = {"caseID": key, "status": status}
        if status == "not_executed":
            evidence = case["skipEvidence"]["upstream"]
            row["conditions"] = [s["expression"] for s in evidence["conditionalSkips"]]
            row["line"] = evidence["location"]["line"]
            row["sourceSHA256"] = suites[case["upstreamTest"]]
            if evidence["explicitSkips"]:
                row["status"] = "upstream_explicit_skip"
                if key in latest:
                    raise ValueError("An upstream literal skip cannot be replaced by a live result")
            elif key in latest:
                row["live"] = latest[key]
                row["status"] = "live_passed" if latest[key]["status"] == "passed" else latest[key]["status"]
        rows.append(row)
    counts = Counter(r["status"] for r in rows)
    allowed = {"passed", "live_passed", "outside_scope"}
    return {"identity": identity, "caseCount": len(rows), "suiteInventory": source["reviewedInventoryCounts"],
            "statusCounts": counts, "offlineConformant": source["offlineConformant"],
            "upstreamRunnableConformant": not (counts.keys() - allowed - {"upstream_explicit_skip"}),
            "conformant": not (counts.keys() - allowed), "cases": rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True, help="Complete offline evidence directory")
    parser.add_argument("--upstream", type=Path, default=ROOT / ".build/upstreams/pi")
    parser.add_argument("--build-root", type=Path)
    parser.add_argument("--provider", action="append", default=[], help="Run this provider's reviewed pilot cases")
    parser.add_argument("--previous", type=Path, action="append", default=[], help="Earlier paired batch.json")
    parser.add_argument("--output", type=Path, required=True, help="New evidence directory")
    args = parser.parse_args()
    upstream = args.upstream.resolve()
    source, identity = baseline(args.baseline, upstream)
    plans = read(HERE / "pilot.json")
    if set(args.provider) - {p["provider"] for p in plans}:
        parser.error("Unknown pilot provider")
    previous = [read(f) for f in args.previous]
    aggregate(source, identity, previous)
    credentials = {plan["credential"]: os.environ.get(plan["credential"]) for plan in plans
                   if plan["provider"] in args.provider}
    # The compiler, package resolver and Git only need the local build environment.
    build_environment = {k: os.environ[k] for k in ("PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "DEVELOPER_DIR", "SDKROOT")
                         if k in os.environ}
    os.environ.clear()
    os.environ.update(build_environment)
    args.output.mkdir(parents=True, exist_ok=False)
    results = []
    probe = module = None
    batch = {"identity": identity, "results": results}
    for plan in plans:
        if plan["provider"] not in args.provider:
            continue
        matches = [c for c in source["cases"] if c["upstreamTest"] == "packages/ai/test/" + plan["suite"]
                   and c["name"] == plan["name"] and c["conformanceStatus"] == "not_executed"]
        if len(matches) != 1 or matches[0]["skipEvidence"]["upstream"]["explicitSkips"]:
            raise ValueError("Case is not a unique conditional skip in this baseline")
        c = matches[0]
        key = credentials[plan["credential"]]
        if key:
            if probe is None:
                probe, module, _ = offline.build_probe(ROOT, upstream, args.build_root)
                batch["probeSHA256"] = sha(probe)
            result = paired(plan, c, upstream, probe, module, key)
        else:
            result = {"status": "credential_unavailable"}
        row = {**result, "caseID": c["caseID"], "provider": plan["provider"], "model": plan["model"],
               "authMethod": "oauth" if plan["provider"] == "openai-codex" else "api_key",
               "observedAt": datetime.now(timezone.utc).isoformat()}
        results.append(row)
        print(row["provider"], row["model"], row["status"], flush=True)
    if baseline(args.baseline, upstream)[1] != identity:
        raise ValueError("Provenance changed while running")
    report = aggregate(source, identity, [*previous, batch])
    for file, data in [("batch.json", batch), ("report.json", report)]:
        (args.output / file).write_text(json.dumps(data, indent=2) + "\n")
    print(dict(report["statusCounts"]))
    return int(any(r["status"] != "passed" for r in results))


if __name__ == "__main__":
    sys.exit(main())
