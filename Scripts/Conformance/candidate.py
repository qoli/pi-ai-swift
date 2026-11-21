"""Offline inputs for the reviewed v1.6.0 lock candidate."""
import base64
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def profile(repo, revision, accepted):
    directory = repo / "Scripts/Conformance"
    data = json.loads((directory / "candidate-v1.6.0.json").read_text())
    if data["revision"] != revision or data["baseRevision"] != accepted:
        raise ValueError("No reviewed candidate profile for this exact candidate and accepted revision")
    for name, key in [("suites.json", "baseManifestSHA256"), ("scope-audit.json", "baseScopeAuditSHA256")]:
        if sha256(directory / name) != data[key]:
            raise ValueError(f"Candidate review needs rebasing: {name}")
    return data


def inventory(upstream, manifest, review):
    suites = sorted(manifest["suites"] + review["addSuites"])
    excluded = {**manifest["excludedSuites"], **review["excludedSuites"]}
    for name in review["removeExcludedSuites"]:
        del excluded[name]
    discovered = {str(p.relative_to(upstream / "packages/ai/test"))
                  for p in (upstream / "packages/ai/test").rglob("*.test.ts")}
    if (len(suites) != len(set(suites)) or set(suites) & excluded.keys()
            or discovered != set(suites) | excluded.keys()):
        raise ValueError("Candidate suite inventory differs from the reviewed list")
    return {"suites": suites, "excludedSuites": excluded}


def catalog_identity(upstream):
    data = json.loads((upstream / "packages/ai/src/providers/data/.manifest.json").read_text())
    del data["generatedAt"]
    return hashlib.sha256(json.dumps(data, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def stage_native_package(repo, upstream, destination):
    """Build the candidate with its real SwiftPM resource, leaving the accepted bundle intact."""
    destination.mkdir()
    for name in ("Package.swift", "Package.resolved"):
        shutil.copyfile(repo / name, destination / name)
    shutil.copytree(repo / "Sources", destination / "Sources")
    (destination / "Tests").symlink_to(repo / "Tests", target_is_directory=True)
    resource = destination / "Sources/PiAIProviderRuntime/Resources/BuiltinCatalog.json"
    subprocess.run(["node", str(repo / "Scripts/generate-source-catalog.mjs"), str(upstream),
                    str(repo / "Scripts/Conformance/candidate-v1.6.0.json"), str(resource)], check=True)
    return sha256(resource)


def prepare_catalog(upstream, tarball, review):
    # Use the release's catalog bytes. Regenerating from older public inputs
    # can omit models which this exact release's original tests require.
    with tarball.open("rb") as handle:
        digest = hashlib.sha512(handle.read()).digest()
        if "sha512-" + base64.b64encode(digest).decode() != review["publishedPackage"]["integrity"]:
            raise ValueError("Published npm package integrity mismatch")
        handle.seek(0)
        with tarfile.open(fileobj=handle, mode="r:gz") as archive:
            directory = upstream / "packages/ai/src/providers/data"
            directory.mkdir(parents=True, exist_ok=True)
            for member in archive.getmembers():
                path = Path(member.name)
                if member.isfile() and path.parent == Path("package/dist/providers/data") and path.suffix == ".json":
                    (directory / path.name).write_bytes(archive.extractfile(member).read())
    subprocess.run(["node", "scripts/check-model-data.ts"], cwd=upstream / "packages/ai", check=True)
    if catalog_identity(upstream) != review["catalogSHA256"]:
        raise ValueError("Candidate catalog differs from the reviewed release")


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Prepare the published model data in a disposable exact candidate checkout")
    parser.add_argument("--upstream", type=Path, required=True)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--package-tarball", required=True, type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    upstream = args.upstream.resolve()
    lock = json.loads((repo / "Upstream.lock.json").read_text())
    review = profile(repo, args.candidate, lock["revision"])
    if subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=upstream, text=True).strip() != review["revision"]:
        parser.error("Candidate checkout revision mismatch")
    prepare_catalog(upstream, args.package_tarball, review)
