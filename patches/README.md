# Custom Patches

> **Note:** This directory is no longer actively used. The full source tree
> (including custom C# and F# parsers) is maintained directly in this repo.
> Build scripts compile from local source — no patching step needed.
>
> This directory is kept for reference in case patches are needed for
> quick hotfixes against upstream without a full merge.

## Historical Context

Previously, this repo was a thin wrapper that cloned upstream
[justrach/codedb](https://github.com/justrach/codedb) and applied patches
at build time. That approach was replaced by maintaining the full source
tree locally, which is simpler and allows direct development of the C#
and F# parsers.

## If You Need a Patch

If you need to apply a quick fix against upstream without merging:

1. Clone upstream:
   ```bash
   git clone https://github.com/justrach/codedb.git /tmp/codedb-upstream
   cd /tmp/codedb-upstream
   ```

2. Make your changes and generate a patch:
   ```bash
   git diff > /path/to/codedb_custom/patches/001-my-fix.patch
   ```

3. The patch will be available for reference but won't be auto-applied
   during build (builds use local source).
