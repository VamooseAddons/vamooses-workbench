#!/usr/bin/env bash
# Reactor headless test suite. Run from anywhere: bash tests/run_all.sh
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LUA="${LUA:-/opt/homebrew/bin/lua}"
LUAC="${LUAC:-/opt/homebrew/bin/luac}"

echo "=== parse ==="
for f in "$DIR"/Reactor/*.lua "$DIR"/Layout/*.lua "$DIR"/Showroom/*.lua "$DIR"/Core/*.lua; do "$LUAC" -p "$f"; done
echo "   all Reactor + Layout + Showroom + Core files parse"

fail=0
for t in "$DIR"/tests/*_test.lua; do
  echo "=== $(basename "$t") ==="
  "$LUA" "$t" || fail=1
done

# ---- WoW-API type-safety tier (wowlua-ls) ----------------------------------
# TSM's Rust WoW-Lua LS (built at ../wowlua-ls; needs git-lfs for its stub blobs
# -- see memory reference_wowlua_ls). The WLL_BASELINE warnings are ALL triaged
# stub/inference false-positives: GetCatalogEntryInfoByItem 2-arg +
# GetGuildRecipeMember 4-return are wrong in Ketho's stubs but verified correct
# in-game via the wow-api MCP; SetSelected is our own widget method; the
# RecipeHarvest one is a NormalizeExpansion annotation gap. Gate on a COUNT
# BASELINE -- fail only when the count RISES (a new warning = candidate real bug).
# Soft-skip when the binary isn't built.
# Baseline 5 (2026-07-11 evening): -1 from 6; the button unification deleted
# the pill-atlas SegmentedToggle branch that carried one warning. Lower as
# warnings clear.
WLL_BASELINE=5
WLL="$DIR/../wowlua-ls/target/release/wowlua_ls"
wll_fail=0
echo "=== wowlua-ls (WoW-API type tier -- count baseline $WLL_BASELINE) ==="
if [ -x "$WLL" ]; then
  set +e
  wll_out="$( cd "$DIR" && "$WLL" check . 2>&1 )"
  wll_n="$( echo "$wll_out" | grep -c 'warning\[' )"
  set -e
  echo "   wowlua-ls: $wll_n warnings (baseline $WLL_BASELINE)"
  if [ "$wll_n" -gt "$WLL_BASELINE" ]; then
    wll_fail=1
    echo "!! wowlua-ls: $wll_n > baseline $WLL_BASELINE -- NEW diagnostic(s); triage vs the wow-api MCP:"
    echo "$wll_out" | grep -E 'warning\[|error\['
  elif [ "$wll_n" -lt "$WLL_BASELINE" ]; then
    echo "   wowlua-ls: below baseline -- lower WLL_BASELINE to $wll_n in run_all.sh."
  fi
else
  echo "   wowlua-ls: SKIPPED (binary not built; needs git-lfs + cargo build --release -- see reference_wowlua_ls)."
fi

echo "=== dead-guard lint (proxy-readiness guards) ==="
set +e
lint_out="$( cd "$DIR" && python3 tests/lint_dead_guard.py 2>&1 )"; lint_rc=$?
set -e
lint_fail=0
echo "$lint_out" | tail -1
if [ "$lint_rc" -ne 0 ]; then
  lint_fail=1
  echo "$lint_out" | grep -E 'PROXY-GATE|guard-only'
  echo "   -> fix (gate on the real dependency) or annotate the guard line with -- exception(<kind>): <reason>"
fi

if [ "$fail" -eq 0 ] && [ "$wll_fail" -eq 0 ] && [ "$lint_fail" -eq 0 ]; then
  echo "ALL REACTOR TESTS PASS + wowlua-ls at/below baseline"
else
  [ "$fail" -ne 0 ]      && echo "REACTOR TESTS FAILED"
  [ "$wll_fail" -ne 0 ]  && echo "wowlua-ls: warning count rose above baseline"
  [ "$lint_fail" -ne 0 ] && echo "dead-guard lint: un-annotated proxy-guard candidate(s)"
  exit 1
fi
