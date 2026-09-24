#!/usr/bin/env python3

import argparse
import json
import pathlib
import subprocess
import sys


def canonical(document: object) -> str:
    return json.dumps(document, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=pathlib.Path, required=True)
    parser.add_argument("--upstream", type=pathlib.Path, required=True)
    parser.add_argument("--generate", action="store_true")
    arguments = parser.parse_args()

    repo = arguments.repo.resolve()
    upstream = arguments.upstream.resolve()
    lock = json.loads((repo / "Upstream.lock.json").read_text(encoding="utf-8"))
    revision = subprocess.run(
        ["git", "-C", str(upstream), "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    if revision != lock["revision"]:
        raise SystemExit(
            f"source oracle revision mismatch: expected {lock['revision']}, found {revision}"
        )

    request_case_path = repo / "Fixtures/Differential/Cases/request-rich.json"
    verify_or_generate(
        repo=repo,
        revision=revision,
        repository=lock["repository"],
        script="pi-ai-source-oracle.mjs",
        arguments=[str(upstream), str(request_case_path)],
        output_path=repo / "Fixtures/Differential/Oracle/request-rich.json",
        generate=arguments.generate,
        description="request",
    )
    verify_or_generate(
        repo=repo,
        revision=revision,
        repository=lock["repository"],
        script="pi-ai-replay-oracle.mjs",
        arguments=[
            str(upstream),
            str(repo / "Fixtures/Differential/Cases/request-replay.json"),
            str(request_case_path),
        ],
        output_path=repo / "Fixtures/Differential/Oracle/request-replay.json",
        generate=arguments.generate,
        description="request replay",
    )
    verify_or_generate(
        repo=repo,
        revision=revision,
        repository=lock["repository"],
        script="pi-ai-secondary-request-oracle.mjs",
        arguments=[
            str(upstream),
            str(repo / "Fixtures/Differential/Cases/request-secondary.json"),
        ],
        output_path=repo / "Fixtures/Differential/Oracle/request-secondary.json",
        generate=arguments.generate,
        description="secondary request",
    )
    verify_or_generate_exact(
        repo=repo,
        script="pi-ai-request-domain-oracle.mjs",
        arguments=[
            str(upstream),
            str(repo / "Fixtures/Differential/Cases/request-domain.json"),
        ],
        output_path=repo / "Fixtures/Differential/Oracle/request-domain.json",
        generate=arguments.generate,
        description="request-domain contract",
    )
    verify_or_generate_exact(
        repo=repo,
        script="pi-ai-provider-options-oracle.mjs",
        arguments=[
            str(upstream),
            str(repo / "Fixtures/Differential/Cases/provider-options.json"),
        ],
        output_path=repo / "Fixtures/Differential/Oracle/provider-options.json",
        generate=arguments.generate,
        description="provider option and session-header contract",
    )
    for script, case_relative, oracle_relative, description in [
        (
            "pi-ai-anthropic-bedrock-request-oracle.mjs",
            "Fixtures/Differential/Cases/request-anthropic-bedrock.json",
            "Fixtures/Differential/Oracle/request-anthropic-bedrock.json",
            "Anthropic and Bedrock request branches",
        ),
        (
            "pi-ai-google-request-oracle.mjs",
            "Fixtures/Differential/Cases/request-google-branches.json",
            "Fixtures/Differential/Oracle/request-google-branches.json",
            "Google request branches",
        ),
        (
            "openai-request-branch-oracle.mjs",
            "Fixtures/OpenAIRequestBranches/Cases/request-branches.json",
            "Fixtures/OpenAIRequestBranches/Oracle/request-branches.json",
            "OpenAI request branches",
        ),
        (
            "pi-ai-azure-configuration-oracle.mjs",
            "Fixtures/AzureOpenAIConfiguration/Cases/configuration.json",
            "Fixtures/AzureOpenAIConfiguration/Oracle/configuration.json",
            "Azure OpenAI configuration branches",
        ),
    ]:
        verify_or_generate_exact(
            repo=repo,
            script=script,
            arguments=[str(upstream), str(repo / case_relative)],
            output_path=repo / oracle_relative,
            generate=arguments.generate,
            description=description,
        )
    verify_or_generate(
        repo=repo,
        revision=revision,
        repository=lock["repository"],
        script="pi-ai-response-oracle.mjs",
        arguments=[
            str(upstream),
            str(repo / "Fixtures/Differential/Cases/response-rich.json"),
        ],
        output_path=repo / "Fixtures/Differential/Oracle/response-rich.json",
        generate=arguments.generate,
        description="response event",
    )
    for script, case_relative, oracle_relative, description in [
        (
            "pi-ai-anthropic-bedrock-pi-response-oracle.mjs",
            "Fixtures/Differential/Cases/response-anthropic-bedrock-pi.json",
            "Fixtures/Differential/Oracle/response-anthropic-bedrock-pi.json",
            "Anthropic Bedrock and Pi response branches",
        ),
        (
            "pi-ai-provider-response-branches-oracle.mjs",
            "Fixtures/Differential/Cases/response-provider-branches.json",
            "Fixtures/Differential/Oracle/response-provider-branches.json",
            "Google Mistral and OpenRouter response branches",
        ),
        (
            "openai-response-event-oracle.mjs",
            "Fixtures/OpenAIRequestBranches/Cases/response-event-branches.json",
            "Fixtures/OpenAIRequestBranches/Oracle/response-event-branches.json",
            "OpenAI response branches",
        ),
    ]:
        verify_or_generate_exact(
            repo=repo,
            script=script,
            arguments=[str(upstream), str(repo / case_relative)],
            output_path=repo / oracle_relative,
            generate=arguments.generate,
            description=description,
        )
    for failure_name, description in [
        ("failure-http", "HTTP failure"),
        ("failure-malformed-wire", "malformed-wire failure"),
        ("failure-missing-terminal", "missing-terminal failure"),
        ("failure-provider-declared", "provider-declared failure"),
        ("failure-cancellation", "cancellation failure"),
    ]:
        verify_or_generate(
            repo=repo,
            revision=revision,
            repository=lock["repository"],
            script="pi-ai-failure-oracle.mjs",
            arguments=[
                str(upstream),
                str(repo / f"Fixtures/Differential/Cases/{failure_name}.json"),
                str(request_case_path),
            ],
            output_path=repo / f"Fixtures/Differential/Oracle/{failure_name}.json",
            generate=arguments.generate,
            description=description,
        )
    if lock['schemaVersion'] == 4:
        for script, cases, output, description in [
            ('google-response-identity-oracle.mjs', None,
             'Fixtures/GoogleResponseIdentity/identity.json', 'Google emission identity lifecycle'),
            ('candidate-completions-oracle.mjs', None,
             'Fixtures/CandidateCompletions/request.json', 'completion strict and empty-text cases'),
            ('pi-ai-anthropic-candidate-usage-oracle.mjs',
             'Fixtures/Differential/Cases/anthropic-candidate-cache-ttl.json',
             'Fixtures/Differential/Oracle/anthropic-candidate-cache-ttl.json', 'Anthropic delta cache TTL'),
            ('pi-ai-candidate-headers-oracle.mjs',
             'Fixtures/Differential/Cases/candidate-provider-headers.json',
             'Fixtures/Differential/Oracle/candidate-provider-headers.json', 'case-insensitive headers'),
        ]:
            verify_or_generate_exact(
                repo=repo, script=script,
                arguments=[str(upstream)] + ([str(repo / cases)] if cases else []),
                output_path=repo / output, generate=arguments.generate,
                description=description,
            )
    return 0


def verify_or_generate(
    *,
    repo: pathlib.Path,
    revision: str,
    repository: str,
    script: str,
    arguments: list[str],
    output_path: pathlib.Path,
    generate: bool,
    description: str,
) -> None:
    process = subprocess.run(
        [
            "node",
            str(repo / "Scripts" / script),
            *arguments,
        ],
        check=False,
        capture_output=True,
        text=True,
        timeout=60,
    )
    if process.returncode != 0:
        raise SystemExit(
            "source oracle execution failed:\n" + process.stderr.strip()
        )
    observed = json.loads(process.stdout)
    observed["upstreamRepository"] = repository
    observed["upstreamRevision"] = revision
    rendered = canonical(observed)

    if generate:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(rendered, encoding="utf-8")
        print(f"generated {output_path}")
        return

    if not output_path.is_file():
        raise SystemExit(f"missing source-derived oracle: {output_path}")
    expected = output_path.read_text(encoding="utf-8")
    if expected != rendered:
        raise SystemExit(
            f"source-derived {description} oracle drift; regenerate explicitly and review the semantic diff"
        )
    protocol_count = len(observed.get("protocols", {}))
    suffix = f" for {protocol_count} protocols" if protocol_count else ""
    print(f"verified source-derived {description} oracle{suffix}")


def verify_or_generate_exact(
    *,
    repo: pathlib.Path,
    script: str,
    arguments: list[str],
    output_path: pathlib.Path,
    generate: bool,
    description: str,
) -> None:
    process = subprocess.run(
        ["node", str(repo / "Scripts" / script), *arguments],
        check=False,
        capture_output=True,
        text=True,
        timeout=60,
    )
    if process.returncode != 0:
        raise SystemExit(
            f"source oracle execution failed for {description}:\n"
            + process.stderr.strip()
        )
    rendered = canonical(json.loads(process.stdout))
    if generate:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(rendered, encoding="utf-8")
        print(f"generated {output_path}")
        return
    if not output_path.is_file() or output_path.read_text(encoding="utf-8") != rendered:
        raise SystemExit(
            f"source-derived {description} oracle drift; regenerate explicitly and review the semantic diff"
        )
    print(f"verified source-derived {description} oracle")


if __name__ == "__main__":
    sys.exit(main())
