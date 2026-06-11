# Building the Windows `codedb_index` Fix on Linux

## Background

`codedb_index` was failing on Windows with:

```
error: failed to run indexer
```

**Root cause:** `cio.runCapture` in `src/cio.zig` returned `error.NotImplemented` on Windows.
The `codedb_index` MCP handler spawns itself as a subprocess (`codedb <path> snapshot <snapshot_path>`)
to build the snapshot — that spawn call was a stub on Windows.

**Fix (commit `ff9a0a1`):** Implements the full Windows `CreateProcessW` path in `runCapture`,
mirroring the existing POSIX `posix_spawnp` implementation. The binary itself was always correct;
only the MCP server's subprocess launch was broken.

---

## Prerequisites

- Linux x86_64 (or aarch64)
- `git`, `curl`, `tar`
- `scp` or any file transfer method to copy a `.exe` to the Windows machine

---

## Step 1 — Get Zig 0.16.0

The project requires exactly Zig 0.16.0.

```bash
ZIG_VERSION="0.16.0"
ZIG_ARCH="x86_64-linux"   # change to aarch64-linux if on ARM
ZIG_DIR="$HOME/.local/zig"

mkdir -p "$ZIG_DIR"
curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-${ZIG_VERSION}.tar.xz" \
  | tar -xJ -C "$ZIG_DIR" --strip-components=1

export PATH="$ZIG_DIR:$PATH"
zig version   # should print: 0.16.0
```

To make this permanent, add the `export PATH` line to your `~/.bashrc` or `~/.zshrc`.

---

## Step 2 — Clone / update the repo

```bash
git clone https://github.com/jwvolschenk_crdc/codedb_custom.git
cd codedb_custom

# If already cloned:
git pull
git log --oneline -3   # verify ff9a0a1 "cio: implement Windows CreateProcess path" is present
```

---

## Step 3 — Cross-compile for Windows

Zig cross-compilation is built-in — no MinGW, Wine, or Windows SDK needed.

```bash
# From inside the codedb_custom directory:
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows
```

Expected output (takes ~30–60 s on first build):

```
# (no output = success)
```

Verify the binary was produced:

```bash
ls -lh zig-out/bin/codedb.exe
file zig-out/bin/codedb.exe
# should say: PE32+ executable (console) x86-64, for MS Windows
```

For ARM64 Windows (Surface Pro X etc.):

```bash
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-windows
```

---

## Step 4 — Run the test suite (Linux)

The unit tests run against the Linux binary and cover parsing, indexing, and MCP logic.
They do **not** cover the Windows subprocess path (that requires a live Windows environment),
but they verify nothing else regressed.

```bash
zig build test
```

All tests should pass. The Windows-specific `runCapture` code is dead on Linux — it compiles
but the `if (is_windows)` branch is never entered.

---

## Step 5 — Transfer the binary to Windows

```bash
scp zig-out/bin/codedb.exe user@windows-machine:"C:/Users/jwvolschenk/AppData/Local/codedb/bin/codedb.exe"
```

Or copy via a shared drive / USB / any method you prefer. The destination is wherever
`codedb.exe` is currently installed, which you can find by running this in PowerShell on
the Windows machine:

```powershell
(Get-Command codedb -ErrorAction SilentlyContinue).Source
# or check the MCP config:
Get-Content "$env:APPDATA\..\Local\codedb\bin\codedb.exe" -ErrorAction SilentlyContinue
```

The install path on this machine is:

```
C:\Users\jwvolschenk\AppData\Local\codedb\bin\codedb.exe
```

---

## Step 6 — Verify on Windows

After replacing the binary, restart any running MCP server (restart Claude Code / VS Code),
then test `codedb_index` from the MCP client:

```
codedb_index path: "E:\credo\github\hmrc"
```

**Before the fix:** `error: failed to run indexer`  
**After the fix:** `✓ indexed <N> files`

You can also sanity-check the binary version from PowerShell:

```powershell
& "C:\Users\jwvolschenk\AppData\Local\codedb\bin\codedb.exe" version
# should print the new build version
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `zig: command not found` | PATH not updated | Re-run `export PATH="$ZIG_DIR:$PATH"` |
| `error: build.zig not found` | Not in repo root | `cd codedb_custom` first |
| `file` says ELF not PE | Wrong target | Use `-Dtarget=x86_64-windows` |
| Tests fail after the change | Something else broke | Run `zig build test 2>&1` and check error messages |
| MCP still shows old error | Server not restarted | Restart Claude Code / VS Code extension host |

---

## What the fix does (code reference)

**File:** `src/cio.zig`

- **`win_spawn_impl` struct** (after line 515): Windows API declarations —
  `CreateProcessW`, `CreatePipe`, `SetHandleInformation`, `ReadFile`, `CloseHandle`,
  `WaitForSingleObject`, `GetExitCodeProcess`.

- **`winAppendUtf16`** helper: converts a UTF-8 string to UTF-16LE for the Windows
  command-line API, handling surrogate pairs for non-BMP characters.

- **`runCapture` Windows branch** (replaces the old `return error.NotImplemented`):
  builds a properly-quoted UTF-16 command line, creates stdout/stderr pipe pairs
  (write ends inherit into the child, read ends do not), launches the process with
  `CREATE_NO_WINDOW`, drains stderr on a background thread while the main thread drains
  stdout (avoids pipe deadlock), then waits for the process and collects the exit code.
