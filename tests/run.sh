#!/usr/bin/env bash
# Lance toute la suite : bash tests/run.sh [motif-de-fichier]
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATTERN="${1:-}"
TOTAL=0; FAILED=0; SKIPPED=0
for f in "$DIR"/test_*.sh; do
  case "$f" in *"$PATTERN"*) ;; *) continue ;; esac
  echo "▶ $(basename "$f")"
  fns="$(bash -c "source '$DIR/lib.sh'; source '$f'; declare -F | awk '{print \$3}' | grep '^test_'")"
  for fn in $fns; do
    TOTAL=$((TOTAL + 1))
    T="$(mktemp -d)"; mkdir -p "$T/bin"
    out="$(cd "$T" && T="$T" PATH="$T/bin:$PATH" bash -c "set -e; source '$DIR/lib.sh'; source '$f'; $fn" 2>&1)"; rc=$?
    if [ $rc -eq 0 ]; then echo "  ✓ ${fn#test_}"
    elif [ $rc -eq 99 ]; then echo "  - ${fn#test_} (ignoré : prérequis absent)"; SKIPPED=$((SKIPPED + 1))
    else echo "  ✗ ${fn#test_}"; printf '%s\n' "$out" | sed 's/^/      /'; FAILED=$((FAILED + 1)); fi
    rm -rf "$T"
  done
done
echo; echo "${TOTAL} tests : $((TOTAL - FAILED - SKIPPED)) réussis, ${FAILED} en échec, ${SKIPPED} ignorés"
[ "$FAILED" -eq 0 ]
