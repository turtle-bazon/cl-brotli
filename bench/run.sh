#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Development, tests, and benchmarks use Roswell's SBCL 2.6.9.  Set BENCH_LISP
# to override (for example BENCH_LISP=sbcl).
if [ -z "${BENCH_LISP:-}" ]; then
    roswell_sbcl="${HOME}/.roswell/impls/x86-64/linux/sbcl-bin/2.6.9/bin/sbcl"
    if [ -x "$roswell_sbcl" ]; then
        lisp="$roswell_sbcl"
    else
        lisp="sbcl"
    fi
else
    lisp="$BENCH_LISP"
fi

exec "$lisp" --script "$root/bench/run.lisp" "$@"
