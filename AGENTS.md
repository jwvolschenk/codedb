# codedb Agent Guidelines

## Review guidelines

- Flag any security issues: injection, file traversal, untrusted input, secret exposure
- Verify that sensitive files (.env, .pem, .key, credentials) are excluded from indexing AND search
- Check that telemetry behavior matches documentation claims
- Flag any regression in benchmark-critical paths (threshold: 10%)
- Treat P1 issues as merge-blocking
- Verify new language parsers handle malformed input gracefully (braces in strings, unterminated comments)
- Check that installer scripts don't execute untrusted code or skip verification

## Pre-merge verification

Run these before merging any MCP-related change:

Use Zig **0.16.0** explicitly when another version is on PATH. On Windows use
`codedb.exe` and an isolated `CODEDB_CACHE_DIR` for the E2E suite. See
[release validation](docs/release-validation.md) for the five-root performance,
corpus parity, real-client and rollback checks. A recorded failing 10% gate
blocks release; it must not be presented as a successful benchmark.

```bash
zig build test                                          # unit tests
python3 scripts/e2e_mcp_test.py \
    --binary zig-out/bin/codedb \
    --project /path/to/codedb                          # E2E MCP scenarios
```

`e2e_mcp_test.py` covers eight scenarios:
1. **issue-346 regression** — spawn from cwd=`/`, roots handshake, tools return real data
2. **Normal mode** — explicit positional root (`codedb <path> mcp`), immediate scan
3. **No-roots client** — spawn from `/` with no roots capability, stays alive gracefully
4. **Root canonicalization** — localhost URI, percent encoding, trailing slash, and cache parity
5. **Warm-start reconcile** — offline edits, additions, and deletions without force indexing
6. **Worktree branch switching** — HEAD/ref changes trigger a bounded refresh
7. **Memory budget** — partial indexing remains queryable and reports its terminal state
8. **Force reindex** — all stale cache artifacts are removed before rebuilding

For the full local release check, also run:

```bash
python3 scripts/test-plan-integration.py --binary zig-out/bin/codedb
powershell -File scripts/test-installers.ps1
bash scripts/test-installers.sh
```

These use isolated synthetic fixtures and a local telemetry endpoint. They do
not register clients or contact an analytics service.

## Security-sensitive areas

- `src/watcher.zig` — file indexing skip lists (secrets must be excluded)
- `src/mcp.zig` — file read/search (path traversal, scope boundaries)
- `src/telemetry.zig` — data collection and transmission (must match docs)
- `src/snapshot.zig` — sensitive file filtering
- `scripts/setup-codedb.sh` — binary download and config modification
