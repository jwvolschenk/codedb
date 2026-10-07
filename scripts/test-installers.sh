#!/usr/bin/env bash
# Offline download-failure tests; no network or client configuration writes.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/setup-codedb.sh"
test_dir="$(mktemp -d)"
trap 'rm -f "$test_dir"/* "$test_dir"/.codedb-download*; rmdir "$test_dir"' EXIT
dest="$test_dir/codedb"
printf verified-new-binary > "$test_dir/new"
hash="$(sha256sum "$test_dir/new")"; hash="${hash%% *}"
curl() {
    local url='' output=''
    while (($#)); do
        case "$1" in
            -o) output="$2"; shift 2 ;;
            https:*) url="$1"; shift ;;
            *) shift ;;
        esac
    done
    [[ "$test_case" != http ]] || return 22
    if [[ "$url" != */checksums.sha256 ]]; then cp "$test_dir/new" "$output"; return; fi
    case "$test_case" in
        missing) printf '%s  another\n' "$hash" > "$output" ;;
        malformed) printf 'bad  codedb-x86_64-linux\n' > "$output" ;;
        duplicate) printf '%s  codedb-x86_64-linux\n%s  codedb-x86_64-linux\n' "$hash" "$hash" > "$output" ;;
        mismatch) printf '%064d  codedb-x86_64-linux\n' 0 > "$output" ;;
        *) printf '%s  codedb-x86_64-linux\n' "$hash" > "$output" ;;
    esac
}
command() {
    if [[ "$test_case" == nohash && "$1" == -v && ( "$2" == sha256sum || "$2" == shasum ) ]]; then return 1; fi
    builtin command "$@"
}
export -f curl command
export test_dir hash
for test_case in http missing malformed duplicate mismatch nohash success; do
    export test_case
    printf original-binary > "$dest"
    # Do not invoke the function as an if-condition: bash suppresses errexit
    # inside conditional functions, which would invalidate the failure test.
    set +e
    bash -c 'source "$1"; download_binary x86_64-linux test "$2"' _ "$(dirname "${BASH_SOURCE[0]}")/setup-codedb.sh" "$dest" > "$test_dir/log" 2>&1
    status=$?
    set -e
    if [[ "$test_case" == success ]]; then
        [[ "$status" == 0 && "$(cat "$dest")" == verified-new-binary ]] || { cat "$test_dir/log"; exit 1; }
    else
        [[ "$status" != 0 && "$(cat "$dest")" == original-binary ]] || { cat "$test_dir/log"; exit 1; }
    fi
    [[ -z "$(find "$test_dir" -name '.codedb-download*' -print)" ]] || exit 1
    printf 'PASS %s\n' "$test_case"
done
