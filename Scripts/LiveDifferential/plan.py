#!/usr/bin/env python3
"""Create an explicit plan for SwiftChat Dev's Acceptance menu; contains no credentials."""
import argparse
import json
import math
from pathlib import Path
import subprocess


def make_plan(args):
    root = Path(__file__).resolve().parents[2]
    manifest = json.loads((root / "Scripts/LiveDifferential/scenarios.json").read_text())
    upstream = args.upstream.resolve()
    revision = subprocess.check_output(["git", "-C", str(upstream), "rev-parse", "HEAD"], text=True).strip()
    if revision != manifest["upstreamRevision"]:
        raise ValueError("upstream_revision_mismatch")
    selections = []
    for item in args.model:
        provider, separator, model = item.partition("/")
        if not separator or not model:
            raise ValueError("model_selection_requires_provider_and_model")
        selections.append({"providerID": provider, "modelID": model})
    known_cases = {case["id"] for case in manifest["cases"]}
    if args.case and not set(args.case).issubset(known_cases):
        raise ValueError("unknown_scenario")
    if args.mode == "run":
        if not selections or not args.inventory:
            raise ValueError("run_requires_inventory_and_explicit_models")
        inventory = json.loads(args.inventory.read_text())
        models = {(p["id"], m["id"]): m for p in inventory for m in p["models"]}
        if any((s["providerID"], s["modelID"]) not in models for s in selections):
            raise ValueError("selection_absent_from_inventory")
        selected = {f'{s["providerID"]}/{s["modelID"]}': s for s in selections}
        for item in args.effort:
            model, separator, effort = item.rpartition("=")
            if not separator or model not in selected:
                raise ValueError("effort_requires_selected_provider_and_model")
            selection = selected[model]
            model_info = models[selection["providerID"], selection["modelID"]]
            if effort not in model_info.get("supportedReasoningEfforts", []):
                raise ValueError("effort_not_advertised_by_model")
            selection.setdefault("efforts", []).append(effort)
    plan = {"mode": args.mode, "sdkDirectory": root.as_uri(), "upstream": upstream.as_uri(),
            "node": args.node.resolve().as_uri(), "outputDirectory": args.evidence.resolve().as_uri(),
            "selections": selections}
    if args.case:
        plan["cases"] = args.case
    if args.catalog_output_cap:
        plan["useCatalogOutputCap"] = True
    if args.deadline is not None:
        if not math.isfinite(args.deadline) or args.deadline <= 0:
            raise ValueError("observation_deadline_must_be_finite_and_positive")
        plan["caseDeadlineSeconds"] = args.deadline
    return plan


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("inventory", "run"), required=True)
    parser.add_argument("--upstream", type=Path, required=True)
    parser.add_argument("--node", type=Path, required=True)
    parser.add_argument("--inventory", type=Path)
    parser.add_argument("--model", action="append", default=[], help="providerID/modelID; repeat for each exact model")
    parser.add_argument("--effort", action="append", default=[],
                        help="providerID/modelID=level; repeat to choose advertised levels for reasoning cases")
    parser.add_argument("--case", action="append", help="Explicit scenario IDs; omitted means all manifest scenarios")
    parser.add_argument("--deadline", type=float, help="Optional observation budget per implementation, in seconds")
    parser.add_argument("--catalog-output-cap", action="store_true",
                        help="Pass the catalog model's output ceiling explicitly to both implementations")
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        plan = make_plan(args)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.error(str(error))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(plan, indent=2) + "\n")
    print(args.output.resolve())


if __name__ == "__main__":
    main()
