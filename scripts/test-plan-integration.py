#!/usr/bin/env python3
"""Local-only security, navigation, freshness, protocol and telemetry acceptance.

Uses an isolated fixture and CODEDB_CACHE_DIR; never touches client registration.
Run against a freshly built binary. Exits nonzero on any failed assertion.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import tempfile
import threading
import time
from e2e_mcp_test import MCPProcess, all_tool_text, do_initialize


def check(ok, name):
    if not ok:
        raise AssertionError(name)
    print("PASS", name, flush=True)


def request(p, method, params=None):
    ident = p.next_id()
    p.send({"jsonrpc": "2.0", "id": ident, "method": method, "params": params or {}})
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        msg = p.recv(1)
        if msg and msg.get("id") == ident:
            return msg
    raise AssertionError("No reply to " + method)


def ready(p):
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        text = all_tool_text(p.call_tool("codedb_status", {}))
        if "scan: ready" in text:
            return text
        if "scan: failed" in text:
            raise AssertionError(text)
        time.sleep(.2)
    raise AssertionError("Scan did not reach ready: " + text)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", required=True)
    args = ap.parse_args()
    binary = str(Path(args.binary).resolve())
    # A nested temporary root is allowed; never ask the server to scan temp itself.
    with tempfile.TemporaryDirectory(prefix="codedb-plan-") as temp:
        base = Path(temp)
        root = base / "project"
        root.mkdir()
        (root / "a").mkdir()
        (root / "b").mkdir()
        (root / "nested").mkdir()
        (root / "a/index.ts").write_text("export const value = 1;\n", encoding="utf-8")
        (root / "b/index.ts").write_text("export const value = 2;\n", encoding="utf-8")
        (root / "consumer.ts").write_text("import {value} from './a/index';\n", encoding="utf-8")
        (root / "calls.ts").write_text("/*\nprobe();\n*/\nconst s = `probe()`;\nconst r = /probe()/;\nconst x = 'text'; probe();\n", encoding="utf-8")
        (root / "watch.ts").write_text("export const beforeCanary = 1;\n", encoding="utf-8")
        (root / "nested/.gitignore").write_text("hidden.ts\n", encoding="utf-8")
        (root / "nested/hidden.ts").write_text("const ignoredCanary = 1;", encoding="utf-8")
        (root / ".ENV").write_text("SECRET_CANARY=synthetic_only", encoding="utf-8")
        env = {"CODEDB_CACHE_DIR": str(base / "cache"), "CODEDB_REQUIRE_GIT_REPO": "0",
               "CODEDB_NO_AUTO_UPDATE": "1", "CODEDB_TELEMETRY": "0", "CODEDB_NO_TELEMETRY": "0"}

        def launch(extra=None):
            return MCPProcess(binary, [], str(root), command=[binary, str(root), "mcp"], env={**env, **(extra or {})})

        p = launch()
        try:
            check(do_initialize(p, False), "legacy initialize")
            ready(p)
            discovery = request(p, "tools/list")
            check("resultType" not in discovery["result"], "legacy envelope")
            tools = discovery["result"]["tools"]
            check(all("annotations" in t for t in tools), "tool annotations")
            for limit in (1, 50):
                response = p.call_tool("codedb_callers", {"name": "probe", "max_results": limit, "output_format": "json"})
                rows = json.loads(all_tool_text(response))
                check(len(rows["hits"]) == 1, f"lexical callers at limit {limit}")
            for path in (".ENV", "../outside.ts", "C:relative.ts", "watch.ts:stream"):
                text = all_tool_text(p.call_tool("codedb_read", {"path": path}))
                check("SECRET_CANARY" not in text and ("error" in text.lower() or "denied" in text.lower()), "reject " + path)
            text = all_tool_text(p.call_tool("codedb_search", {"query": "ignoredCanary"}))
            check("nested/hidden.ts:" not in text, "nested ignore at startup")

            # A metadata collision must converge under the documented sweep bound.
            time.sleep(3)
            f = root / "watch.ts"
            st = f.stat()
            f.write_text("export const afterxCanary = 1;\n", encoding="utf-8")
            os.utime(f, ns=(st.st_atime_ns, st.st_mtime_ns))
            deadline = time.monotonic() + 70
            while time.monotonic() < deadline:
                text = all_tool_text(p.call_tool("codedb_search", {"query": "afterxCanary"}))
                if "watch.ts:" in text:
                    break
                time.sleep(1)
            check("watch.ts:" in text, "same-size same-mtime edit converges")

            (root / "nested/.gitignore").write_text("", encoding="utf-8")
            text = all_tool_text(p.call_tool("codedb_index", {"path": str(root), "force": True}, timeout=60))
            check("error:" not in text.lower(), "forced rebuild completes")
            text = all_tool_text(p.call_tool("codedb_search", {"query": "ignoredCanary"}))
            check("nested/hidden.ts:" in text, "forced rebuild refreshes populated default explorer")
        finally:
            p.close()

        p = launch({"CODEDB_TOOL_PROFILE": "navigation"})
        try:
            res = request(p, "initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "plan-test", "version": "1"}})
            check(res["result"]["protocolVersion"] == "2025-11-25", "2025-11-25 negotiation")
            nav = request(p, "tools/list")["result"]["tools"]
            check(len(nav) < len(tools), "navigation profile reduces tool count")
            check(all(t["annotations"]["readOnlyHint"] for t in nav), "navigation profile read-only tools")
            res = request(p, "tools/list", {"_meta": "invalid"})
            check("error" in res, "invalid metadata rejected")
        finally:
            p.close()

        received = []
        class Handler(http.server.BaseHTTPRequestHandler):
            status = 503
            def do_POST(self):
                received.append(self.rfile.read(int(self.headers["Content-Length"])))
                self.send_response(self.status)
                self.end_headers()
            def log_message(self, *args):
                pass
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = f"http://127.0.0.1:{server.server_port}/synthetic"
        try:
            for opt_in, opt_out, status, upload in [("0", "0", 200, False), ("1", "1", 200, False), ("1", "0", 503, True), ("true", "0", 200, True)]:
                Handler.status = status
                count = len(received)
                existing = set(base.rglob("telemetry-*.ndjson"))
                p = launch({"CODEDB_TELEMETRY": opt_in, "CODEDB_NO_TELEMETRY": opt_out, "CODEDB_TELEMETRY_URL": url})
                try:
                    check(do_initialize(p, False), "telemetry session initialize")
                    ready(p)
                    p.call_tool("codedb_search", {"query": "PRIVATE_QUERY_CANARY"})
                finally:
                    p.close()
                check((len(received) > count) == upload, f"telemetry opt-in={opt_in} disable={opt_out} HTTP={status}")
                files = set(base.rglob("telemetry-*.ndjson")) - existing
                if upload:
                    check(bool(files), "isolated telemetry file")
                    check(all((f.stat().st_size > 0) == (status == 503) for f in files), "retain failed upload; clear successful upload")
                    payload = received[-1]
                    check(b"PRIVATE_QUERY_CANARY" not in payload and b"SECRET_CANARY" not in payload and str(root).encode() not in payload, "telemetry excludes queries secrets and paths")
                    for line in payload.splitlines():
                        json.loads(line)
                else:
                    check(not files, "disabled telemetry creates no file")
        finally:
            server.shutdown()
            server.server_close()
    print("All plan integration checks passed", flush=True)


if __name__ == "__main__":
    main()
