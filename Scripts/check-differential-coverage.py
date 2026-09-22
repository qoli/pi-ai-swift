#!/usr/bin/env python3

import json
import pathlib
import sys


ALLOWED_EXPRESSIBILITY = {
    "providerRequest",
    "context",
    "unsupported",
    "notComparableInput",
}
ALLOWED_BRANCH_STATUSES = {"covered", "uncovered", "blocked"}
INVENTORY_CLASS_CONFIG = {
    "responseEvents": {
        "path": "Fixtures/Differential/ResponseBranchInventory.json",
        "statusKey": "responseCoverageStatus",
    },
    "typedFailures": {
        "path": "Fixtures/Differential/FailureBranchInventory.json",
        "statusKey": "failureCoverageStatus",
    },
}


def load_json(path: pathlib.Path) -> object:
    if not path.is_file():
        raise SystemExit(f"differential coverage input is missing: {path}")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise SystemExit(f"malformed JSON in {path}: {error}") from error


def executable_request_cases(repo: pathlib.Path) -> dict[str, set[str]]:
    rich = load_json(repo / "Fixtures/Differential/Oracle/request-rich.json")
    replay = load_json(repo / "Fixtures/Differential/Oracle/request-replay.json")
    result: dict[str, set[str]] = {}
    rich_case_id = rich.get("caseID")
    rich_protocols = rich.get("protocols")
    if not isinstance(rich_case_id, str) or not isinstance(rich_protocols, dict):
        raise SystemExit("request-rich oracle has malformed identity or protocols")
    for protocol_id in rich_protocols:
        result.setdefault(protocol_id, set()).add(rich_case_id)

    replay_scenarios = replay.get("scenarios")
    if not isinstance(replay_scenarios, dict):
        raise SystemExit("request-replay oracle has malformed scenarios")
    for case_id, protocols in replay_scenarios.items():
        if not isinstance(case_id, str) or not isinstance(protocols, dict):
            raise SystemExit("request-replay oracle has malformed case coverage")
        for protocol_id in protocols:
            result.setdefault(protocol_id, set()).add(case_id)

    secondary = load_json(repo / "Fixtures/Differential/Oracle/request-secondary.json")
    for case_id, observation in secondary.get("cases", {}).items():
        if not isinstance(observation, dict) or not isinstance(
            observation.get("protocolID"), str
        ):
            raise SystemExit("request-secondary oracle has malformed case coverage")
        result.setdefault(observation["protocolID"], set()).add(case_id)

    request_domain = load_json(repo / "Fixtures/Differential/Oracle/request-domain.json")
    domain_case_id = request_domain.get("caseID")
    if not isinstance(domain_case_id, str):
        raise SystemExit("request-domain oracle has malformed case identity")
    for protocol_id in {
        "anthropic-messages", "azure-openai-responses", "bedrock-converse-stream",
        "google-generative-ai", "google-vertex", "mistral-conversations",
        "openai-codex-responses", "openai-completions", "openai-responses",
        "pi-messages",
    }:
        result.setdefault(protocol_id, set()).add(domain_case_id)
        for additional_case_id in request_domain.get("additionalCases", {}):
            result.setdefault(protocol_id, set()).add(additional_case_id)

    provider_options = load_json(
        repo / "Fixtures/Differential/Oracle/provider-options.json"
    ).get("cases", {})
    provider_option_protocols = {
        "openrouter-completions-session": ["openai-completions"],
        "baseten-completions-session": ["openai-completions"],
        "openrouter-responses-session": ["openai-responses"],
        "openrouter-anthropic-session": ["anthropic-messages"],
        "opencode-session-wrapper": [
            "anthropic-messages", "google-generative-ai",
            "openai-completions", "openai-responses",
        ],
        "vllm-priority": ["openai-completions"],
        "responses-max-output-disabled": ["openai-responses"],
    }
    for case_id, protocols in provider_option_protocols.items():
        if case_id not in provider_options:
            raise SystemExit(f"provider-options oracle is missing {case_id}")
        for protocol_id in protocols:
            result.setdefault(protocol_id, set()).add(case_id)

    anthropic_bedrock_fixture = load_json(
        repo / "Fixtures/Differential/Cases/request-anthropic-bedrock.json"
    )
    anthropic_bedrock_oracle = load_json(
        repo / "Fixtures/Differential/Oracle/request-anthropic-bedrock.json"
    )
    observed_ab = anthropic_bedrock_oracle.get("scenarios", {})
    for scenario in anthropic_bedrock_fixture.get("scenarios", []):
        case_id = scenario.get("caseID")
        protocol_id = scenario.get("protocolID")
        if case_id not in observed_ab or not isinstance(protocol_id, str):
            raise SystemExit("Anthropic/Bedrock request oracle has malformed case coverage")
        result.setdefault(protocol_id, set()).add(case_id)

    google = load_json(repo / "Fixtures/Differential/Oracle/request-google-branches.json")
    for case_id, protocols in google.get("cases", {}).items():
        if not isinstance(protocols, dict):
            raise SystemExit("Google request oracle has malformed case coverage")
        for protocol_id in protocols:
            result.setdefault(protocol_id, set()).add(case_id)

    openai_fixture = load_json(
        repo / "Fixtures/OpenAIRequestBranches/Cases/request-branches.json"
    )
    openai_oracle = load_json(
        repo / "Fixtures/OpenAIRequestBranches/Oracle/request-branches.json"
    )
    observed_openai = openai_oracle.get("cases", {})
    for case in openai_fixture.get("cases", []):
        case_id = case.get("id")
        protocol_id = case.get("protocolID")
        if case_id not in observed_openai or not isinstance(protocol_id, str):
            raise SystemExit("OpenAI request oracle has malformed case coverage")
        result.setdefault(protocol_id, set()).add(case_id)
    for case in openai_fixture.get("matrices", {}).get("additionalCases", []):
        case_id = case.get("id")
        protocol_id = case.get("protocolID")
        if case_id not in observed_openai or not isinstance(protocol_id, str):
            raise SystemExit("OpenAI request matrix has malformed additional case coverage")
        result.setdefault(protocol_id, set()).add(case_id)
    openai_matrix_prefixes = {
        "openai-completions.": "openai-completions",
        "openai-responses.": "openai-responses",
        "azure-openai-responses.": "azure-openai-responses",
        "openai-codex-responses.": "openai-codex-responses",
        "completions.": "openai-completions",
        "responses.": "openai-responses",
        "azure.": "azure-openai-responses",
        "codex.": "openai-codex-responses",
    }
    declared_openai_ids = {
        case.get("id") for case in openai_fixture.get("cases", [])
    } | {
        case.get("id")
        for case in openai_fixture.get("matrices", {}).get("additionalCases", [])
    }
    for case_id in set(observed_openai) - declared_openai_ids:
        protocol_id = next(
            (
                value
                for prefix, value in openai_matrix_prefixes.items()
                if case_id.startswith(prefix)
            ),
            None,
        )
        if protocol_id is None:
            raise SystemExit(f"OpenAI request matrix case has no protocol mapping: {case_id}")
        result.setdefault(protocol_id, set()).add(case_id)

    azure_configuration = load_json(
        repo / "Fixtures/AzureOpenAIConfiguration/Oracle/configuration.json"
    )
    for case_id in azure_configuration.get("cases", {}):
        if not isinstance(case_id, str):
            raise SystemExit("Azure configuration oracle has malformed case coverage")
        result.setdefault("azure-openai-responses", set()).add(case_id)
    return result


def validate_request_branch_inventory(
    repo: pathlib.Path,
    wire_protocols: set[str],
) -> tuple[dict[str, set[str]], dict[str, list[str]]]:
    lock = load_json(repo / "Upstream.lock.json")
    inventory = load_json(
        repo / "Fixtures/Differential/RequestBranchInventory.json"
    )
    if inventory.get("schemaVersion") != 1:
        raise SystemExit("unsupported request branch inventory schema")
    if inventory.get("upstreamRevision") != lock.get("revision"):
        raise SystemExit("request branch inventory revision does not match upstream lock")
    if inventory.get("requestCoverageStatus") not in {"incomplete", "complete"}:
        raise SystemExit("request branch inventory has invalid coverage status")

    invalid_evidence = inventory.get("invalidSourceEvidence", {})
    if not isinstance(invalid_evidence, dict) or any(
        not isinstance(case_id, str) or not isinstance(reason, str) or not reason
        for case_id, reason in invalid_evidence.items()
    ):
        raise SystemExit("request branch inventory has malformed invalidSourceEvidence")

    executable = executable_request_cases(repo)
    branches = inventory.get("branches")
    if not isinstance(branches, list) or not branches:
        raise SystemExit("request branch inventory must contain branches")

    branch_ids: set[str] = set()
    required_by_protocol = {protocol_id: set() for protocol_id in wire_protocols}
    gaps_by_protocol = {protocol_id: [] for protocol_id in wire_protocols}
    for branch in branches:
        if not isinstance(branch, dict):
            raise SystemExit("request branch inventory entries must be objects")
        branch_id = branch.get("id")
        if not isinstance(branch_id, str) or not branch_id:
            raise SystemExit("request branch inventory entry lacks an id")
        if branch_id in branch_ids:
            raise SystemExit(f"duplicate request branch id: {branch_id}")
        branch_ids.add(branch_id)

        required = branch.get("required")
        protocols = branch.get("protocols")
        variants = branch.get("variants")
        symbols = branch.get("sourceSymbols")
        expected = branch.get("expected")
        expressibility = branch.get("expressibility")
        status = branch.get("status")
        cases = branch.get("cases")
        if not isinstance(required, bool):
            raise SystemExit(f"request branch {branch_id} lacks required boolean")
        if (
            not isinstance(protocols, list)
            or not protocols
            or any(not isinstance(value, str) or not value for value in protocols)
            or len(protocols) != len(set(protocols))
        ):
            raise SystemExit(f"request branch {branch_id} has malformed protocols")
        unknown_protocols = set(protocols) - wire_protocols
        if unknown_protocols:
            raise SystemExit(
                f"request branch {branch_id} has unknown protocols: "
                f"{sorted(unknown_protocols)}"
            )
        if (
            not isinstance(variants, list)
            or not variants
            or any(not isinstance(value, str) or not value for value in variants)
        ):
            raise SystemExit(f"request branch {branch_id} has malformed variants")
        if (
            not isinstance(symbols, list)
            or not symbols
            or any(not isinstance(value, str) or not value for value in symbols)
        ):
            raise SystemExit(f"request branch {branch_id} lacks source symbols")
        if not isinstance(expected, str) or not expected:
            raise SystemExit(f"request branch {branch_id} lacks expected behavior")
        if expressibility not in ALLOWED_EXPRESSIBILITY:
            raise SystemExit(
                f"request branch {branch_id} has invalid expressibility: {expressibility}"
            )
        if status not in ALLOWED_BRANCH_STATUSES:
            raise SystemExit(f"request branch {branch_id} has invalid status: {status}")
        if not isinstance(cases, list):
            raise SystemExit(f"request branch {branch_id} cases must be an array")

        case_coverage = {protocol_id: set() for protocol_id in protocols}
        variant_protocols = branch.get("variantProtocols", {})
        if not isinstance(variant_protocols, dict):
            raise SystemExit(f"request branch {branch_id} has malformed variantProtocols")
        unknown_variant_keys = set(variant_protocols) - set(variants)
        if unknown_variant_keys:
            raise SystemExit(
                f"request branch {branch_id} has unknown variantProtocols keys: "
                f"{sorted(unknown_variant_keys)}"
            )
        applicable: dict[str, set[str]] = {}
        for variant in variants:
            values = variant_protocols.get(variant, protocols)
            if (
                not isinstance(values, list)
                or not values
                or any(not isinstance(value, str) for value in values)
                or set(values) - set(protocols)
            ):
                raise SystemExit(
                    f"request branch {branch_id}/{variant} has malformed protocol applicability"
                )
            applicable[variant] = set(values)
        matrix = {protocol_id: set() for protocol_id in protocols}
        for case in cases:
            if not isinstance(case, dict):
                raise SystemExit(f"request branch {branch_id} has malformed case")
            case_id = case.get("caseID")
            case_protocols = case.get("protocols")
            case_variants = case.get("coversVariants", [])
            if (
                not isinstance(case_id, str)
                or not case_id
                or not isinstance(case_protocols, list)
                or not case_protocols
            ):
                raise SystemExit(f"request branch {branch_id} has malformed case identity")
            if (
                not isinstance(case_variants, list)
                or any(
                    not isinstance(value, str) or value not in variants
                    for value in case_variants
                )
            ):
                raise SystemExit(
                    f"request branch {branch_id}/{case_id} has invalid coversVariants"
                )
            if case_id in invalid_evidence:
                raise SystemExit(
                    f"request branch {branch_id} counts invalid source evidence "
                    f"{case_id}: {invalid_evidence[case_id]}"
                )
            for protocol_id in case_protocols:
                if protocol_id not in protocols:
                    raise SystemExit(
                        f"request branch {branch_id}/{case_id} names inapplicable "
                        f"protocol {protocol_id}"
                    )
                if case_id not in executable.get(protocol_id, set()):
                    raise SystemExit(
                        f"request branch {branch_id} lacks executable source-derived "
                        f"case {case_id} for {protocol_id}"
                    )
                case_coverage[protocol_id].add(case_id)
                matrix[protocol_id].update(case_variants)

        if status == "covered":
            if expressibility in {"unsupported", "notComparableInput"}:
                raise SystemExit(
                    f"request branch {branch_id} cannot be covered with "
                    f"expressibility={expressibility}"
                )
            missing_case_protocols = sorted(
                protocol_id
                for protocol_id, case_ids in case_coverage.items()
                if not case_ids
            )
            if missing_case_protocols:
                raise SystemExit(
                    f"covered request branch {branch_id} lacks executable cases for "
                    f"{missing_case_protocols}"
                )
            if branch.get("missingVariants"):
                raise SystemExit(
                    f"covered request branch {branch_id} still lists missingVariants"
                )
            missing_cells = sorted(
                f"{protocol_id}:{variant}"
                for variant, applicable_protocols in applicable.items()
                for protocol_id in applicable_protocols
                if variant not in matrix[protocol_id]
            )
            if missing_cells:
                raise SystemExit(
                    f"covered request branch {branch_id} lacks executable protocol/variant "
                    f"coverage: {missing_cells}"
                )
        elif status == "blocked":
            if expressibility not in {"unsupported", "notComparableInput"}:
                raise SystemExit(
                    f"blocked request branch {branch_id} must use unsupported or "
                    "notComparableInput expressibility"
                )
            if not isinstance(branch.get("blocker"), str) or not branch["blocker"]:
                raise SystemExit(f"blocked request branch {branch_id} lacks blocker")

        if required:
            for protocol_id in protocols:
                required_by_protocol[protocol_id].add(branch_id)
                if status != "covered":
                    missing_for_protocol = sorted(
                        variant
                        for variant, applicable_protocols in applicable.items()
                        if protocol_id in applicable_protocols
                        and variant not in matrix[protocol_id]
                    )
                    gaps_by_protocol[protocol_id].append(
                        f"{branch_id}:{status}:{expressibility}:"
                        f"{','.join(missing_for_protocol) or 'status-not-covered'}"
                    )

    request_closed = {
        protocol_id: required
        for protocol_id, required in required_by_protocol.items()
        if required and not gaps_by_protocol[protocol_id]
    }
    calculated_status = (
        "complete"
        if len(request_closed) == len(wire_protocols)
        else "incomplete"
    )
    if inventory["requestCoverageStatus"] != calculated_status:
        raise SystemExit(
            "request branch inventory status is stale: "
            f"recorded={inventory['requestCoverageStatus']} calculated={calculated_status}"
        )
    return request_closed, gaps_by_protocol


def executable_cases_from_evidence(
    repo: pathlib.Path,
    inventory: dict,
    case_class: str,
) -> dict[str, set[str]]:
    """Return only cases backed by both a checked-in oracle and its replay test."""
    evidence_sources = inventory.get("evidenceSources")
    if not isinstance(evidence_sources, list) or not evidence_sources:
        raise SystemExit(f"{case_class} branch inventory lacks evidenceSources")
    executable: dict[str, set[str]] = {}
    for evidence in evidence_sources:
        if not isinstance(evidence, dict):
            raise SystemExit(f"{case_class} evidence source must be an object")
        oracle_rel = evidence.get("oracle")
        test_rel = evidence.get("test")
        shape = evidence.get("shape")
        if not isinstance(oracle_rel, str) or not isinstance(test_rel, str):
            raise SystemExit(f"{case_class} evidence source lacks oracle/test paths")
        oracle_path = repo / oracle_rel
        test_path = repo / test_rel
        oracle = load_json(oracle_path)
        if not test_path.is_file():
            raise SystemExit(f"{case_class} replay test is missing: {test_path}")
        test_text = test_path.read_text(encoding="utf-8")
        oracle_name = oracle_path.stem
        if oracle_name not in test_text:
            raise SystemExit(
                f"{case_class} replay test does not reference oracle {oracle_name}: "
                f"{test_path}"
            )
        if oracle.get("upstreamRevision") != inventory.get("upstreamRevision"):
            raise SystemExit(
                f"{case_class} oracle revision drift: {oracle_rel}"
            )

        if shape == "protocols":
            case_id = oracle.get("caseID")
            protocols = oracle.get("protocols")
            if not isinstance(case_id, str) or not isinstance(protocols, dict):
                raise SystemExit(f"malformed {case_class} protocols oracle: {oracle_rel}")
            for protocol_id in protocols:
                executable.setdefault(protocol_id, set()).add(case_id)
        elif shape == "named-scenarios":
            cases_rel = evidence.get("cases")
            collection = evidence.get("collection")
            if not isinstance(cases_rel, str) or not isinstance(collection, str) or not collection:
                raise SystemExit(f"{case_class} named scenarios lack cases/collection")
            fixture = load_json(repo / cases_rel)
            scenarios = fixture.get(collection)
            observed = oracle.get(collection)
            if (
                fixture.get("upstreamRevision") != inventory.get("upstreamRevision")
                or not isinstance(scenarios, list)
                or not scenarios
                or not isinstance(observed, dict)
                or collection not in test_text
            ):
                raise SystemExit(f"malformed {case_class} named scenarios: {cases_rel}/{collection}")
            identifiers = set()
            for scenario in scenarios:
                case_id = scenario.get("caseID") if isinstance(scenario, dict) else None
                protocol_id = scenario.get("protocolID") if isinstance(scenario, dict) else None
                if (
                    not isinstance(case_id, str) or not case_id
                    or not isinstance(protocol_id, str) or not protocol_id
                    or case_id in identifiers
                    or not isinstance(observed.get(case_id), dict)
                ):
                    raise SystemExit(f"invalid {case_class} named scenario: {case_id}")
                identifiers.add(case_id)
                executable.setdefault(protocol_id, set()).add(case_id)
            if identifiers != set(observed):
                raise SystemExit(f"{case_class} named scenario set drift: {cases_rel}/{collection}")
        elif shape == "scenarios-from-case-file":
            cases_rel = evidence.get("cases")
            if not isinstance(cases_rel, str):
                raise SystemExit(f"{case_class} scenario evidence lacks cases path")
            cases = load_json(repo / cases_rel)
            observed = oracle.get("scenarios")
            if not isinstance(observed, dict):
                raise SystemExit(f"malformed {case_class} scenarios oracle: {oracle_rel}")
            for scenario in cases.get("scenarios", []):
                case_id = scenario.get("caseID")
                protocol_id = scenario.get("protocolID")
                if (
                    not isinstance(case_id, str)
                    or not isinstance(protocol_id, str)
                    or case_id not in observed
                ):
                    raise SystemExit(f"malformed {case_class} scenario evidence: {cases_rel}")
                executable.setdefault(protocol_id, set()).add(case_id)
        elif shape == "case-protocol-map":
            cases_rel = evidence.get("cases")
            if not isinstance(cases_rel, str):
                raise SystemExit(f"{case_class} case-map evidence lacks cases path")
            fixture = load_json(repo / cases_rel)
            cases = oracle.get("cases")
            if not isinstance(cases, dict):
                raise SystemExit(f"malformed {case_class} case map oracle: {oracle_rel}")
            for scenario in fixture.get("scenarios", []):
                case_id = scenario.get("caseID")
                protocol_ids = scenario.get("protocolIDs")
                protocols = cases.get(case_id)
                if (
                    not isinstance(case_id, str)
                    or not isinstance(protocol_ids, list)
                    or not isinstance(protocols, dict)
                ):
                    raise SystemExit(f"malformed {case_class} case map: {cases_rel}")
                for protocol_id in protocol_ids:
                    if protocol_id not in protocols:
                        raise SystemExit(
                            f"{case_class} oracle lacks fixture scenario "
                            f"{case_id}/{protocol_id}"
                        )
                    executable.setdefault(protocol_id, set()).add(case_id)
        elif shape == "declared-case-map":
            cases_rel = evidence.get("cases")
            case_protocols = evidence.get("caseProtocols")
            if not isinstance(cases_rel, str) or not isinstance(case_protocols, dict):
                raise SystemExit(f"{case_class} declared case map lacks cases/protocols")
            if not (repo / cases_rel).is_file():
                raise SystemExit(f"{case_class} source case input is missing: {cases_rel}")
            observed = oracle.get("cases")
            if not isinstance(observed, dict):
                raise SystemExit(f"malformed {case_class} declared case map: {oracle_rel}")
            for case_id, protocol_ids in case_protocols.items():
                if (
                    not isinstance(case_id, str)
                    or case_id not in observed
                    or not isinstance(protocol_ids, list)
                    or not protocol_ids
                    or any(not isinstance(value, str) for value in protocol_ids)
                ):
                    raise SystemExit(f"malformed {case_class} declared case: {case_id}")
                for protocol_id in protocol_ids:
                    executable.setdefault(protocol_id, set()).add(case_id)
        else:
            raise SystemExit(f"unsupported {case_class} evidence shape: {shape}")
    return executable


def validate_branch_inventory(
    repo: pathlib.Path,
    wire_protocols: set[str],
    case_class: str,
) -> tuple[dict[str, set[str]], dict[str, list[str]]]:
    config = INVENTORY_CLASS_CONFIG[case_class]
    inventory = load_json(repo / config["path"])
    lock = load_json(repo / "Upstream.lock.json")
    if inventory.get("schemaVersion") != 1:
        raise SystemExit(f"unsupported {case_class} branch inventory schema")
    if inventory.get("upstreamRevision") != lock.get("revision"):
        raise SystemExit(f"{case_class} branch inventory revision does not match upstream lock")
    status_key = config["statusKey"]
    if inventory.get(status_key) not in {"incomplete", "complete"}:
        raise SystemExit(f"{case_class} branch inventory has invalid coverage status")
    executable = executable_cases_from_evidence(repo, inventory, case_class)
    branches = inventory.get("branches")
    if not isinstance(branches, list) or not branches:
        raise SystemExit(f"{case_class} branch inventory must contain branches")

    branch_ids: set[str] = set()
    required_by_protocol = {protocol_id: set() for protocol_id in wire_protocols}
    gaps_by_protocol = {protocol_id: [] for protocol_id in wire_protocols}
    for branch in branches:
        if not isinstance(branch, dict):
            raise SystemExit(f"{case_class} branch entries must be objects")
        branch_id = branch.get("id")
        if not isinstance(branch_id, str) or not branch_id or branch_id in branch_ids:
            raise SystemExit(f"invalid or duplicate {case_class} branch id: {branch_id}")
        branch_ids.add(branch_id)
        required = branch.get("required")
        protocols = branch.get("protocols")
        variants = branch.get("variants")
        symbols = branch.get("sourceSymbols")
        expected = branch.get("expected")
        status = branch.get("status")
        cases = branch.get("cases")
        if not isinstance(required, bool):
            raise SystemExit(f"{case_class} branch {branch_id} lacks required boolean")
        if (
            not isinstance(protocols, list)
            or not protocols
            or any(not isinstance(value, str) or not value for value in protocols)
            or len(protocols) != len(set(protocols))
            or set(protocols) - wire_protocols
        ):
            raise SystemExit(f"{case_class} branch {branch_id} has malformed protocols")
        if (
            not isinstance(variants, list)
            or not variants
            or any(not isinstance(value, str) or not value for value in variants)
            or len(variants) != len(set(variants))
        ):
            raise SystemExit(f"{case_class} branch {branch_id} has malformed variants")
        if not isinstance(symbols, list) or not symbols or any(not isinstance(v, str) for v in symbols):
            raise SystemExit(f"{case_class} branch {branch_id} lacks source symbols")
        if not isinstance(expected, str) or not expected:
            raise SystemExit(f"{case_class} branch {branch_id} lacks expected behavior")
        if status not in ALLOWED_BRANCH_STATUSES:
            raise SystemExit(f"{case_class} branch {branch_id} has invalid status: {status}")
        if not isinstance(cases, list):
            raise SystemExit(f"{case_class} branch {branch_id} cases must be an array")

        matrix = {protocol_id: set() for protocol_id in protocols}
        for case in cases:
            if not isinstance(case, dict):
                raise SystemExit(f"{case_class} branch {branch_id} has malformed case")
            case_id = case.get("caseID")
            case_protocols = case.get("protocols")
            case_variants = case.get("coversVariants")
            if (
                not isinstance(case_id, str)
                or not isinstance(case_protocols, list)
                or not case_protocols
                or not isinstance(case_variants, list)
                or not case_variants
                or set(case_protocols) - set(protocols)
                or set(case_variants) - set(variants)
            ):
                raise SystemExit(f"{case_class} branch {branch_id}/{case_id} has malformed coverage")
            for protocol_id in case_protocols:
                if case_id not in executable.get(protocol_id, set()):
                    raise SystemExit(
                        f"{case_class} branch {branch_id} lacks executable oracle/test "
                        f"evidence for {case_id}/{protocol_id}"
                    )
                matrix[protocol_id].update(case_variants)

        if status == "covered":
            missing_cells = [
                f"{protocol_id}:{variant}"
                for protocol_id in protocols
                for variant in variants
                if variant not in matrix[protocol_id]
            ]
            if missing_cells:
                raise SystemExit(
                    f"covered {case_class} branch {branch_id} lacks protocol/variant "
                    f"evidence: {missing_cells}"
                )
            if branch.get("missingVariants"):
                raise SystemExit(
                    f"covered {case_class} branch {branch_id} still lists missingVariants"
                )

        if required:
            for protocol_id in protocols:
                required_by_protocol[protocol_id].add(branch_id)
                if status != "covered":
                    missing = sorted(set(variants) - matrix[protocol_id])
                    detail = ",".join(missing) if missing else "status-not-covered"
                    gaps_by_protocol[protocol_id].append(
                        f"{branch_id}:{status}:{detail}"
                    )

    closed = {
        protocol_id: required
        for protocol_id, required in required_by_protocol.items()
        if required and not gaps_by_protocol[protocol_id]
    }
    calculated = "complete" if len(closed) == len(wire_protocols) else "incomplete"
    if inventory[status_key] != calculated:
        raise SystemExit(
            f"{case_class} branch inventory status is stale: "
            f"recorded={inventory[status_key]} calculated={calculated}"
        )
    return closed, gaps_by_protocol


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: check-differential-coverage.py REPO_ROOT")
    repo = pathlib.Path(sys.argv[1])
    mapping = load_json(repo / "UpstreamMappings/pi-ai.json")
    coverage = load_json(repo / "Fixtures/Differential/Coverage.json")
    if coverage.get("schemaVersion") != 1:
        raise SystemExit("unsupported differential coverage schema")
    if coverage.get("requestBranchInventory") != (
        "Fixtures/Differential/RequestBranchInventory.json"
    ):
        raise SystemExit("differential coverage must name the request branch inventory")
    for case_class, config in INVENTORY_CLASS_CONFIG.items():
        key = f"{case_class}BranchInventory"
        if coverage.get(key) != config["path"]:
            raise SystemExit(f"differential coverage must name the {case_class} branch inventory")
    required = set(coverage.get("requiredCaseClasses", []))
    if required != {"request", "responseEvents", "typedFailures"}:
        raise SystemExit("differential coverage must require request, responseEvents, and typedFailures")

    wire_areas = {
        area["protocolID"]: area
        for area in mapping["areas"]
        if isinstance(area.get("protocolID"), str)
    }
    request_closed, request_gaps = validate_request_branch_inventory(
        repo, set(wire_areas)
    )
    response_closed, response_gaps = validate_branch_inventory(
        repo, set(wire_areas), "responseEvents"
    )
    failure_closed, failure_gaps = validate_branch_inventory(
        repo, set(wire_areas), "typedFailures"
    )
    recorded = coverage.get("protocols")
    if not isinstance(recorded, dict) or set(recorded) != set(wire_areas):
        missing = sorted(set(wire_areas) - set(recorded or {}))
        extra = sorted(set(recorded or {}) - set(wire_areas))
        raise SystemExit(
            f"differential protocol coverage drift: missing={missing}, extra={extra}"
        )

    complete_protocols = set()
    for protocol_id, classes in recorded.items():
        if not isinstance(classes, list) or len(classes) != len(set(classes)):
            raise SystemExit(f"malformed differential coverage: {protocol_id}")
        unknown = set(classes) - required
        if unknown:
            raise SystemExit(
                f"unknown differential case classes for {protocol_id}: {sorted(unknown)}"
            )
        calculated_classes = {
            case_class
            for case_class, closed_protocols in [
                ("request", request_closed),
                ("responseEvents", response_closed),
                ("typedFailures", failure_closed),
            ]
            if protocol_id in closed_protocols
        }
        if set(classes) != calculated_classes:
            raise SystemExit(
                f"differential coverage record is stale for {protocol_id}: "
                f"recorded={sorted(classes)} calculated={sorted(calculated_classes)}"
            )
        if "request" in classes and protocol_id not in request_closed:
            raise SystemExit(
                f"request coverage is not branch-closed for {protocol_id}: "
                f"gaps={request_gaps[protocol_id]}"
            )
        if "responseEvents" in classes and protocol_id not in response_closed:
            raise SystemExit(
                f"response-event coverage is not branch-closed for {protocol_id}: "
                f"gaps={response_gaps[protocol_id]}"
            )
        if "typedFailures" in classes and protocol_id not in failure_closed:
            raise SystemExit(
                f"typed-failure coverage is not branch-closed for {protocol_id}: "
                f"gaps={failure_gaps[protocol_id]}"
            )
        if set(classes) == required:
            complete_protocols.add(protocol_id)

    for protocol_id, area in wire_areas.items():
        if area["status"] == "landed" and protocol_id not in complete_protocols:
            missing = sorted(required - set(recorded[protocol_id]))
            raise SystemExit(
                f"landed wire protocol lacks mandatory source-derived cases: "
                f"{protocol_id}: missing={missing}"
            )
        if protocol_id in complete_protocols and area["status"] != "landed":
            raise SystemExit(
                f"fully closed wire protocol must be promoted to landed: {protocol_id}"
            )

    areas_by_id = {area.get("id"): area for area in mapping["areas"]}
    if len(complete_protocols) == len(wire_areas):
        for area_id in {
            "canonical-request-event-dtos",
            "differential-fixture-harness",
            "wire-common",
        }:
            area = areas_by_id.get(area_id)
            if not isinstance(area, dict) or area.get("status") != "landed":
                raise SystemExit(
                    f"fully closed differential coverage requires landed area: {area_id}"
                )

    print(
        f"verified differential coverage status for {len(wire_areas)} protocols; "
        f"complete={len(complete_protocols)}; requestBranchClosed={len(request_closed)}; "
        f"responseBranchClosed={len(response_closed)}; "
        f"failureBranchClosed={len(failure_closed)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
