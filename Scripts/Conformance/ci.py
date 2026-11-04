#!/usr/bin/env python3
"""Run the complete offline gate from fresh dependency and build state."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def isolated_environment(parent, root):
    environment = {key: parent[key] for key in ["PATH", "TMPDIR", "DEVELOPER_DIR", "SDKROOT", "LANG", "LC_ALL"]
                   if key in parent}
    environment.update({
        "PYTHONDONTWRITEBYTECODE": "1",
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
        "npm_config_userconfig": str(root / "npm-userconfig"),
        "npm_config_globalconfig": str(root / "npm-globalconfig"),
        "npm_config_cache": str(root / "npm"),
        "CLANG_MODULE_CACHE_PATH": str(root / "clang"),
        "SWIFTPM_MODULECACHE_OVERRIDE": str(root / "swift-modules"),
        "PI_AI_SWIFT_UPSTREAM_CACHE": str(root / "upstream"),
        "SCHEMA6_UPSTREAM": str(root / "upstream"),
    })
    # Preserve explicitly supplied Git routing, without inheriting account configuration.
    config = [("credential.helper", "")]
    for index in range(int(parent.get("GIT_CONFIG_COUNT", "0"))):
        key = parent[f"GIT_CONFIG_KEY_{index}"]
        if key in {"http.proxy", "http.version"}:
            config.append((key, parent[f"GIT_CONFIG_VALUE_{index}"]))
    environment["GIT_CONFIG_COUNT"] = str(len(config))
    for index, (key, value) in enumerate(config):
        environment[f"GIT_CONFIG_KEY_{index}"] = key
        environment[f"GIT_CONFIG_VALUE_{index}"] = value
    return environment


def swift_options(root):
    options = ["--disable-keychain", "--disable-netrc", "--force-resolved-versions"]
    for option, directory in [("--scratch-path", "build"), ("--cache-path", "cache"),
                              ("--config-path", "configuration"), ("--security-path", "security")]:
        options.extend([option, str(root / directory)])
    return options


def write_evidence(output, evidence):
    (output / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    checksums = []
    for path in sorted(output.rglob("*")):
        if path.is_file() and path.name != "SHA256SUMS":
            checksums.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.relative_to(output)}\n")
    (output / "SHA256SUMS").write_text("".join(checksums))


def execute_logged(command, *, cwd, environment, log):
    with log.open("w") as handle:
        with subprocess.Popen(command, cwd=cwd, env=environment, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True, bufsize=1) as process:
            for line in process.stdout:
                handle.write(line)
                print(line, end="", flush=True)
            return process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New evidence directory; must not already exist")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    output.mkdir(parents=True)
    logs = output / "logs"
    logs.mkdir()
    lock = json.loads((repo / "Upstream.lock.json").read_text())
    evidence = {
        "schemaVersion": 1,
        "repositoryRevision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
        "worktreeClean": not bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=repo, text=True)),
        "upstreamRevision": lock["revision"],
        "cachePolicy": "Fresh temporary upstream, npm, SwiftPM and compiler caches for every invocation",
        "credentialPolicy": "Allowlisted process environment; no Git helpers, npm user config, SwiftPM Keychain or netrc",
        "executionNetworkPolicy": "Conformance permits mocks and loopback only; public dependency bootstrap requires network",
        "tools": {},
        "steps": [],
        "exitCode": None,
    }
    exit_code = 1
    try:
        with tempfile.TemporaryDirectory(prefix="pi-ai-offline-", dir=os.environ.get("RUNNER_TEMP")) as directory:
            root = Path(directory)
            environment = isolated_environment(os.environ, root)

            def run(name, command, *, capture=False, cwd=repo):
                log = logs / f"{name}.log"
                step = {"name": name, "command": list(map(str, command)), "cwd": str(cwd),
                        "log": str(log.relative_to(output)), "exitCode": None}
                evidence["steps"].append(step)
                write_evidence(output, evidence)
                print(f"Running {name}; log: {log}", flush=True)
                exit_code = execute_logged(command, cwd=cwd, environment=environment, log=log)
                step["exitCode"] = exit_code
                write_evidence(output, evidence)
                if exit_code:
                    raise subprocess.CalledProcessError(exit_code, command)
                if capture:
                    return log.read_text().strip()

            for name, command in [("xcode", ["xcodebuild", "-version"]), ("swift", ["swift", "--version"]),
                                  ("node", ["node", "--version"]), ("npm", ["npm", "--version"]),
                                  ("python", [sys.executable, "--version"]), ("platform", ["uname", "-sm"]),
                                  ("os", ["sw_vers"]), ("cpu", ["sysctl", "-n", "machdep.cpu.brand_string"])]:
                evidence["tools"][name] = run(f"tool-{name}", command, capture=True)
            upstream = root / "upstream"
            run("upstream-init", ["git", "init", str(upstream)])
            run("upstream-origin", ["git", "-C", str(upstream), "remote", "add", "origin", lock["repository"]])
            run("upstream-fetch", ["git", "-C", str(upstream), "fetch", "--depth", "1", "origin", lock["revision"]])
            run("upstream-checkout", ["git", "-C", str(upstream), "checkout", "--detach", lock["revision"]])
            run("upstream-dependencies", ["npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund"], cwd=upstream)
            catalog = output / "exact-source-catalog.json"
            run("source-catalog", [sys.executable, "-B", "Scripts/replay-schema6-catalog.py", "--upstream", str(upstream),
                                   "--output", str(catalog), "--generated-data-output",
                                   str(upstream / "packages/ai/src/providers/data")])
            environment["SCHEMA6_CATALOG_PATH"] = str(catalog)
            run("verify-pinned-upstream", ["bash", "Scripts/check-upstream.sh", "--explain", "--candidate", lock["revision"]])
            run("reporting-tests", [sys.executable, "-B", "-m", "unittest", "discover", "-s", "Scripts/tests"])
            run("swift-format", ["swift", "format", "lint", "--recursive", "Sources", "Tests", "Package.swift"])
            run("native-tests", ["swift", "test", *swift_options(root / "native")])
            run("offline-conformance", [sys.executable, "-B", "Scripts/Conformance/run.py", "--offline", "--upstream",
                                        str(upstream), "--output", str(output), "--build-root", str(root / "conformance")])
            report = json.loads((output / "report.json").read_text())
            evidence["result"] = {key: report[key] for key in ["offlineConformant", "conformant", "conformanceCounts",
                                                              "swiftSourceSHA256", "harnessSHA256"]}
            exit_code = 0
    except subprocess.CalledProcessError as error:
        exit_code = error.returncode if error.returncode > 0 else 1
        print("Offline CI failed; inspect evidence.json and the step logs.", file=sys.stderr)
    finally:
        evidence["exitCode"] = exit_code
        write_evidence(output, evidence)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
