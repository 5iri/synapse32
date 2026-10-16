#!/bin/sh
# Run inside the target's Linux shell; capture stdout for host report.py.
set -eu
binary="${1:-./coremark}"
iterations="${2:-0}"
case "$iterations" in ''|*[!0-9]*) echo 'Iterations must be a nonnegative integer' >&2; exit 1;; esac
for repeat in 1 2 3; do
    "$binary" 0 0 0x66 "$iterations" 7 1
done
"$binary" 0x3415 0x3415 0x66 "$iterations" 7 1
