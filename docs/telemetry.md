# Telemetry Data Flow

Telemetry is disabled by default. `CODEDB_TELEMETRY=1`, `true`, or `yes` enables
local aggregate events (words are case insensitive). `0`, `false`, an empty
value, and other values do not enable it. `CODEDB_NO_TELEMETRY=1`, `true`, or
`yes`, and MCP's `--no-telemetry` option take precedence over opt-in.

There is no default analytics destination. Upload requires an explicit
`CODEDB_TELEMETRY_URL`. HTTPS is accepted; HTTP is accepted only for
`localhost:<port>` or `127.0.0.1:<port>` for local testing. `CLOUD_URL` is not
used for telemetry. Explicit remote-query tools remain separate operations.

Each process exclusively creates `telemetry-<random>.ndjson` in its data
directory. Events flush after every three recorded events and on graceful
shutdown. Upload is attempted only at shutdown, with a five-second curl timeout;
query handlers never upload telemetry. Only a successful HTTP/process response
clears the file. Failed uploads stay on disk; previous session files are not
automatically retried. Forced termination can lose events still in the bounded
256-event memory buffer.

**No source code, file contents, file paths, search queries, embeddings, or tool
arguments are collected** — only aggregate tool-call and index statistics.

The current on-disk format is compact:

- `ts` or `timestamp_ms`
- `ev` or `event_type`
- `tool`, `ns` / `latency_ns`, `err` / `error`, `bytes` / `response_bytes`
- `files` / `file_count`, `lines` / `total_lines`
- optional `languages`, `index_size_bytes`, `startup_time_ms`, `version`, `platform`

The language mask currently covers enum values 0–31; later language categories
are omitted. Test the contract with synthetic payloads and a local HTTP endpoint:
`python scripts/test-plan-integration.py --binary zig-out/bin/codedb.exe`.

`scripts/sync-telemetry.py` normalizes those fields and loads them into Postgres with `COPY`.

## Postgres schema

Use [`docs/telemetry/postgres-schema.sql`](./telemetry/postgres-schema.sql) to create the destination table and indexes.

## Sync

```bash
python3 scripts/sync-telemetry.py --dsn "$DATABASE_URL"
```

For a preview without touching Postgres:

```bash
python3 scripts/sync-telemetry.py --dry-run
```

The sync path stores aggregate usage and performance data only. It does not capture file contents, file paths, or search queries.
