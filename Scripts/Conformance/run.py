#!/usr/bin/env python3

import argparse
from collections import Counter
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import sys


def run(command, *, cwd, env=None):
    subprocess.run(command, cwd=cwd, env=env, check=True)


def evaluate(upstream, reports, invocations, exit_codes, upstream_invocations=()):
    cases = []
    upstream_cases = {}
    for file in reports["upstream"]["testResults"]:
        for case in file["assertionResults"]:
            name = " > ".join([*case["ancestorTitles"], case["title"]])
            upstream_cases.setdefault((file["name"], name), []).append(case)
    occurrences = Counter()
    for file in reports["swift"]["testResults"]:
        relative = str(Path(file["name"]).relative_to(upstream))
        for index, case in enumerate(file["assertionResults"]):
            name = " > ".join([*case["ancestorTitles"], case["title"]])
            calls = [call for call in invocations if call.get("file") == file["name"] and call.get("test") == name]
            original_calls = [call for call in upstream_invocations
                              if call.get("file") == file["name"] and call.get("test") == name]
            operations = {call["operation"] for call in original_calls}
            swift_operations = {"stream" if call.get("operation") in ["encode", "decode"]
                                else call.get("operation") for call in calls}
            upstream_protocols = {call["protocol"] for call in original_calls if call.get("protocol")}
            swift_protocols = {call["protocol"] for call in calls
                               if call.get("entrypoint") == "stream"
                               and call.get("operation") in ["encode", "decode"]}
            missing_protocols = upstream_protocols - swift_protocols
            unexpected_protocols = swift_protocols - upstream_protocols if upstream_protocols else set()
            key = (file["name"], name)
            matching = upstream_cases.get(key, [])
            original = matching[occurrences[key]] if occurrences[key] < len(matching) else {}
            occurrences[key] += 1
            item = {
                "caseID": f"{relative}#{index}:{name}",
                "upstreamTest": relative,
                "name": name,
                "upstreamStatus": original.get("status", "missing"),
                "status": case["status"],
                "swiftInvocations": len(calls),
                "upstreamOperations": sorted(operations),
                "upstreamProtocols": sorted(upstream_protocols),
                "swiftDispatchProtocols": sorted(swift_protocols),
                "missingSwiftProtocols": sorted(missing_protocols),
                "unexpectedSwiftProtocols": sorted(unexpected_protocols),
                "missingSwiftOperations": sorted(operations - swift_operations),
                "protocols": sorted({call["protocol"] for call in calls if call["protocol"] != "*"}),
                "failures": sorted({call["failure"]["operation"] for call in calls
                                    if call.get("failure", {}).get("operation")}),
                "nativeFailures": [call["failure"] for call in calls if call.get("failure")],
                "unrepresentedCapabilities": sorted({
                    capability for call in calls for capability in call.get("unrepresentedCapabilities", [])
                }),
                "assertionFailures": case.get("failureMessages", []),
            }
            if item["upstreamStatus"] in ["pending", "skipped"] or item["status"] in ["pending", "skipped"]:
                item["conformanceStatus"] = "not_executed"
            elif item["upstreamStatus"] != "passed":
                item["conformanceStatus"] = "upstream_failure"
            elif item["unrepresentedCapabilities"]:
                item["conformanceStatus"] = "interface_gap"
            elif not item["swiftInvocations"] or not operations or item["missingSwiftOperations"]:
                item["conformanceStatus"] = "bridge_gap"
            elif missing_protocols or unexpected_protocols:
                item["conformanceStatus"] = "dispatch_mismatch"
            elif item["status"] != "passed":
                item["conformanceStatus"] = "mismatch"
            else:
                item["conformanceStatus"] = "passed"
            cases.append(item)
    baseline_names = Counter(
        (file["name"], " > ".join([*case["ancestorTitles"], case["title"]]))
        for file in reports["upstream"]["testResults"] for case in file["assertionResults"]
    )
    swift_names = Counter(
        (str(upstream / case["upstreamTest"]), case["name"]) for case in cases
    )
    conformant = (
        all(code == 0 for code in exit_codes.values()) and bool(cases)
        and baseline_names == swift_names
        and all(case["conformanceStatus"] == "passed" for case in cases)
    )
    return conformant, cases


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--upstream", type=Path)
    parser.add_argument("--test", action="append", dest="tests")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    manifest = json.loads((repo / "Scripts/Conformance/suites.json").read_text())
    suites = args.tests or manifest["suites"]
    for suite in suites:
        if suite not in manifest["suites"]:
            raise SystemExit(manifest["excludedSuites"].get(
                suite, f"Suite is not in the reviewed offline conformance manifest: {suite}"))
    upstream = (args.upstream or repo / ".build/upstreams/pi").resolve()
    lock = json.loads((repo / "Upstream.lock.json").read_text())
    if not (upstream / "node_modules/vitest/vitest.mjs").is_file():
        raise SystemExit("Prepare the pinned upstream and its dependencies with ./Scripts/check-upstream.sh first, or pass --upstream")
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=upstream, text=True).strip()
    if revision != lock["revision"]:
        raise SystemExit(f"Upstream revision mismatch: {revision}")
    run(["git", "diff", "--quiet", "HEAD", "--", "packages/ai/src", "packages/ai/test"], cwd=upstream)
    build = (args.output or repo / ".build/conformance").resolve()
    build.mkdir(parents=True, exist_ok=True)
    (build / "report.json").unlink(missing_ok=True)
    scratch = repo / ".build/conformance/swift"
    run(["swift", "build", "--scratch-path", str(scratch)], cwd=repo)
    bin_path = Path(subprocess.check_output(
        ["swift", "build", "--scratch-path", str(scratch), "--show-bin-path"],
        cwd=repo, text=True).strip())
    probe = bin_path / "swift-conformance-probe"
    objects = sorted((bin_path / "PiAIProviderRuntime.build").glob("*.o"))
    modules = bin_path / "Modules"
    if (bin_path / "PiAIProviderRuntime.o").is_file():
        objects = [bin_path / "PiAIProviderRuntime.o"]
        modules = bin_path
    if not objects:
        raise SystemExit("Swift provider-runtime object files were not produced")
    heap_object = bin_path / "heap-observer.o"
    run(["xcrun", "clang", "-std=c11", "-c",
         str(repo / "Scripts/Conformance/HeapObserver.c"), "-o", str(heap_object)], cwd=repo)
    run(["xcrun", "swiftc", "-parse-as-library", "-g", "-enable-testing",
         "-import-objc-header", str(repo / "Scripts/Conformance/HeapObserver.h"),
         "-I", str(modules),
         str(repo / "Scripts/Conformance/SwiftProbe.swift"),
         *map(str, objects), str(heap_object), "-o", str(probe)], cwd=repo)
    environment = {
        key: value for key, value in os.environ.items()
        if not re.search(r"TOKEN|API_KEY|SECRET|ACCESS_KEY|CREDENTIAL|PROXY$", key, re.IGNORECASE)
        and not re.match(r"ANTHROPIC_|OPENAI_|AZURE_|AWS_|GOOGLE_|GCLOUD_|CLOUDFLARE_|COPILOT_", key)
    }
    environment.update({
        "PI_CONFORMANCE_UPSTREAM": str(upstream),
        "PI_CONFORMANCE_PROBE": str(probe),
        "PI_CONFORMANCE_OUTPUT": str(build),
    })
    command = [
        "node", str(upstream / "node_modules/vitest/vitest.mjs"), "run",
        "--config", str(repo / "Scripts/Conformance/vitest.config.mjs"),
        *[f"test/{name}" for name in suites],
    ]
    reports = {}
    exit_codes = {}
    (build / "upstream-invocations.jsonl").write_text("")
    (build / "heap-observations.jsonl").write_text("")
    for implementation in ["upstream", "swift"]:
        environment["PI_CONFORMANCE_IMPLEMENTATION"] = implementation
        (build / "swift-invocations.jsonl").write_text("")
        (build / f"{implementation}.json").unlink(missing_ok=True)
        result = subprocess.run(command, cwd=upstream / "packages/ai", env=environment)
        exit_codes[implementation] = result.returncode
        reports[implementation] = json.loads((build / f"{implementation}.json").read_text())
    invocations = [json.loads(line) for line in (build / "swift-invocations.jsonl").read_text().splitlines()]
    upstream_invocations = [json.loads(line) for line in (build / "upstream-invocations.jsonl").read_text().splitlines()]
    conformant, cases = evaluate(upstream, reports, invocations, exit_codes, upstream_invocations)
    swift_digest = hashlib.sha256()
    for path in sorted((repo / "Sources/PiAIProviderRuntime").rglob("*")):
        if path.is_file():
            swift_digest.update(str(path.relative_to(repo)).encode() + b"\0" + path.read_bytes() + b"\0")
    harness_digest = hashlib.sha256()
    for path in sorted((repo / "Scripts/Conformance").iterdir()):
        if path.is_file():
            harness_digest.update(path.name.encode() + b"\0" + path.read_bytes() + b"\0")
    report = {
        "schemaVersion": 1,
        "upstreamRevision": revision,
        "swiftSourceSHA256": swift_digest.hexdigest(),
        "harnessSHA256": harness_digest.hexdigest(),
        "conformant": conformant,
        "exitCodes": exit_codes,
        "scope": "unchanged upstream test files listed in suites",
        "bridgeBoundary": "Swift ProviderRuntimeKernel, wire adapters and catalog; upstream transcript assembly, fixture credentials and SDK transports remain test infrastructure; general SDK retry policies and authorization lifecycle are not covered",
        "mismatchMeaning": "An original assertion differs across the bridge; ownership and bridge triage are required before classifying it as a Swift runtime defect",
        "suites": [{
            "path": f"packages/ai/test/{suite}",
            "sha256": hashlib.sha256((upstream / "packages/ai/test" / suite).read_bytes()).hexdigest(),
        } for suite in suites],
        "statusCounts": dict(Counter(case["status"] for case in cases)),
        "conformanceCounts": dict(Counter(case["conformanceStatus"] for case in cases)),
        "heapMeasurements": [json.loads(line) for line in
                             (build / "heap-observations.jsonl").read_text().splitlines()],
        "upstreamStatusCounts": dict(Counter(case["upstreamStatus"] for case in cases)),
        "suiteResults": {implementation: [{
            "path": str(Path(file["name"]).relative_to(upstream)),
            "status": file["status"],
            "message": file.get("message", ""),
        } for file in reports[implementation]["testResults"]] for implementation in reports},
        "unrepresentedCapabilityCases": sum(bool(case["unrepresentedCapabilities"]) for case in cases),
        "notAdoptedSuites": [{
            "path": str(path.relative_to(upstream)),
            "reason": manifest["excludedSuites"].get(path.name, "Not yet adopted by the Swift conformance bridge"),
        } for path in sorted((upstream / "packages/ai/test").glob("*.test.ts")) if path.name not in suites],
        "cases": cases,
    }
    (build / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Conformance: {conformant}; upstream suites={len(suites)}; cases={len(cases)}; Swift calls={len(invocations)}")
    print(f"Report: {build / 'report.json'}")
    return 0 if conformant else 1


if __name__ == "__main__":
    sys.exit(main())
