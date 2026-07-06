#!/usr/bin/env python3
"""
E2E MCP test harness for codedb.

Scenarios covered:
  1. issue-346 regression: spawn from cwd=/, complete MCP handshake via roots, wait
     for scan to finish, verify core tools return real data from the project.
  2. Normal mode: spawn with explicit --root <path>, verify scan runs immediately
     and tools return data without needing a roots handshake.
  3. No-roots client: spawn from cwd=/, client declares no roots capability, MCP
     stays alive and tools respond gracefully (0 files, no crash).
  4. issue-591 root canonicalization: client sends a file://localhost URI with a
     percent-encoded space and a trailing slash; the server must index the right
     dir and reuse the same cache dir the CLI path produces (project.txt check).

Usage:
  python3 scripts/e2e_mcp_test.py [--binary /path/to/codedb] [--project /path/to/project]

Defaults:
  --binary  : zig-out/bin/codedb (build artifact)
  --project : current working directory (the codedb repo itself)
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any


# ── ANSI colours ──────────────────────────────────────────────────────────────

GREEN = "\033[32m"
RED = "\033[31m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
BOLD = "\033[1m"
RESET = "\033[0m"

PASS = f"{GREEN}PASS{RESET}"
FAIL = f"{RED}FAIL{RESET}"
SKIP = f"{YELLOW}SKIP{RESET}"


# ── MCP subprocess wrapper ────────────────────────────────────────────────────

class MCPProcess:
    """Wraps a codedb mcp subprocess; sends/receives JSON-RPC over stdio."""

    def __init__(self, binary: str, args: list[str], cwd: str,
                 command: list[str] | None = None,
                 env: dict[str, str] | None = None) -> None:
        """
        command: full argv override (default: [binary, "mcp"] + args).
        Use command=[binary, root, "mcp"] for explicit-root invocation.
        env: extra environment variables merged over os.environ.
        """
        argv = command if command is not None else [binary, "mcp"] + args
        full_env = {**os.environ, **env} if env else None
        self.proc = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=cwd,
            text=True,
            bufsize=1,
            env=full_env,
        )
        self._id = 1
        self._lock = threading.Lock()
        self._lines: list[str] = []
        self._stderr_lines: list[str] = []
        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()
        self._stderr_reader = threading.Thread(target=self._stderr_loop, daemon=True)
        self._stderr_reader.start()

    def _read_loop(self) -> None:
        assert self.proc.stdout
        for line in self.proc.stdout:
            line = line.strip()
            if line:
                with self._lock:
                    self._lines.append(line)

    def _stderr_loop(self) -> None:
        assert self.proc.stderr
        for line in self.proc.stderr:
            with self._lock:
                self._stderr_lines.append(line.rstrip())

    def send(self, msg: dict[str, Any]) -> None:
        assert self.proc.stdin
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()

    def recv(self, timeout: float = 10.0) -> dict[str, Any] | None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self._lock:
                if self._lines:
                    return json.loads(self._lines.pop(0))
            time.sleep(0.02)
        return None

    def recv_method(self, method: str, timeout: float = 10.0) -> dict[str, Any] | None:
        """Wait for a message with a specific 'method' field (server→client request)."""
        deadline = time.monotonic() + timeout
        buf: list[str] = []
        while time.monotonic() < deadline:
            with self._lock:
                remaining = list(self._lines)
                self._lines.clear()
            for raw in remaining:
                msg = json.loads(raw)
                if msg.get("method") == method:
                    with self._lock:
                        self._lines = buf + self._lines  # put others back
                    return msg
                buf.append(raw)
            with self._lock:
                self._lines = buf + self._lines
            buf = []
            time.sleep(0.02)
        return None

    def next_id(self) -> int:
        self._id += 1
        return self._id

    def call_tool(self, name: str, args: dict[str, Any], timeout: float = 30.0) -> dict[str, Any] | None:
        """Send a tools/call request and return the response."""
        req_id = self.next_id()
        self.send({
            "jsonrpc": "2.0",
            "id": req_id,
            "method": "tools/call",
            "params": {"name": name, "arguments": args},
        })
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            msg = self.recv(timeout=1.0)
            if msg is None:
                continue
            if msg.get("id") == req_id:
                return msg
        return None

    def stderr_lines(self) -> list[str]:
        with self._lock:
            return list(self._stderr_lines)

    def close(self) -> None:
        try:
            assert self.proc.stdin
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


# ── Helpers ───────────────────────────────────────────────────────────────────

def do_initialize(p: MCPProcess, with_roots: bool = True) -> bool:
    """Send initialize + initialized. Returns True if server replied."""
    capabilities: dict[str, Any] = {}
    if with_roots:
        capabilities["roots"] = {"listChanged": True}

    p.send({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": capabilities,
            "clientInfo": {"name": "e2e-test", "version": "1"},
        },
    })
    resp = p.recv(timeout=10)
    if resp is None or "result" not in resp:
        return False
    p.send({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
    return True


def reply_roots(p: MCPProcess, project_path: str, timeout: float = 5.0) -> bool:
    """
    Wait for the server's roots/list request, reply with project_path.
    Returns True if the request arrived and we replied.
    """
    req = p.recv_method("roots/list", timeout=timeout)
    if req is None:
        return False
    p.send({
        "jsonrpc": "2.0",
        "id": req["id"],
        "result": {
            "roots": [{"uri": f"file://{project_path}", "name": "project"}],
        },
    })
    return True


def all_tool_text(resp: dict[str, Any] | None) -> str:
    """Concatenate all content[*].text from a tools/call response."""
    if resp is None:
        return ""
    content = resp.get("result", {}).get("content", [])
    return "\n".join(c.get("text", "") for c in content if isinstance(c, dict))


def wait_for_scan(p: MCPProcess, timeout: float = 60.0) -> bool:
    """Poll codedb_status until outlines > 0 (full scan + outline pass done) or timeout."""
    import re
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        resp = p.call_tool("codedb_status", {}, timeout=5.0)
        if resp and "result" in resp:
            text = all_tool_text(resp)
            m = re.search(r'\boutlines:\s*(\d+)', text)
            if m and int(m.group(1)) > 0:
                return True
        time.sleep(1.0)
    return False


def tool_text(resp: dict[str, Any] | None) -> str:
    """Return all content text joined — use all_tool_text directly for assertions."""
    return all_tool_text(resp)


# ── Test cases ────────────────────────────────────────────────────────────────

class TestResult:
    def __init__(self, name: str) -> None:
        self.name = name
        self.passed = False
        self.message = ""

    def ok(self, msg: str = "") -> "TestResult":
        self.passed = True
        self.message = msg
        return self

    def fail(self, msg: str) -> "TestResult":
        self.passed = False
        self.message = msg
        return self


def run_scenario_1_issue346_regression(binary: str, project: str) -> list[TestResult]:
    """
    issue-346: spawn from cwd=/, roots handshake delivers real path, tools work.
    """
    results: list[TestResult] = []

    def t(name: str) -> TestResult:
        r = TestResult(f"[S1] {name}")
        results.append(r)
        return r

    p = MCPProcess(binary, [], cwd="/")

    try:
        r = t("initialize does not crash (no transport-closed)")
        ok = do_initialize(p, with_roots=True)
        if not ok:
            r.fail("no initialize response — transport closed")
            return results
        r.ok()

        r = t("server sends roots/list request")
        got_roots_req = reply_roots(p, project, timeout=5.0)
        if not got_roots_req:
            r.fail("server never sent roots/list request")
        else:
            r.ok()

        r = t("scan completes and files > 0")
        scan_ok = wait_for_scan(p, timeout=90.0)
        if not scan_ok:
            r.fail("timed out waiting for scan (files stayed at 0)")
        else:
            r.ok()

        r = t("codedb_tree returns non-empty result")
        resp = p.call_tool("codedb_tree", {})
        text = tool_text(resp)
        if not text or len(text) < 20:
            r.fail(f"tree response too short: {text!r}")
        else:
            r.ok(f"{len(text)} chars")

        r = t("codedb_search finds 'DeferredScan' in project")
        resp = p.call_tool("codedb_search", {"query": "DeferredScan", "max_results": 5})
        text = tool_text(resp)
        if "DeferredScan" not in text:
            r.fail(f"DeferredScan not found in search results: {text[:200]!r}")
        else:
            r.ok()

        r = t("codedb_hot returns recent files")
        resp = p.call_tool("codedb_hot", {"limit": 5})
        text = tool_text(resp)
        if not text or len(text) < 10:
            r.fail(f"hot response empty: {text!r}")
        else:
            r.ok(f"{len(text)} chars")

        r = t("codedb_outline works on src/mcp.zig")
        resp = p.call_tool("codedb_outline", {"path": "src/mcp.zig"})
        text = tool_text(resp)
        if "run" not in text and "DeferredScan" not in text:
            r.fail(f"outline missing expected symbols: {text[:200]!r}")
        else:
            r.ok()

        r = t("codedb_symbol finds 'DeferredScan'")
        resp = p.call_tool("codedb_symbol", {"name": "DeferredScan"})
        text = tool_text(resp)
        if "DeferredScan" not in text:
            r.fail(f"symbol lookup returned: {text[:200]!r}")
        else:
            r.ok()

    finally:
        p.close()

    return results


def run_scenario_2_normal_mode(binary: str, project: str) -> list[TestResult]:
    """
    Normal mode: explicit positional root (`codedb <project> mcp`), scan runs immediately,
    no roots handshake needed.
    """
    results: list[TestResult] = []

    def t(name: str) -> TestResult:
        r = TestResult(f"[S2] {name}")
        results.append(r)
        return r

    p = MCPProcess(binary, [], cwd="/", command=[binary, project, "mcp"])

    try:
        r = t("initialize succeeds")
        ok = do_initialize(p, with_roots=False)
        if not ok:
            r.fail("no initialize response")
            return results
        r.ok()

        r = t("server does NOT send roots/list (scan is immediate)")
        # Give 2 seconds — if no roots/list arrives, that's correct for explicit-root mode
        req = p.recv_method("roots/list", timeout=2.0)
        if req is not None:
            r.fail("server sent roots/list even though root was explicit — unexpected")
        else:
            r.ok("no roots/list request (correct)")

        r = t("scan completes without roots handshake")
        scan_ok = wait_for_scan(p, timeout=90.0)
        if not scan_ok:
            r.fail("timed out waiting for scan")
        else:
            r.ok()

        r = t("codedb_search works")
        resp = p.call_tool("codedb_search", {"query": "isIndexableRoot", "max_results": 3})
        text = tool_text(resp)
        if "isIndexableRoot" not in text:
            r.fail(f"search result: {text[:200]!r}")
        else:
            r.ok()

    finally:
        p.close()

    return results


def run_scenario_3_no_roots_client(binary: str) -> list[TestResult]:
    """
    No-roots client: spawn from cwd=/, no roots capability, MCP stays alive, tools
    respond gracefully with 0 files (no crash, no transport-closed).
    """
    results: list[TestResult] = []

    def t(name: str) -> TestResult:
        r = TestResult(f"[S3] {name}")
        results.append(r)
        return r

    p = MCPProcess(binary, [], cwd="/")

    try:
        r = t("initialize succeeds with no roots capability")
        ok = do_initialize(p, with_roots=False)
        if not ok:
            r.fail("no initialize response — transport closed")
            return results
        r.ok()

        r = t("server does NOT send roots/list")
        req = p.recv_method("roots/list", timeout=3.0)
        if req is not None:
            r.fail("server sent roots/list to a client with no roots capability")
        else:
            r.ok("correctly skipped roots/list")

        r = t("codedb_status responds (0 files is fine)")
        resp = p.call_tool("codedb_status", {})
        if resp is None or "result" not in resp:
            r.fail("codedb_status did not respond")
        else:
            r.ok(f"responded: {tool_text(resp)[:80]}")

        r = t("codedb_search responds (may return empty)")
        resp = p.call_tool("codedb_search", {"query": "anything", "max_results": 5})
        if resp is None:
            r.fail("no response to codedb_search — server may have crashed")
        else:
            r.ok("responded (empty results expected)")

        r = t("process is still alive")
        poll = p.proc.poll()
        if poll is not None:
            r.fail(f"process exited with code {poll}")
        else:
            r.ok()

    finally:
        p.close()

    return results


def run_scenario_4_root_canonicalization(binary: str, project: str) -> list[TestResult]:
    """
    issue-591: root canonicalization through one funnel.

    The client sends a file:// URI that exercises the bug class:
      - localhost authority (file://localhost/...)
      - percent-encoded space (%20)
      - trailing slash
    The server must (a) index the right directory (files > 0), and (b) write a
    project.txt naming the realpath — proving the MCP path and the CLI path share
    one cache dir (the core #591 invariant). We point the URI at a throwaway tmp
    dir containing a single source file so we don't mutate the real project's
    cache dir, and we compare against an independently-computed realpath.
    """
    import tempfile
    import urllib.parse

    results: list[TestResult] = []

    def t(name: str) -> TestResult:
        r = TestResult(f"[S4] {name}")
        results.append(r)
        return r

    # Build a tmp project dir whose name has a space — forces percent-encoding
    # to be meaningful. Use the user's home (never /tmp — root_policy denies it)
    # and clean up explicitly. Symlinks (/tmp -> /private/tmp on macOS) are
    # resolved by realpath, so we compare against os.path.realpath.
    home = str(Path.home())
    tmp_raw = os.path.join(home, f".codedb-e2e-591-{os.getpid()}-{int(time.time())}")
    os.makedirs(os.path.join(tmp_raw, "space dir"))  # name with a space
    tmp_real = os.path.realpath(os.path.join(tmp_raw, "space dir"))
    try:
        # Drop one file so the index is non-empty.
        (Path(tmp_real) / "hello.zig").write_text("pub fn hello591() void {}\n")
        # Make it a git repo so require_git_repo (the default) doesn't reject
        # it — mirrors real usage and keeps this scenario about URI handling,
        # not the git guard.
        subprocess.run(["git", "init", "-q"], cwd=tmp_real, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        # URI with localhost authority, %20 for the space, and a trailing slash.
        encoded_path = urllib.parse.quote(tmp_real)  # spaces -> %20
        uri = f"file://localhost/{encoded_path.lstrip('/')}/"

        p = MCPProcess(binary, [], cwd="/")
        try:
            r = t("initialize succeeds")
            if not do_initialize(p, with_roots=True):
                r.fail("no initialize response — transport closed")
                return results
            r.ok()

            r = t("server sends roots/list")
            req = p.recv_method("roots/list", timeout=5.0)
            if req is None:
                r.fail("server never sent roots/list")
                return results
            # Reply with the adversarial URI.
            p.send({
                "jsonrpc": "2.0",
                "id": req["id"],
                "result": {"roots": [{"uri": uri, "name": "591-space-dir"}]},
            })
            r.ok()

            r = t("scan completes on the canonicalized root (files > 0)")
            if not wait_for_scan(p, timeout=90.0):
                r.fail("timed out waiting for scan (root never indexed)")
                return results
            r.ok()

            r = t("codedb_search finds the file content")
            resp = p.call_tool("codedb_search", {"query": "hello591", "max_results": 5})
            text = tool_text(resp)
            if "hello591" not in text:
                r.fail(f"hello591 not found — search saw: {text[:200]!r}")
            else:
                r.ok()

            r = t("project.txt names the realpath (CLI/MCP cache-dir parity)")
            # getDataDir writes project.txt into ~/.codedb/projects/<hash>/.
            # The hash is root_resolve.cacheKey(canonical_root); for a passing
            # run the dir exists and names tmp_real.
            home = Path.home()
            found = False
            if (home / ".codedb" / "projects").is_dir():
                for d in (home / ".codedb" / "projects").iterdir():
                    pt = d / "project.txt"
                    if pt.exists():
                        content = pt.read_text().strip()
                        if content == tmp_real:
                            found = True
                            break
            if found:
                r.ok(f"project.txt == {tmp_real}")
            else:
                r.fail(f"no project.txt matched realpath {tmp_real!r}")
        finally:
            p.close()
    finally:
        import shutil
        shutil.rmtree(tmp_raw, ignore_errors=True)

    return results


def run_scenario_5_restart_staleness(binary: str) -> list[TestResult]:
    """
    issue-591 Task 5: warm-start reconcile.

    Index a project, shut the server down, then edit one file, create one, and
    delete one. On restart the warm-loaded snapshot passes the git-HEAD gate
    (no commit happened) — before the fix, all three offline changes were
    invisible until `codedb_index force=true`. The reconcile + seed sweep must
    surface them with no manual step.
    """
    results: list[TestResult] = []

    def t(name: str) -> TestResult:
        r = TestResult(f"[S5] {name}")
        results.append(r)
        return r

    home = str(Path.home())
    proj = os.path.join(home, f".codedb-e2e-591t5-{os.getpid()}-{int(time.time())}")
    os.makedirs(proj)
    proj = os.path.realpath(proj)
    try:
        Path(proj, "keep.zig").write_text("pub fn keepMe591() void {}\n")
        Path(proj, "edit.zig").write_text("pub fn beforeEdit591() void {}\n")
        Path(proj, "gone.zig").write_text("pub fn goneSoon591() void {}\n")
        env = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
               **os.environ}
        subprocess.run(["git", "init", "-q"], cwd=proj, check=True)
        subprocess.run(["git", "add", "-A"], cwd=proj, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "init"], cwd=proj,
                       check=True, env=env)

        # First run: index and persist a snapshot.
        p = MCPProcess(binary, [], cwd="/", command=[binary, proj, "mcp"])
        try:
            r = t("first run: initialize + scan")
            if not do_initialize(p, with_roots=False) or not wait_for_scan(p, timeout=90.0):
                r.fail("first run never became ready")
                return results
            r.ok()

            r = t("first run: snapshot persisted")
            deadline = time.monotonic() + 30.0
            snap = Path(proj, "codedb.snapshot")
            while time.monotonic() < deadline and not snap.exists():
                time.sleep(0.5)
            if not snap.exists():
                r.fail("codedb.snapshot never written")
                return results
            r.ok()
        finally:
            p.close()

        # Offline edits — same git HEAD, so the snapshot will warm-load.
        Path(proj, "edit.zig").write_text("pub fn afterEdit591() void {}\n")
        Path(proj, "born.zig").write_text("pub fn bornOffline591() void {}\n")
        os.unlink(os.path.join(proj, "gone.zig"))

        # Second run: warm start must reconcile, no force=true.
        p = MCPProcess(binary, [], cwd="/", command=[binary, proj, "mcp"])
        try:
            r = t("second run: initialize + ready")
            if not do_initialize(p, with_roots=False) or not wait_for_scan(p, timeout=90.0):
                r.fail("second run never became ready")
                return results
            r.ok()

            r = t("edited-while-down content visible (no force)")
            text = tool_text(p.call_tool("codedb_search", {"query": "afterEdit591", "max_results": 5}))
            if "afterEdit591" not in text:
                r.fail(f"stale content — search saw: {text[:200]!r}")
            else:
                r.ok()

            r = t("created-while-down file visible (no force)")
            text = tool_text(p.call_tool("codedb_search", {"query": "bornOffline591", "max_results": 5}))
            if "bornOffline591" not in text:
                r.fail(f"created file invisible — search saw: {text[:200]!r}")
            else:
                r.ok()

            r = t("deleted-while-down file evicted (no force)")
            # NOTE: the response header echoes the query string, so match on
            # the file path — a live hit renders as "gone.zig:N: ...".
            text = tool_text(p.call_tool("codedb_search", {"query": "goneSoon591", "max_results": 5}))
            if "gone.zig" in text:
                r.fail(f"deleted file still served from the index: {text[:200]!r}")
            else:
                r.ok()
        finally:
            p.close()
    finally:
        import shutil
        shutil.rmtree(proj, ignore_errors=True)

    return results


def run_scenario_6_worktree_branch_switch(binary: str) -> list[TestResult]:
    """
    issue-591 Task 6: branch switches must be detected in git WORKTREES, where
    `.git` is a file (gitdir pointer) — the old watcher stat'd `{root}/.git/HEAD`
    and was silently blind there forever.
    """
    results: list[TestResult] = []

    def t(name: str) -> TestResult:
        r = TestResult(f"[S6] {name}")
        results.append(r)
        return r

    home = str(Path.home())
    base = os.path.join(home, f".codedb-e2e-591t6-{os.getpid()}-{int(time.time())}")
    repo = os.path.join(base, "repo")
    wt = os.path.join(base, "wt")
    os.makedirs(repo)
    try:
        env = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
               **os.environ}

        def git(cwd: str, *args: str) -> None:
            subprocess.run(["git", *args], cwd=cwd, check=True, env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        # main: one file. feat: an extra file (different tree, different SHA).
        Path(repo, "base.zig").write_text("pub fn baseFn591() void {}\n")
        git(repo, "init", "-q", "-b", "main")
        git(repo, "add", "-A")
        git(repo, "commit", "-q", "-m", "base")
        git(repo, "switch", "-q", "-c", "feat")
        Path(repo, "feat.zig").write_text("pub fn featOnly591() void {}\n")
        git(repo, "add", "-A")
        git(repo, "commit", "-q", "-m", "feat")
        git(repo, "switch", "-q", "main")

        # Linked worktree on its own branch at main's commit (a branch checked
        # out in the primary tree can't be checked out again in a worktree).
        git(repo, "worktree", "add", "-q", "-b", "wtbranch", wt, "main")
        wt_real = os.path.realpath(wt)

        p = MCPProcess(binary, [], cwd="/", command=[binary, wt_real, "mcp"])
        try:
            r = t("server ready on the worktree")
            if not do_initialize(p, with_roots=False) or not wait_for_scan(p, timeout=90.0):
                r.fail("server never became ready on the worktree")
                return results
            r.ok()

            r = t("feat-branch file not indexed yet")
            text = tool_text(p.call_tool("codedb_search", {"query": "featOnly591", "max_results": 5}))
            if "feat.zig" in text:
                r.fail("feat.zig visible before the switch?!")
                return results
            r.ok()

            # Give the watcher time to seed its HEAD watch (it resolves the
            # git dir and records baseline mtimes right after scan_done). A
            # switch inside that window is healed by the seed walk itself but
            # doesn't register as a HEAD *event*, which is what we assert below.
            time.sleep(4.0)

            # Switch the WORKTREE to feat — updates the worktree-private HEAD
            # (under repo/.git/worktrees/...), never {wt}/.git/HEAD.
            git(wt_real, "switch", "-q", "feat")

            r = t("branch switch detected; feat file searchable (≤30s)")
            deadline = time.monotonic() + 30.0
            seen = False
            while time.monotonic() < deadline:
                text = tool_text(p.call_tool("codedb_search", {"query": "featOnly591", "max_results": 5}))
                if "feat.zig" in text:
                    seen = True
                    break
                time.sleep(1.0)
            if seen:
                r.ok()
            else:
                r.fail("worktree branch switch never reflected in the index")

            # The 2s file poller would eventually index feat.zig by itself, so
            # the load-bearing assertion is the HEAD-rescan log: it only fires
            # when the worktree-aware watch actually saw HEAD move.
            r = t("HEAD-change rescan actually triggered (stderr log)")
            deadline = time.monotonic() + 30.0
            found_log = False
            while time.monotonic() < deadline and not found_log:
                with p._lock:
                    found_log = any("git HEAD changed" in ln for ln in p._stderr_lines)
                if not found_log:
                    time.sleep(1.0)
            if found_log:
                r.ok()
            else:
                r.fail("no 'git HEAD changed' rescan log — worktree HEAD watch is blind")
        finally:
            p.close()
    finally:
        import shutil
        shutil.rmtree(base, ignore_errors=True)

    return results


def run_scenario_7_memory_budget(binary: str) -> list[TestResult]:
    """
    issue-591 Task 8: memory budget backstop. With CODEDB_MAX_MEMORY_MB=1 any
    live process is over budget, so a cold scan must stop immediately, KEEP the
    partial index, keep the server alive, and report scan=budget_exceeded with
    an override hint — never OOM the host, never crash.
    """
    results: list[TestResult] = []

    def t(name: str) -> TestResult:
        r = TestResult(f"[S7] {name}")
        results.append(r)
        return r

    home = str(Path.home())
    proj = os.path.join(home, f".codedb-e2e-591t8-{os.getpid()}-{int(time.time())}")
    os.makedirs(proj)
    proj = os.path.realpath(proj)
    try:
        for i in range(20):
            Path(proj, f"f{i}.zig").write_text(f"pub fn fn591_{i}() void {{}}\n")
        env = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
               **os.environ}
        subprocess.run(["git", "init", "-q"], cwd=proj, check=True)
        subprocess.run(["git", "add", "-A"], cwd=proj, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "init"], cwd=proj,
                       check=True, env=env)

        p = MCPProcess(binary, [], cwd="/", command=[binary, proj, "mcp"],
                       env={"CODEDB_MAX_MEMORY_MB": "1"})
        try:
            r = t("server survives hitting the budget (initialize + terminal scan state)")
            if not do_initialize(p, with_roots=False):
                r.fail("no initialize response")
                return results
            # Wait for a terminal state; wait_for_scan only accepts ready/lazy,
            # so poll status text directly.
            deadline = time.monotonic() + 60.0
            state_text = ""
            while time.monotonic() < deadline:
                state_text = tool_text(p.call_tool("codedb_status", {}))
                if "budget_exceeded" in state_text or "scan: ready" in state_text:
                    break
                time.sleep(0.5)
            if p.proc.poll() is not None:
                r.fail("server process died")
                return results
            r.ok()

            r = t("codedb_status reports scan=budget_exceeded")
            if "budget_exceeded" not in state_text:
                r.fail(f"status: {state_text[:300]!r}")
            else:
                r.ok()

            r = t("status shows budget limit + override hint")
            if "memory_budget: 1MB" in state_text and "CODEDB_MAX_MEMORY_MB" in state_text:
                r.ok()
            else:
                r.fail(f"status missing budget/override info: {state_text[:400]!r}")

            r = t("queries still answer (partial index, no crash)")
            text = tool_text(p.call_tool("codedb_search", {"query": "fn591_0", "max_results": 3}))
            if p.proc.poll() is not None:
                r.fail("server died on query after budget stop")
            elif "PARTIAL index" in text or "search" in text:
                r.ok()
            else:
                r.fail(f"unexpected response: {text[:200]!r}")
        finally:
            p.close()
    finally:
        import shutil
        shutil.rmtree(proj, ignore_errors=True)

    return results


# ── Runner ────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(description="codedb MCP E2E test harness")
    parser.add_argument("--binary", default="zig-out/bin/codedb",
                        help="Path to codedb binary (default: zig-out/bin/codedb)")
    parser.add_argument("--project", default=os.getcwd(),
                        help="Absolute path to project to index (default: cwd)")
    args = parser.parse_args()

    binary = str(Path(args.binary).resolve())
    project = str(Path(args.project).resolve())

    if not Path(binary).exists():
        print(f"{RED}ERROR:{RESET} binary not found: {binary}")
        print("Run `zig build` first, or pass --binary /path/to/codedb")
        return 1

    print(f"\n{BOLD}codedb MCP E2E test harness{RESET}")
    print(f"  binary : {binary}")
    print(f"  project: {project}\n")

    all_results: list[TestResult] = []

    print(f"{CYAN}── Scenario 1: issue-346 regression (spawn from /, roots handshake) ──{RESET}")
    all_results += run_scenario_1_issue346_regression(binary, project)

    print(f"\n{CYAN}── Scenario 2: normal mode (explicit --root) ──{RESET}")
    all_results += run_scenario_2_normal_mode(binary, project)

    print(f"\n{CYAN}── Scenario 3: no-roots client (spawn from /, no scan) ──{RESET}")
    all_results += run_scenario_3_no_roots_client(binary)

    print(f"\n{CYAN}── Scenario 4: issue-591 root canonicalization (localhost + %20 + trailing slash) ──{RESET}")
    all_results += run_scenario_4_root_canonicalization(binary, project)

    print(f"\n{CYAN}── Scenario 5: issue-591 warm-start reconcile (offline edits, no force) ──{RESET}")
    all_results += run_scenario_5_restart_staleness(binary)

    print(f"\n{CYAN}── Scenario 6: issue-591 worktree branch-switch detection ──{RESET}")
    all_results += run_scenario_6_worktree_branch_switch(binary)

    print(f"\n{CYAN}── Scenario 7: issue-591 memory budget backstop (CODEDB_MAX_MEMORY_MB=1) ──{RESET}")
    all_results += run_scenario_7_memory_budget(binary)

    print()
    passed = 0
    failed = 0
    for r in all_results:
        status = PASS if r.passed else FAIL
        detail = f"  {r.message}" if r.message else ""
        print(f"  {status}  {r.name}{detail}")
        if r.passed:
            passed += 1
        else:
            failed += 1

    print(f"\n{BOLD}Results: {passed}/{len(all_results)} passed{RESET}")
    if failed:
        print(f"{RED}{failed} test(s) failed.{RESET}")
        return 1
    print(f"{GREEN}All tests passed.{RESET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
