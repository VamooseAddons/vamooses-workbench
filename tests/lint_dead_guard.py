#!/usr/bin/env python3
"""
dead-guard lint -- flags the 'proxy-readiness guard' shape that stranded cold
mounts in Showroom kindRes: a `local X = <call>` whose ONLY use in its scope is a
nil/not existence guard (`if not X` / `X == nil`). If a fetched value is only
ever existence-checked to bail -- and never actually consumed -- it cannot be
gating the right thing (classID was fetched, guarded on, `return nil`-ed, and
never read again; meanwhile the real work used other APIs with other readiness).

This is a HEURISTIC, not a compiler: it reports candidates for a human to judge.
A legit hit gets `-- exception(<kind>): <reason>` on the guard line to silence it.

Run: python3 tests/lint_dead_guard.py [addon_dir]   (default: the parent dir)
Exit 1 if any un-annotated candidate is found.
"""
import re
import sys
import os

SKIP_DIRS = {"tests", "archive", "docs", ".git", "Reactor"}  # Reactor is the engine, not addon logic
LOCAL_RE = re.compile(r'^\s*local\s+([A-Za-z_]\w*)\s*=\s*(.+)$')
OPEN_RE = re.compile(r'\b(?:function|if|for|while|repeat)\b')
FORWHILE_RE = re.compile(r'\b(?:for|while)\b')
DO_RE = re.compile(r'\bdo\b')
CLOSE_RE = re.compile(r'\b(?:end|until)\b')


def strip_code(line):
    """Drop comments + string literals so their keywords/identifiers don't count."""
    line = re.sub(r'--.*$', '', line)
    line = re.sub(r'"(?:\\.|[^"\\])*"', '""', line)
    line = re.sub(r"'(?:\\.|[^'\\])*'", "''", line)
    return line


def depth_before(codes):
    """depthBefore[i] = Lua block nesting entering line i."""
    out, d = [], 0
    for c in codes:
        out.append(d)
        opens = len(OPEN_RE.findall(c))
        standalone_do = max(0, len(DO_RE.findall(c)) - len(FORWHILE_RE.findall(c)))
        closes = len(CLOSE_RE.findall(c))
        d += (opens + standalone_do) - closes
    return out


def scan_file(path):
    with open(path, encoding="utf-8") as fh:
        raw = fh.readlines()
    codes = [strip_code(l) for l in raw]
    depths = depth_before(codes)
    hits = []
    for i, code in enumerate(codes):
        m = LOCAL_RE.match(code)
        if not m:
            continue
        var, rhs = m.group(1), m.group(2)
        if "(" not in rhs:  # only value-bearing calls; index/literal locals aren't proxy-guards
            continue
        d = depths[i]
        v = re.escape(var)
        word = re.compile(r'\b' + v + r'\b')                       # any occurrence, incl. X.field / X:m()
        # Sole-condition existence guard only: `if not X then` / `if X == nil then`.
        # NOT `not X or ...` (a legit filter-toggle idiom) and NOT `not X.field`.
        guard = re.compile(r'\bif\s+not\s+' + v + r'\s+then\b|\bif\s+' + v + r'\s*==\s*nil\s+then\b')
        occ, guard_line = 0, None
        for j in range(i + 1, len(codes)):
            if depths[j] < d:  # scope closed
                break
            mj = LOCAL_RE.match(codes[j])
            if mj and mj.group(1) == var:
                break  # shadowed / redeclared
            occ += len(word.findall(codes[j]))                     # TOTAL occurrences, not lines
            if guard.search(codes[j]):
                guard_line = j
        # Dead-guard: fetched, existence-checked to bail, and NEVER otherwise used.
        if occ == 1 and guard_line is not None:
            after = sum(1 for j in range(guard_line + 1, len(codes))
                        if depths[j] >= d and codes[j].strip() and not codes[j].strip().startswith("end"))
            if depths[guard_line + 1] < d:
                after = 0  # guard closes the scope -> it's a conclusion, not a proxy-gate
            if "-- exception(" in raw[guard_line]:
                continue
            hits.append((i + 1, var, guard_line + 1, after, raw[i].rstrip(), raw[guard_line].rstrip()))
    return hits


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    total = 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in sorted(filenames):
            if not fn.endswith(".lua"):
                continue
            for line, var, gline, after, decl, guard in scan_file(os.path.join(dirpath, fn)):
                rel = os.path.relpath(os.path.join(dirpath, fn), root)
                tag = "PROXY-GATE" if after >= 2 else "guard-only"
                print(f"{rel}:{line}  [{tag}] local '{var}' used ONCE, only in the guard at line {gline} ({after} code lines follow in scope)")
                print(f"    {decl.strip()}")
                print(f"    {guard.strip()}")
                total += 1
    if total:
        print(f"\ndead-guard lint: {total} candidate(s). A legit one gets -- exception(<kind>): <reason> on the guard line.")
    else:
        print("dead-guard lint: clean.")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
