#!/usr/bin/env python3
"""Combine safe live observations into an inspectable capability matrix."""
import argparse
from collections import Counter
import html
import json
from pathlib import Path


def combine(reports):
    history = []
    latest = {}
    revisions = set()
    runs = []
    for path, report in reports:
        revisions.add(report["upstreamRevision"])
        runs.append({"evidenceFile": str(path), "identity": report.get("identity", {}),
                     "completed": report.get("completed")})
        for row in report["rows"]:
            value = {**row, "evidenceFile": str(path)}
            history.append(value)
            key = (row["providerID"], row["modelID"], row["capability"], row.get("effort", "provider_default"),
                   row.get("maximumOutputTokens"))
            current = latest.get(key)
            # An unselected entry from another run is not new evidence about a tested cell.
            if current is None or row["status"] != "not_selected":
                latest[key] = value
    if len(revisions) != 1:
        raise ValueError("upstream_revision_mismatch")
    rows = list(latest.values())
    return {"schemaVersion": 1, "upstreamRevision": revisions.pop(), "rows": rows,
            "history": history, "runs": runs, "statusCounts": dict(Counter(row["status"] for row in rows)),
            "scope": "Only the recorded model, credential kind, platform, time and capability were exercised.",
            "authorizationLifecycle": "not_executed", "physicalIOS": "not_executed"}


def render(report):
    esc = lambda value: html.escape(str(value), quote=True)
    items = []
    for row in report["rows"]:
        checks = {key: row[key] for key in ("referenceBinding", "toolChoice", "maximumOutputTokens", "swift", "typescript", "failure", "identity")
                  if key in row}
        detail = esc(json.dumps(checks, ensure_ascii=False, indent=2))
        items.append(f'<tr data-status="{esc(row["status"])}"><td>{esc(row["providerName"])}</td>'
                     f'<td>{esc(row["modelID"])}<br><small>{esc(row.get("protocolID", ""))}</small></td>'
                     f'<td>{esc(row["capability"])}</td>'
                     f'<td>{esc(row.get("effort", "provider_default"))}</td>'
                     f'<td>{esc(row["status"])}</td><td>{esc(row.get("authentication", ""))}</td>'
                     f'<td>{esc(row.get("finishedAt", ""))}</td>'
                     f'<td><details><summary>Evidence</summary><pre>{detail}</pre>'
                     f'<small>{esc(row["evidenceFile"])}</small></details></td></tr>')
    counts = esc(json.dumps(report["statusCounts"]))
    return '''<!doctype html><meta charset="utf-8"><title>Provider capability matrix</title>
<style>body{font:15px system-ui;margin:32px;color:#19212b;background:#f7f9fc}h1{font-size:25px}
input,select{padding:9px;margin:6px 10px 16px 0}table{border-collapse:collapse;width:100%;background:white}
td,th{padding:10px;border-bottom:1px solid #dce2eb;text-align:left;vertical-align:top}
th{position:sticky;top:0;background:#eaf0f7}tr[data-status=passed]{color:#16643b}
tr[data-status=not_selected]{color:#78818d}pre{font-size:12px;white-space:pre-wrap;min-width:310px}
small{word-break:break-all}summary{cursor:pointer}</style>
<h1>Provider capability matrix</h1><p>''' + esc(report["scope"]) + '''</p><p>''' + counts + '''</p>
<p>OAuth renewal and physical iOS acceptance: not executed by this generation harness.</p>
<label>Search <input id="search" placeholder="Provider or model"></label>
<label>Result <select id="status"><option value="selected">Selected cases</option><option value="">All results</option>
<option>passed</option><option>swift_failure</option><option>reference_failure</option><option>both_failed</option>
<option>harness_failure</option><option>interface_gap</option><option>host_refresh_required</option><option>observation_timeout</option><option>not_selected</option><option>not_advertised</option><option>running</option></select></label>
<table><thead><tr><th>Provider</th><th>Model / protocol</th><th>Capability</th><th>Effort</th><th>Result</th><th>Credential</th><th>UTC</th><th>Assertions</th></tr></thead><tbody>''' + "".join(items) + '''</tbody></table>
<script>const search=document.querySelector('#search'),status=document.querySelector('#status');
function filter(){for(const row of document.querySelectorAll('tbody tr')){
  const matchesStatus = status.value==='selected' ? row.dataset.status!=='not_selected'
    : !status.value || row.dataset.status===status.value;
  row.hidden=!matchesStatus||!row.textContent.toLowerCase().includes(search.value.toLowerCase());
}}
search.oninput=filter;status.onchange=filter;filter();</script>'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", action="append", type=Path, required=True,
                        help="Evidence in chronological run order; repeat to preserve earlier failures")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = combine([(path, json.loads(path.read_text())) for path in args.input])
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "matrix.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    (args.output / "matrix.html").write_text(render(report))
    print(json.dumps(report["statusCounts"]))


if __name__ == "__main__":
    main()
