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


def target_object_files(bin_path, target):
    aggregate = bin_path / f"{target}.o"
    if aggregate.is_file():
        return [aggregate]
    return sorted((bin_path / f"{target}.build").rglob("*.o"))


def evidence_digests(repo):
    digests = {}
    for name, root, recursive in [
        ("swiftSourceSHA256", repo / "Sources/PiAIProviderRuntime", True),
        ("harnessSHA256", repo / "Scripts/Conformance", False),
    ]:
        digest = hashlib.sha256()
        if name == "swiftSourceSHA256":
            for package_file in (repo / "Package.swift", repo / "Package.resolved"):
                digest.update(package_file.name.encode() + b"\0" + package_file.read_bytes() + b"\0")
        for path in sorted(root.rglob("*") if recursive else root.iterdir()):
            if path.is_file():
                relative = path.relative_to(repo) if recursive else path.name
                digest.update(str(relative).encode() + b"\0" + path.read_bytes() + b"\0")
        digests[name] = digest.hexdigest()
    return digests


def load_scope_audit(repo, upstream, manifest, revision):
    audit = json.loads((repo / "Scripts/Conformance/scope-audit.json").read_text())
    if audit["schemaVersion"] != 1 or audit["upstreamRevision"] != revision:
        raise ValueError("Conformance scope audit revision/schema drift")

    def verify_file(root, reference):
        if hashlib.sha256((root / reference["path"]).read_bytes()).hexdigest() != reference["sha256"]:
            raise ValueError(f"Conformance scope audit source drift: {reference['path']}")

    verify_file(repo, audit["contract"])
    for rule in audit["rules"].values():
        for existing in rule["existingSuiteRules"]:
            reason = manifest["excludedSuites"][existing["suite"]]
            if not reason.startswith("Outside") or hashlib.sha256(reason.encode()).hexdigest() != existing["sha256"]:
                raise ValueError("Conformance scope audit established ownership rule drift")
    result = {}
    for entry in audit["cases"]:
        if entry["upstreamTest"].split("/")[-1] not in manifest["suites"]:
            raise ValueError("Audited cases must remain in the adopted upstream suites")
        verify_file(upstream, {"path": entry["upstreamTest"], "sha256": entry["testSHA256"]})
        if not entry["references"]:
            raise ValueError("Conformance scope audit requires exact source references")
        for reference in entry["references"]:
            verify_file(upstream, reference)
            if reference["symbol"] not in (upstream / reference["path"]).read_text():
                raise ValueError("Conformance scope audit symbol is absent from pinned source")
        selector = (entry["upstreamTest"], entry["name"], entry["occurrence"])
        if selector in result:
            raise ValueError("Duplicate conformance scope audit selector")
        result[selector] = {**entry, "basis": audit["rules"][entry["rule"]]}
    return result


def skip_evidence(upstream, reports, observations):
    result = {}
    for implementation, report in reports.items():
        occurrences = Counter()
        for file in report["testResults"]:
            text = Path(file["name"]).read_text()
            lines = text.splitlines()
            source_hash = hashlib.sha256(text.encode()).hexdigest()
            for case in file["assertionResults"]:
                name = " > ".join([*case["ancestorTitles"], case["title"]])
                key = (str(Path(file["name"]).relative_to(upstream)), name)
                occurrence = occurrences[key]
                occurrences[key] += 1
                if case["status"] not in ["pending", "skipped"]:
                    continue
                location = case.get("location") or {}
                declarations = []
                for observed in observations[implementation]:
                    if observed["file"] != file["name"] or not observed["skipped"]:
                        continue
                    if observed["declaration"] == "describe":
                        matches = observed["title"] in case["ancestorTitles"]
                    else:
                        matches = observed["title"] == case["title"] and observed["line"] == location.get("line")
                    if not matches:
                        continue
                    fragment = "\n".join(lines[observed["line"] - 1:])
                    condition = re.search(r"\b(?:describe|it|test)\.skipIf\((.*?)\)\s*\(", fragment, re.DOTALL)
                    declarations.append({**observed, "expression": condition[1].strip() if condition else None,
                                         "sourceSHA256": source_hash})
                explicit = []
                line = location.get("line")
                if line and re.search(r"\b(?:it|test)\.skip\s*\(", lines[line - 1]):
                    explicit.append({"file": file["name"], "line": line, "sourceSHA256": source_hash})
                result.setdefault((*key, occurrence), {})[implementation] = {
                    "location": location, "conditionalSkips": declarations, "explicitSkips": explicit,
                    "explained": bool(declarations or explicit),
                }
    return result


def evaluate(upstream, reports, invocations, exit_codes, upstream_invocations=(), *, require_case_instances=False,
             scope_audit=None):
    cases = []
    value_producers = {call["valueOrigin"]["id"]: call for call in invocations
                       if call.get("entrypoint") == "value-produced" and call.get("valueOrigin")}

    def valid_value_access(call):
        origin = call.get("valueOrigin", {})
        producer = value_producers.get(origin.get("id"), {})
        return (call.get("operation") in {"catalog", "catalog.images", "catalog.classifiers", "catalog.all-models"}
                and bool(re.fullmatch(r"[0-9a-f]{64}", origin.get("sha256", "")))
                and producer.get("file") == call.get("file")
                and not producer.get("caseInstanceID")
                and producer.get("operation") == call.get("operation")
                and producer.get("protocol") == call.get("protocol")
                and producer.get("valueOrigin") == origin
                and not producer.get("failure"))
    upstream_cases = {}
    for file in reports["upstream"]["testResults"]:
        for case in file["assertionResults"]:
            name = " > ".join([*case["ancestorTitles"], case["title"]])
            upstream_cases.setdefault((file["name"], name), []).append(case)
    swift_case_counts = Counter(
        (file["name"], " > ".join([*case["ancestorTitles"], case["title"]]))
        for file in reports["swift"]["testResults"] for case in file["assertionResults"]
    )
    occurrences = Counter()
    for file in reports["swift"]["testResults"]:
        relative = str(Path(file["name"]).relative_to(upstream))
        for index, case in enumerate(file["assertionResults"]):
            name = " > ".join([*case["ancestorTitles"], case["title"]])
            key = (file["name"], name)
            matching = upstream_cases.get(key, [])
            original = matching[occurrences[key]] if occurrences[key] < len(matching) else {}
            occurrences[key] += 1
            audited_scope = (scope_audit or {}).get((relative, name, occurrences[key] - 1))
            duplicate_name = len(matching) > 1 or swift_case_counts[key] > 1

            def case_calls(records, test_case):
                instance = (test_case.get("meta") or {}).get("piConformanceInstanceID")
                if not instance and (require_case_instances or duplicate_name):
                    return []
                return [call for call in records
                        if call.get("file") == file["name"] and call.get("test") == name
                        and (not instance or call.get("caseInstanceID") == instance)]

            calls = case_calls(invocations, case)
            invalid_values = [call for call in calls if call.get("entrypoint") == "value-access"
                              and not valid_value_access(call)]
            calls = [call for call in calls if call not in invalid_values]
            original_calls = case_calls(upstream_invocations, original)
            caller_operations = {call["operation"] for call in original_calls
                                 if call.get("ownership") == "caller"
                                 and call["operation"] in ["identity.merge", "identity.session-headers"]}
            operations = {call["operation"] for call in original_calls
                          if not (call.get("ownership") == "caller"
                                  and call["operation"] in ["identity.merge", "identity.session-headers"])}
            swift_operations = {"stream" if call.get("operation") in ["encode", "decode"]
                                else call.get("operation") for call in calls}
            upstream_protocols = {call["protocol"] for call in original_calls if call.get("protocol")}
            swift_protocols = {call["protocol"] for call in calls
                               if (call.get("entrypoint") == "stream" and call.get("operation") in ["encode", "decode"])
                               or (call.get("entrypoint") == "classify" and call.get("operation") == "classify")}
            missing_protocols = upstream_protocols - swift_protocols
            unexpected_protocols = swift_protocols - upstream_protocols if upstream_protocols else set()
            item = {
                "caseID": f"{relative}#{index}:{name}",
                "upstreamCaseInstanceID": (original.get("meta") or {}).get("piConformanceInstanceID"),
                "swiftCaseInstanceID": (case.get("meta") or {}).get("piConformanceInstanceID"),
                "upstreamTest": relative,
                "name": name,
                "upstreamStatus": original.get("status", "missing"),
                "status": case["status"],
                "swiftInvocations": len(calls),
                "swiftOperationInvocations": sum(call.get("entrypoint") != "value-access" for call in calls),
                "swiftValueAccesses": sum(call.get("entrypoint") == "value-access" for call in calls),
                "nativeValueOrigins": [call["valueOrigin"] for call in calls if call.get("entrypoint") == "value-access"],
                "invalidNativeValueOrigins": [call.get("valueOrigin") for call in invalid_values],
                "upstreamOperations": sorted(operations),
                "upstreamCallerOperations": sorted(caller_operations),
                "upstreamProtocols": sorted(upstream_protocols),
                "swiftDispatchProtocols": sorted(swift_protocols),
                "missingSwiftProtocols": sorted(missing_protocols),
                "unexpectedSwiftProtocols": sorted(unexpected_protocols),
                "missingSwiftOperations": sorted(operations - swift_operations),
                "protocols": sorted({call["protocol"] for call in calls if call["protocol"] != "*"}),
                "failures": sorted({call["failure"]["operation"] for call in calls
                                    if call.get("failure", {}).get("operation")}),
                "nativeFailures": [call["failure"] for call in calls if call.get("failure")
                                   and call["failure"].get("code") != "bridgeAssertion"],
                "bridgeFailures": [call["failure"] for call in calls
                                   if call.get("failure", {}).get("code") == "bridgeAssertion"],
                "unrepresentedCapabilities": sorted({
                    capability for call in calls for capability in call.get("unrepresentedCapabilities", [])
                }),
                "assertionFailures": case.get("failureMessages", []),
                "scopeAudit": audited_scope,
            }
            if item["upstreamStatus"] in ["pending", "skipped"] or item["status"] in ["pending", "skipped"]:
                item["conformanceStatus"] = "not_executed"
            elif item["upstreamStatus"] != "passed":
                item["conformanceStatus"] = "upstream_failure"
            elif item["unrepresentedCapabilities"]:
                item["conformanceStatus"] = "interface_gap"
            elif audited_scope:
                if operations or upstream_protocols or swift_protocols or invalid_values:
                    item["conformanceStatus"] = "scope_audit_conflict"
                elif item["status"] != "passed" or item["bridgeFailures"]:
                    item["conformanceStatus"] = "mismatch"
                else:
                    item["conformanceStatus"] = "outside_scope"
            elif invalid_values or not item["swiftInvocations"] or not operations or item["missingSwiftOperations"]:
                item["conformanceStatus"] = "bridge_gap"
            elif missing_protocols or unexpected_protocols:
                item["conformanceStatus"] = "dispatch_mismatch"
            elif item["status"] != "passed" or item["bridgeFailures"]:
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
    for key, count in (baseline_names - swift_names).items():
        file, name = key
        for original in upstream_cases[key][swift_names[key]:swift_names[key] + count]:
            cases.append({
                "caseID": f"{Path(file).relative_to(upstream)}#missing:{len(cases)}:{name}",
                "upstreamTest": str(Path(file).relative_to(upstream)), "name": name,
                "upstreamStatus": original["status"], "status": "missing",
                "swiftInvocations": 0, "upstreamOperations": [], "upstreamCallerOperations": [], "upstreamProtocols": [],
                "swiftDispatchProtocols": [], "missingSwiftProtocols": [], "unexpectedSwiftProtocols": [],
                "missingSwiftOperations": [], "protocols": [], "failures": [], "nativeFailures": [],
                "unrepresentedCapabilities": [],
                "assertionFailures": ["The reference case was not collected by the Swift run; inspect suiteResults for setup/import failures"],
                "conformanceStatus": ("not_executed" if original["status"] in ["pending", "skipped"] else
                                      "bridge_gap" if original["status"] == "passed" else "upstream_failure"),
            })
    conformant = (
        all(code == 0 for code in exit_codes.values()) and bool(cases)
        and baseline_names == swift_names
        and any(case["conformanceStatus"] == "passed" for case in cases)
        and all(case["conformanceStatus"] in ["passed", "outside_scope"] for case in cases)
    )
    return conformant, cases


def offline_conformant(report):
    if not report["sourceStableDuringRun"] or report["casePattern"] is not None:
        return False
    if any(report["exitCodes"].values()):
        return False
    selected = [suite["path"] for suite in report["suites"]]
    if len(set(selected)) != len(selected) or len(selected) != report["reviewedInventoryCounts"]["adoptedByManifest"]:
        return False
    if report["reviewedInventoryCounts"]["notYetAdopted"]:
        return False
    if not any(case["conformanceStatus"] == "passed" for case in report["cases"]):
        return False
    for case in report["cases"]:
        if case["conformanceStatus"] in {"passed", "outside_scope"}:
            continue
        if case["conformanceStatus"] != "not_executed":
            return False
        if case["upstreamStatus"] not in {"pending", "skipped"} or case["status"] not in {"pending", "skipped"}:
            return False
        evidence = case.get("skipEvidence", {})
        reference, native = evidence.get("upstream", {}), evidence.get("swift", {})
        if not reference.get("explained") or reference != native:
            return False
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--upstream", type=Path)
    parser.add_argument("--test", action="append", dest="tests")
    parser.add_argument("--case", dest="case_pattern")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--build-root", type=Path,
                        help="Isolate SwiftPM build, dependency cache, configuration and security state")
    parser.add_argument("--offline", action="store_true",
                        help="Accept only full-manifest Native conformance with identical explained upstream skips")
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
    scope_audit = load_scope_audit(repo, upstream, manifest, revision)
    run(["git", "diff", "--quiet", "HEAD", "--", "packages/ai/src", "packages/ai/test"], cwd=upstream)
    identities = evidence_digests(repo)
    build = (args.output or repo / ".build/conformance").resolve()
    build.mkdir(parents=True, exist_ok=True)
    (build / "report.json").unlink(missing_ok=True)
    scratch = args.build_root.resolve() / "build" if args.build_root else repo / ".build/conformance/swift"
    swift_build = ["swift", "build", "-c", "release", "-Xswiftc", "-enable-testing", "--scratch-path", str(scratch)]
    if args.build_root:
        for option, directory in [("--cache-path", "cache"), ("--config-path", "configuration"),
                                  ("--security-path", "security")]:
            swift_build.extend([option, str(args.build_root.resolve() / directory)])
        swift_build.extend(["--disable-keychain", "--disable-netrc", "--force-resolved-versions",
                            "--disable-dependency-cache", "--manifest-cache", "local"])
    run(swift_build, cwd=repo)
    bin_path = Path(subprocess.check_output(
        [*swift_build, "--show-bin-path"],
        cwd=repo, text=True).strip())
    probe = bin_path / "swift-conformance-probe"
    objects = target_object_files(bin_path, "PiAIProviderRuntime")
    modules = bin_path / "Modules"
    if (bin_path / "PiAIProviderRuntime.o").is_file():
        objects = [bin_path / "PiAIProviderRuntime.o"]
        modules = bin_path
    if not objects:
        raise SystemExit("Swift provider-runtime object files were not produced")
    zstd_objects = target_object_files(bin_path, "libzstd")
    if not zstd_objects:
        raise SystemExit("Native zstd object files were not produced")
    objects.extend(zstd_objects)
    dependency_flags = ["-Xcc", "-fmodule-map-file=" + str(scratch / "checkouts/zstd/lib/module.modulemap")]
    heap_object = bin_path / "heap-observer.o"
    run(["xcrun", "clang", "-std=c11", "-c",
         str(repo / "Scripts/Conformance/HeapObserver.c"), "-o", str(heap_object)], cwd=repo)
    run(["xcrun", "swiftc", "-parse-as-library", "-g", "-enable-testing",
         "-import-objc-header", str(repo / "Scripts/Conformance/HeapObserver.h"),
         "-I", str(modules), *dependency_flags,
         *map(str, sorted((repo / "Scripts/Conformance").glob("*.swift"))),
         *map(str, objects), str(heap_object), "-o", str(probe)], cwd=repo)
    native_library = bin_path / "libConformanceStreamingJSON.dylib"
    run(["xcrun", "swiftc", "-parse-as-library", "-O", "-emit-library", "-enable-testing",
         "-I", str(modules), *dependency_flags, str(repo / "Scripts/Conformance/StreamingJSONExports.swift"),
         *map(str, objects), "-o", str(native_library)], cwd=repo)
    node = Path(subprocess.check_output(["node", "-p", "process.execPath"], text=True).strip()).resolve()
    node_include = node.parent.parent / "include/node"
    if not (node_include / "node_api.h").is_file():
        raise SystemExit(f"Installed Node headers are required for the Native parser bridge: {node_include}")
    native_module = bin_path / "streaming-json.node"
    run(["xcrun", "clang++", "-std=c++17", "-O2", "-bundle", "-undefined", "dynamic_lookup",
         "-I", str(node_include), str(repo / "Scripts/Conformance/StreamingJSONBridge.cc"),
         str(heap_object), str(native_library), "-o", str(native_module)], cwd=repo)
    environment = {
        key: value for key, value in os.environ.items()
        if not re.search(r"TOKEN|API_KEY|SECRET|ACCESS_KEY|CREDENTIAL|PROXY$", key, re.IGNORECASE)
        and not re.match(r"ANTHROPIC_|OPENAI_|AZURE_|AWS_|GOOGLE_|GCLOUD_|CLOUDFLARE_|COPILOT_", key)
    }
    environment.update({
        "PI_CONFORMANCE_UPSTREAM": str(upstream),
        "PI_CONFORMANCE_PROBE": str(probe),
        "PI_CONFORMANCE_OUTPUT": str(build),
        "PI_CONFORMANCE_JSON_MODULE": str(native_module),
        "PI_NO_LOCAL_LLM": "1",
    })
    command = [
        "node", str(upstream / "node_modules/vitest/vitest.mjs"), "run",
        "--config", str(repo / "Scripts/Conformance/vitest.config.mjs"),
        *[f"test/{name}" for name in suites],
    ]
    if args.case_pattern:
        command.extend(["--testNamePattern", args.case_pattern])
    reports = {}
    exit_codes = {}
    (build / "upstream-invocations.jsonl").write_text("")
    (build / "heap-observations.jsonl").write_text("")
    for implementation in ["upstream", "swift"]:
        environment["PI_CONFORMANCE_IMPLEMENTATION"] = implementation
        (build / f"{implementation}-skip-conditions.jsonl").write_text("")
        (build / "swift-invocations.jsonl").write_text("")
        (build / f"{implementation}.json").unlink(missing_ok=True)
        result = subprocess.run(command, cwd=upstream / "packages/ai", env=environment)
        exit_codes[implementation] = result.returncode
        reports[implementation] = json.loads((build / f"{implementation}.json").read_text())
    invocations = [json.loads(line) for line in (build / "swift-invocations.jsonl").read_text().splitlines()]
    upstream_invocations = [json.loads(line) for line in (build / "upstream-invocations.jsonl").read_text().splitlines()]
    conformant, cases = evaluate(upstream, reports, invocations, exit_codes, upstream_invocations,
                                require_case_instances=True, scope_audit=scope_audit)
    observed_skips = {implementation: [json.loads(line) for line in
        (build / f"{implementation}-skip-conditions.jsonl").read_text().splitlines()]
        for implementation in reports}
    skips = skip_evidence(upstream, reports, observed_skips)
    occurrences = Counter()
    for case in cases:
        key = (case["upstreamTest"], case["name"])
        occurrence = occurrences[key]
        occurrences[key] += 1
        if case["conformanceStatus"] == "not_executed":
            case["skipEvidence"] = skips.get((*key, occurrence), {})
    source_stable = identities == evidence_digests(repo)
    conformant = conformant and source_stable
    report = {
        "schemaVersion": 1,
        "upstreamRevision": revision,
        **identities,
        "sourceStableDuringRun": source_stable,
        "conformant": conformant,
        "acceptanceMode": "offline" if args.offline else "strict",
        "exitCodes": exit_codes,
        "scope": "unchanged upstream test files listed in suites",
        "reviewedInventoryCounts": {
            "adoptedByManifest": len(manifest["suites"]),
            "outsideScope": sum(reason.startswith("Outside") for reason in manifest["excludedSuites"].values()),
            "notYetAdopted": sum(not reason.startswith("Outside") for reason in manifest["excludedSuites"].values()),
        },
        "casePattern": args.case_pattern,
        "offlineConditions": "External sockets are blocked, credential environment variables are removed, test/oauth.ts resolves no persisted credentials, and upstream PI_NO_LOCAL_LLM=1 disables local model downloads and service launches; upstream mocks and loopback fixture servers remain available",
        "bridgeBoundary": "Swift ProviderRuntimeKernel, wire adapters, catalog, and represented OAuth login/refresh adapters; upstream transcript assembly, fixture credentials, host login UI, SDK transports, and unbridged exports remain test infrastructure; general SDK retry policies are not covered",
        "mismatchMeaning": "An original assertion differs across the bridge; ownership and bridge triage are required before classifying it as a Swift runtime defect",
        "suites": [{
            "path": f"packages/ai/test/{suite}",
            "sha256": hashlib.sha256((upstream / "packages/ai/test" / suite).read_bytes()).hexdigest(),
        } for suite in suites],
        "statusCounts": dict(Counter(case["status"] for case in cases)),
        "conformanceCounts": dict(Counter(case["conformanceStatus"] for case in cases)),
        "skipEvidenceCounts": {
            "explainedInBothRuns": sum(case["conformanceStatus"] == "not_executed" and
                all(case.get("skipEvidence", {}).get(implementation, {}).get("explained")
                    for implementation in reports) for case in cases),
            "unexplained": sum(case["conformanceStatus"] == "not_executed" and
                not all(case.get("skipEvidence", {}).get(implementation, {}).get("explained")
                        for implementation in reports) for case in cases),
        },
        "nativeEvidenceCounts": {
            "operationRecords": sum(call.get("entrypoint") not in ["value-access", "value-produced"] for call in invocations),
            "cachedValueAccessRecords": sum(call.get("entrypoint") == "value-access" for call in invocations),
            "valueOrigins": sum(call.get("entrypoint") == "value-produced" for call in invocations),
        },
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
            "disposition": ("not_selected_in_this_run" if path.name in manifest["suites"] else
                            "outside_scope" if manifest["excludedSuites"][path.name].startswith("Outside") else
                            "not_yet_adopted"),
            "reason": manifest["excludedSuites"].get(path.name, "Adopted by the manifest but not selected in this focused run"),
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        } for path in sorted((upstream / "packages/ai/test").glob("*.test.ts")) if path.name not in suites],
        "cases": cases,
    }
    report["offlineConformant"] = offline_conformant(report)
    (build / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Conformance: {conformant}; upstream suites={len(suites)}; cases={len(cases)}; Native evidence records={len(invocations)}")
    print(f"Report: {build / 'report.json'}")
    if args.offline:
        print(f"Offline Native conformance: {report['offlineConformant']}; unexecuted cases remain not_executed")
    return 0 if (report["offlineConformant"] if args.offline else conformant) else 1


if __name__ == "__main__":
    sys.exit(main())
