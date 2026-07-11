#!/usr/bin/env python3
"""Sanitized MCP integration coverage for SSAS/DAX/MDX support."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

from e2e_mcp_test import MCPProcess, all_tool_text, do_initialize, wait_for_scan


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def call_text(process: MCPProcess, tool: str, arguments: dict) -> str:
    response = process.call_tool(tool, arguments, timeout=60.0)
    require(response is not None and "result" in response, f"{tool} did not respond")
    return all_tool_text(response)


def parse_tool_json(text: str, tool: str) -> dict:
    start = text.find("{")
    end = text.rfind("}")
    require(start >= 0 and end >= start, f"{tool} did not return JSON: {text[:500]!r}")
    return json.loads(text[start:end + 1])


def wait_for_ready(process: MCPProcess, timeout: float = 90.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        text = call_text(process, "codedb_status", {})
        if "scan: ready" in text or "scan=ready" in text:
            return True
        time.sleep(0.5)
    return False


def make_fixture() -> Path:
    root = Path.home() / f".codedb-e2e-ssas-{os.getpid()}-{int(time.time())}"
    root.mkdir(parents=True)
    subprocess.run(["git", "init", "-q"], cwd=root, check=True)
    (root / ".gitignore").write_text("codedb.snapshot\n", encoding="utf-8")
    (root / "Model.bim").write_text(
        json.dumps({
            "model": {
                "tables": [{
                    "name": "Sales",
                    "columns": [
                        {"name": "Amount", "dataType": "double", "sourceColumn": "Amount"},
                        {"name": "Margin", "dataType": "double", "expression": "[Revenue] - [Cost]"},
                    ],
                    "measures": [
                        {"name": "Revenue", "expression": "SUM('Sales'[Amount])"},
                        {"name": "Cost", "expression": "SUM('Sales'[CostAmount])"},
                    ],
                    "calculationGroup": {"calculationItems": [
                        {"name": "Current", "expression": "SELECTEDMEASURE()"}
                    ]},
                }],
                "relationships": [{
                    "name": "Sales Customer", "fromTable": "Sales", "fromColumn": "CustomerId",
                    "toTable": "Customer", "toColumn": "Id",
                }],
            }
        }, indent=2) + "\n",
        encoding="utf-8",
    )
    (root / "Query.dax").write_text(
        "DEFINE MEASURE 'Sales'[Gross] = [Revenue]\nEVALUATE ROW(\"Revenue\", [Revenue])\n",
        encoding="utf-8",
    )
    (root / "Script.mdx").write_text(
        "WITH MEMBER [Measures].[Profit] AS [Measures].[Revenue] - [Measures].[Cost]\n"
        "SELECT [Measures].[Profit] ON 0 FROM [Sales]\n",
        encoding="utf-8",
    )
    (root / "Sales.smproj").write_text(
        '<Project><ItemGroup><Compile Include="Model.bim" /></ItemGroup></Project>\n',
        encoding="utf-8",
    )
    (root / "Secret.bim").write_text(
        '{"password":"do-not-index","model":{"tables":[{"name":"SecretTable"}]}}\n',
        encoding="utf-8",
    )
    return root


def validate_sanitized(binary: Path) -> None:
    root = make_fixture()
    process = MCPProcess(str(binary), [], cwd="/", command=[str(binary), str(root), "mcp"])
    try:
        require(do_initialize(process, with_roots=False), "initialize failed")
        require(wait_for_scan(process, timeout=90.0), "scan did not produce outlines")
        require(wait_for_ready(process, timeout=90.0), "scan did not become ready")

        outline = call_text(process, "codedb_outline", {"path": "Model.bim", "output_format": "json"})
        parsed = parse_tool_json(outline, "codedb_outline")
        names = {symbol["name"] for symbol in parsed["symbols"]}
        require({"Sales", "Amount", "Margin", "Revenue", "Current", "Sales Customer"} <= names,
                f"missing BIM symbols: {names}")

        symbol = call_text(process, "codedb_symbol", {"name": "Revenue", "output_format": "json"})
        require("subtype=measure" in symbol and "table=Sales" in symbol, f"bad measure detail: {symbol}")

        callers = call_text(process, "codedb_callers", {"name": "Revenue", "max_results": 20})
        require("Query.dax" in callers and "Model.bim" in callers, f"DAX callers missing: {callers}")

        mdx_callers = call_text(process, "codedb_callers", {"name": "Profit", "max_results": 20})
        require("Script.mdx" in mdx_callers, f"MDX callers missing: {mdx_callers}")

        search = call_text(process, "codedb_search", {"query": "SELECTEDMEASURE", "max_results": 10})
        require("Model.bim" in search, f"expression search missing: {search}")

        deps = call_text(process, "codedb_deps", {"path": "Sales.smproj", "direction": "depends_on"})
        require("Model.bim" in deps, f"project dependency missing: {deps}")

        tree = call_text(process, "codedb_tree", {})
        require("Secret.bim" not in tree and "SecretTable" not in tree, f"secret file exposed in tree: {tree}")
        secret_search = call_text(process, "codedb_search", {"query": "do-not-index", "max_results": 10})
        require("Secret.bim" not in secret_search and "0 results" in secret_search,
                f"secret file exposed in search: {secret_search}")
        secret_read = call_text(process, "codedb_read", {"path": "Secret.bim"})
        require("sensitive file blocked" in secret_read, f"secret read was not rejected: {secret_read}")
        secret_edit = call_text(process, "codedb_edit", {
            "path": "Secret.bim", "op": "insert", "after": 0, "content": "// probe"
        })
        require("SensitiveContent" in secret_edit or "sensitive file blocked" in secret_edit,
                f"secret edit was not rejected: {secret_edit}")
        introduce_secret = call_text(process, "codedb_edit", {
            "path": "Model.bim", "op": "insert", "after": 0,
            "content": '"password":"new-secret",',
        })
        require("introduce sensitive content" in introduce_secret,
                f"secret-introducing edit was not rejected: {introduce_secret}")

        snapshot = root / "codedb.snapshot"
        deadline = time.monotonic() + 15.0
        while time.monotonic() < deadline and not snapshot.exists():
            time.sleep(0.25)
        require(snapshot.exists(), "codedb.snapshot was not written")
        snapshot_bytes = snapshot.read_bytes()
        require(b"do-not-index" not in snapshot_bytes and b"SecretTable" not in snapshot_bytes,
                "secret content was serialized into codedb.snapshot")

        # Incremental security regression: a formerly safe/indexed model that
        # acquires a credential must be evicted and recorded as a deletion.
        (root / "Model.bim").write_text(
            '{"password":"introduced-secret","model":{"tables":[{"name":"FormerlyVisible"}]}}\n',
            encoding="utf-8",
        )
        deadline = time.monotonic() + 15.0
        evicted = False
        while time.monotonic() < deadline:
            tree_after = call_text(process, "codedb_tree", {})
            if "Model.bim" not in tree_after:
                evicted = True
                break
            time.sleep(0.5)
        require(evicted, "incrementally secret-bearing Model.bim remained indexed")
        changes = call_text(process, "codedb_changes", {"since": 0})
        require("Model.bim" in changes and ("op=delete" in changes or "op=tombstone" in changes),
                f"secret eviction was not recorded as deletion: {changes}")
    finally:
        process.close()
        shutil.rmtree(root, ignore_errors=True)


def validate_corpus(binary: Path, project: Path) -> dict[str, int]:
    process = MCPProcess(str(binary), [], cwd="/", command=[str(binary), str(project), "mcp"])
    counts = {
        "files": 0, "tables": 0, "columns": 0, "measures": 0,
        "calculated_columns": 0, "relationships": 0, "calculation_items": 0,
    }
    try:
        require(do_initialize(process, with_roots=False), "corpus initialize failed")
        require(wait_for_scan(process, timeout=90.0), "corpus scan did not produce outlines")
        require(wait_for_ready(process, timeout=90.0), "corpus scan did not become ready")
        status = call_text(process, "codedb_status", {})
        match = re.search(r"outlines:\s*(\d+)", status)
        require(match is not None, f"could not parse corpus status: {status}")
        counts["files"] = int(match.group(1))

        intended = [
            path.relative_to(project).as_posix()
            for path in project.rglob("*")
            if path.is_file() and ".git" not in path.relative_to(project).parts
            and path.name != "codedb.snapshot"
        ]
        for rel in intended:
            discovered = call_text(process, "codedb_outline", {"path": rel, "output_format": "json"})
            require("file not indexed" not in discovered and f'"path":"{rel}"' in discovered,
                    f"intended corpus file was not discoverable: {rel}")

        representative_measure: str | None = None
        for model in sorted(project.rglob("*.bim")):
            rel = model.relative_to(project).as_posix()
            data = parse_tool_json(call_text(process, "codedb_outline", {"path": rel, "output_format": "json"}), "codedb_outline")
            for symbol in data["symbols"]:
                detail = symbol.get("detail") or ""
                if "subtype=table" in detail or "subtype=calculation_group" in detail:
                    counts["tables"] += 1
                if "subtype=column" in detail or "subtype=calculated_column" in detail:
                    counts["columns"] += 1
                if "subtype=measure" in detail:
                    counts["measures"] += 1
                    if representative_measure is None:
                        representative_measure = symbol["name"]
                if "subtype=calculated_column" in detail:
                    counts["calculated_columns"] += 1
                if "subtype=relationship" in detail:
                    counts["relationships"] += 1
                if "subtype=calculation_item" in detail:
                    counts["calculation_items"] += 1

        minimums = {
            "files": 20, "tables": 80, "columns": 1361, "measures": 130,
            "calculated_columns": 93, "relationships": 56, "calculation_items": 7,
        }
        for key, minimum in minimums.items():
            require(counts[key] >= minimum, f"corpus {key}: got {counts[key]}, expected at least {minimum}")
        require(representative_measure is not None, "corpus exposed no representative measure")
        measure_lookup = call_text(process, "codedb_symbol", {
            "name": representative_measure, "kind": "function", "output_format": "json",
        })
        require("subtype=measure" in measure_lookup, "representative corpus measure lookup failed")
        return counts
    finally:
        process.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default="zig-out/bin/codedb")
    parser.add_argument("--validate-project")
    args = parser.parse_args()
    binary = Path(args.binary).resolve()
    require(binary.exists(), f"binary not found: {binary}")
    validate_sanitized(binary)
    print("PASS sanitized SSAS MCP scenario")
    if args.validate_project:
        counts = validate_corpus(binary, Path(args.validate_project).resolve())
        print("PASS SSAS corpus " + " ".join(f"{key}={value}" for key, value in counts.items()))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"FAIL {exc}", file=sys.stderr)
        raise SystemExit(1)
