#!/usr/bin/env python3
"""Validate deployable TSV entries and public AzAdvertizer links before publishing."""

from __future__ import annotations

import csv
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
import json
import os
from pathlib import Path
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from generate_config_from_table import (
    detect_delimiter,
    normalize_key,
    read_params_source,
    resolve_default_input,
    resolve_default_params_input,
    to_bool,
)


@dataclass(frozen=True)
class Finding:
    severity: str
    line: int
    definition: str
    message: str


def public_url(url: str) -> bool:
    try:
        parsed = urlsplit(url)
    except ValueError:
        return False
    return (
        parsed.scheme == "https"
        and parsed.netloc.lower() in {"www.azadvertizer.net", "azadvertizer.net"}
    )


class PublicRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not public_url(newurl):
            raise ValueError("Redirect outside HTTPS AzAdvertizer is not allowed")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def check_link(url: str) -> tuple[str, str]:
    if not public_url(url):
        return "error", f"Expected a public HTTPS AzAdvertizer URL: {url}"
    opener = build_opener(PublicRedirect())
    for attempt in range(3):
        try:
            request = Request(url, headers={"User-Agent": "AzurePolicy-Rebuild-Validation/1.0"})
            with opener.open(request, timeout=10) as response:
                if response.status == 200:
                    return "", ""
                return "error", f"Unexpected HTTP {response.status}: {url}"
        except HTTPError as exc:
            message = f"HTTP {exc.code}: {url}"
            transient = exc.code == 429 or 500 <= exc.code <= 599
            exc.close()
            if not transient:
                return "error", message
        except (URLError, TimeoutError, ConnectionError) as exc:
            message = f"Temporary link check failure ({exc}): {url}"
        except ValueError as exc:
            return "error", f"Invalid link ({exc}): {url}"
        if attempt < 2:
            time.sleep(attempt + 1)
    return "warning", f"{message} (after 3 attempts)"


def validate_parameters(
    line: int, name: str, kind: str, row: dict[str, str],
    parameter_sets: dict, schema: dict | None,
) -> list[Finding]:
    findings: list[Finding] = []
    key = row.get("Parameter Set", "")
    targets = parameter_sets.get(key, {})
    values = {**targets.get("both", {}), **targets.get(kind, {})}
    if key and not values:
        findings.append(Finding(
            "error", line, name,
            f"Parameter Set '{key}' is missing or has no parameters for {kind}",
        ))
    if schema is None:
        return findings
    for parameter, specification in schema.items():
        if "defaultValue" in specification:
            continue
        supplied = values.get(parameter, {})
        value = supplied.get("value")
        if "value" not in supplied or value is None or (
            value == "" and "" not in specification.get("allowedValues", [])
        ):
            findings.append(Finding(
                "error", line, name,
                f"Missing required parameter '{parameter}' (no defaultValue); Parameter Set: {key or '(none)'}",
            ))
    return findings


def validate(root: Path, config: dict) -> tuple[Path, list[Finding], int]:
    table = resolve_default_input(root, config)
    findings: list[Finding] = []
    paths = config.get("paths", {})
    source_roots = [
        root / paths.get("sourceDir", "source/EnterpriseALZ"),
        root / paths.get("customDir", "source/own"),
    ]
    kinds = {"policy": "policyDefinitions", "initiative": "policySetDefinitions"}
    available: dict[str, dict[str, dict]] = {kind: {} for kind in kinds}
    for kind, directory in kinds.items():
        for source_root in source_roots:
            for file in sorted((source_root / directory).glob("*.json")):
                if file.name.endswith((".AzureChinaCloud.json", ".AzureUSGovernment.json")):
                    continue
                with file.open(encoding="utf-8-sig") as stream:
                    source = json.load(stream)
                available[kind][source.get("name", file.stem)] = source.get("properties", {}).get("parameters", {})

    params_path = resolve_default_params_input(root, config)
    parameter_sets = {}
    if params_path is not None:
        with params_path.open(encoding="utf-8-sig", newline="") as stream:
            headers = next(csv.reader(stream, delimiter=detect_delimiter(params_path)), [])
        required_headers = {"Parameter Set", "Key", "Value"}
        if not required_headers.issubset({normalize_key(h) for h in headers}):
            findings.append(Finding(
                "error", 1, "Parameters",
                f"Missing parameter table headers in {params_path}: Parameter Set, Key, Value are required",
            ))
        else:
            parameter_sets = read_params_source(params_path)

    links: dict[str, list[tuple[int, str]]] = {}
    checked = 0
    with table.open(encoding="utf-8-sig", newline="") as stream:
        reader = csv.DictReader(stream, delimiter=detect_delimiter(table))
        for raw in reader:
            line = reader.line_num
            row = {normalize_key(k): (v or "").strip() for k, v in raw.items() if k}
            if not to_bool(row.get("Deploy", "true")):
                continue
            checked += 1
            name = row.get("ID", "")
            kind = (row.get("DefinitionType") or row.get("Type", "")).lower()
            origin = row.get("Type2", "").lower()
            if origin in {"built-in", "builtin"} and kind in kinds:
                prefix = f"/providers/Microsoft.Authorization/{kinds[kind]}/"
                if name.startswith(prefix):
                    name = name[len(prefix):]
            if not name or Path(name).name != name or "/" in name or "\\" in name:
                findings.append(Finding("error", line, name, "Missing or invalid definition ID"))
                continue
            if kind not in kinds:
                findings.append(Finding("error", line, name, "DefinitionType must be Policy or Initiative"))
                continue
            if origin not in {"custom", "own", "built-in", "builtin"}:
                findings.append(Finding("error", line, name, "Type2 must be Custom, Own or Built-in"))
            elif origin in {"custom", "own"}:
                other = "initiative" if kind == "policy" else "policy"
                if name not in available[kind]:
                    message = (
                        f"DefinitionType is {kind}, but source is {other}; set DefinitionType to {other}"
                        if name in available[other]
                        else f"Source {kinds[kind]}/{name}.json not found in EnterpriseALZ or own sources"
                    )
                    findings.append(Finding("error", line, name, message))
                directory = config.get("bicepTemplates", {}).get(
                    kinds[kind], f"bicep/{kinds[kind]}"
                )
                template = root / directory / f"{name}.json"
                if not template.is_file():
                    findings.append(Finding("error", line, name, f"Generated template missing: {template}"))
                else:
                    with template.open(encoding="utf-8-sig") as arm:
                        resources = json.load(arm).get("resources", [])
                    expected = f"Microsoft.Authorization/{kinds[kind]}"
                    if not any(r.get("type") == expected and r.get("name") == name for r in resources):
                        findings.append(Finding("error", line, name, f"Template does not contain {expected}/{name}"))

            if name in available[kind] or origin in {"built-in", "builtin"}:
                findings.extend(validate_parameters(
                    line, name, kind, row, parameter_sets, available[kind].get(name),
                ))

            if origin in {"custom", "built-in", "builtin"}:
                endpoint = "azpolicyinitiativesadvertizer" if kind == "initiative" else "azpolicyadvertizer"
                url = f"https://www.azadvertizer.net/{endpoint}/{name}.html"
                links.setdefault(url, []).append((line, name))

    with ThreadPoolExecutor(max_workers=4) as executor:
        for url, (severity, message) in zip(links, executor.map(check_link, links)):
            if severity:
                for line, name in links[url]:
                    findings.append(Finding(severity, line, name, message))
    return table, findings, checked


def escape_ado(value: str) -> str:
    return value.replace("%", "%AZP25").replace("\r", "%0D").replace("\n", "%0A").replace(";", "%3B").replace("]", "%5D")


def report(table: Path, findings: list[Finding], checked: int) -> int:
    errors = sum(f.severity == "error" for f in findings)
    lines = [
        "# Azure Policy rebuild validation",
        "",
        f"Checked deployable rows: **{checked}**. Errors: **{errors}**. "
        f"Warnings: **{len(findings) - errors}**.",
        "",
        "Validation failed: no new `policy-generated` artifact will be published."
        if errors else "Validation passed; publication can proceed if subsequent steps succeed.",
        "",
        "| Severity | TSV line | Definition ID | Finding |",
        "| --- | --- | --- | --- |",
    ]
    for finding in findings:
        cells = [finding.severity, str(finding.line), finding.definition, finding.message]
        lines.append("| " + " | ".join(c.replace("|", "&#124;").replace("\n", " ") for c in cells) + " |")
        if os.environ.get("TF_BUILD", "").lower() == "true":
            print(
                f"##vso[task.logissue type={finding.severity};sourcepath={escape_ado(str(table))};"
                f"linenumber={finding.line};]{escape_ado(f'{finding.definition}: {finding.message}')}"
            )
        else:
            print(f"{finding.severity.upper()}: {table}:{finding.line}: {finding.definition}: {finding.message}")
    if os.environ.get("TF_BUILD", "").lower() == "true":
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", suffix=".md", prefix="azurepolicy-validation-",
            dir=os.environ.get("AGENT_TEMPDIRECTORY"), delete=False,
        ) as summary:
            summary.write("\n".join(lines) + "\n")
        print(f"##vso[task.uploadsummary]{summary.name}")
    print(f"Rebuild validation: {checked} rows, {errors} errors, {len(findings) - errors} warnings.")
    return 1 if errors else 0


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    table = root / "configuration" / "policy-assignments.tsv"
    try:
        with (root / "configuration" / "deployment-config.json").open(encoding="utf-8-sig") as stream:
            config = json.load(stream)
        table, findings, checked = validate(root, config)
    except (OSError, ValueError, csv.Error) as exc:
        return report(table, [Finding("error", 1, "Input", str(exc))], 0)
    return report(table, findings, checked)


if __name__ == "__main__":
    raise SystemExit(main())
