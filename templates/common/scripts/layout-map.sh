#!/usr/bin/env bash
# Writes the codebase-map skill's layout.md: where code actually lives in THIS
# repository, as the gate sees it -- which directories each source root
# matches, how much code is under each, which test roots and shared surfaces
# exist, and what code no root guards at all.
#
#   bash .claude/scripts/layout-map.sh           # (re)write layout.md
#   bash .claude/scripts/layout-map.sh --check   # exit 1 if layout.md is stale
#   bash .claude/scripts/layout-map.sh --print   # write nothing, print it
#
# WHY GENERATED, not written by an agent: every repository this pipeline is
# installed in has its own shape -- monorepos, src/main trees, personal
# layouts -- and the alternative to a map is every fresh subagent re-reading
# the tree to rediscover it. A hand-written map, or a notes vault, is cheaper
# to read but goes stale silently the first time someone adds a package, and a
# stale map is worse than none: it is trusted. This one is derived from
# `git ls-files` and the compiled roots, stamps the commit it describes, and
# `--check` says when HEAD has moved past it, so "is this still true?" is a
# command, not a judgement.
#
# Structure only. What a module MEANS, why it is shaped that way, and its
# landmines stay in the codebase-map SKILL.md body, which a person or the
# memory-seeding pass writes. If graphify-out/GRAPH_REPORT.md exists, its age
# is reported too, so a stale code graph is as visible as a stale map.
set -uo pipefail
# Absolute BEFORE the cd below: --check re-runs this script with --print, and
# a relative $0 stops resolving the moment the working directory changes.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=/dev/null
. "$(dirname "$SELF")/../hooks/_guard.sh" || { echo "layout-map.sh: cannot find ../hooks/_guard.sh" >&2; exit 1; }
studio_locate "$SELF"
cd "$STUDIO_PROJECT" || { echo "layout-map.sh: cannot enter $STUDIO_PROJECT" >&2; exit 1; }

SOURCE_ROOTS="{{SOURCE_ROOTS}}"
SOURCE_RE="{{SOURCE_ROOTS_REGEX}}"
TEST_RE="{{TEST_ROOTS_REGEX}}"
SHARED_RE="{{SHARED_SURFACE_REGEX}}"
OUT="$STUDIO_HOME/.claude/skills/codebase-map/layout.md"
MODE="${1:-write}"

case "$SOURCE_RE" in *'{{'*)
  echo "layout-map: not configured (source roots are still a placeholder)." >&2
  echo "  Fill docs/setup/PROFILE.md and run ./configure.sh" >&2
  exit 1 ;;
esac
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "layout-map: $STUDIO_PROJECT is not a git work tree; the map is built from git ls-files." >&2; exit 1; }

HEAD_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "no-commits")

# The map describes TRACKED code. Uncommitted files are left out on purpose:
# the map says what HEAD is, and --check compares against HEAD.
if [ "$MODE" = "--check" ]; then
  [ -f "$OUT" ] || { echo "layout-map: no layout.md yet -- run: bash .claude/scripts/layout-map.sh" >&2; exit 1; }
  have=$(sed -n 's/^Built from commit `\([^`]*\)`.*/\1/p' "$OUT" | head -1)
  if [ "$have" != "$HEAD_SHA" ]; then
    # Stale by commit is not stale by STRUCTURE: a commit that edits or adds
    # files inside directories the map already names leaves it true. Rebuild
    # in memory and compare with the counts stripped, so --check fails only
    # when a directory appeared, vanished, or moved in or out of a root --
    # not on every commit, which would teach everyone to ignore it.
    shape() { sed -e '/^Built from commit/d' -e '/^- `graphify-out/d' -E -e 's/[0-9]+//g'; }
    new=$("$SELF" --print 2>/dev/null | shape)
    old=$(shape < "$OUT")
    if [ "$new" != "$old" ]; then
      echo "layout-map: layout.md describes $have, HEAD is $HEAD_SHA, and the layout changed." >&2
      echo "  Re-run: bash .claude/scripts/layout-map.sh" >&2
      exit 1
    fi
  fi
  echo "layout-map: layout.md is current."
  exit 0
fi

CODE_EXT='\.(ts|tsx|js|jsx|mjs|cjs|vue|svelte|astro|py|go|rs|php|rb|java|kt|kts|scala|cs|vb|fs|cshtml|razor|swift|m|mm|c|cc|cpp|h|hpp|sql|dart|ex|exs|erl|clj|lua|sh)$'

render() {
  printf '# Layout (generated)\n\n'
  printf 'Built from commit `%s` by `layout-map.sh`. Do not edit by hand -- re-run it.\n' "$HEAD_SHA"
  printf 'Check freshness with `bash .claude/scripts/layout-map.sh --check`.\n\n'
  printf 'Declared source roots: `%s`\n\n' "$SOURCE_ROOTS"

  git -c core.quotePath=false ls-files 2>/dev/null | grep -iE "$CODE_EXT" \
  | SRE="$SOURCE_RE" TRE="$TEST_RE" XRE="$SHARED_RE" awk '
    # ENVIRON, never -v: -v would process the backslash escapes configure.sh
    # wrote into the patterns and widen `Web\.Api` into `Web.Api`.
    BEGIN { sre = tolower(ENVIRON["SRE"]); tre = ENVIRON["TRE"]; xre = ENVIRON["XRE"] }
    function ext(f,   n, p) { n = split(f, p, "."); return n > 1 ? p[n] : "-" }
    {
      f = $0; lc = tolower(f)
      if (tre != "" && f ~ tre) { match(f, tre); t = substr(f, 1, RLENGTH - 1); tests[t]++; next }
      if (lc ~ sre) {
        match(lc, sre); root = substr(f, 1, RLENGTH); sub(/\/$/, "", root)
        rest = substr(f, length(root) + 2)
        n = split(rest, seg, "/")
        key = (n > 1) ? root "/" seg[1] : root " (files at root)"
        roots[root]++; dirs[key]++; dext[key, ext(f)]++; dkeys[key] = 1
        if (xre != "" && f ~ xre) { match(f, xre); s = substr(f, 1, RLENGTH - 1); shared[s]++ }
        next
      }
      if (f ~ /(^|\/)(\.[^\/]*|docs|node_modules|vendor|dist|build|out|bin|obj|coverage|fixtures)\//) next
      n = split(f, seg, "/")
      key = (n > 2) ? seg[1] "/" seg[2] : (n == 2 ? seg[1] : "(repo root)")
      loose[key]++
    }
    function top_ext(k,   e, best, bn, out, i, used) {
      out = ""
      for (i = 0; i < 3; i++) {
        best = ""; bn = 0
        for (e in exts) if (dext[k, e] > bn && !((k, e) in used)) { best = e; bn = dext[k, e] }
        if (best == "") break
        used[k, best] = 1; out = out (out == "" ? "" : " ") "." best
      }
      return out
    }
    END {
      for (k in dext) { split(k, kp, SUBSEP); exts[kp[2]] = 1 }

      print "## Guarded source (the gate requires a plan before any edit here)\n"
      print "| Directory | Code files |"
      print "|---|---|"
      nr = 0; for (r in roots) rl[++nr] = r
      asort_str(rl, nr)
      for (i = 1; i <= nr; i++) printf "| `%s` | %d |\n", rl[i], roots[rl[i]]
      if (nr == 0) print "| (no tracked code under any declared root) | 0 |"

      print "\n## Inside each root, one level down\n"
      print "| Directory | Files | Mostly |"
      print "|---|---|---|"
      nd = 0; for (d in dkeys) dl[++nd] = d
      asort_str(dl, nd)
      cap = 60
      for (i = 1; i <= nd && i <= cap; i++) printf "| `%s` | %d | %s |\n", dl[i], dirs[dl[i]], top_ext(dl[i])
      if (nd > cap) printf "| ... %d more | | |\n", nd - cap

      print "\n## Test roots (writable in every phase)\n"
      nt = 0; for (t in tests) tl[++nt] = t
      asort_str(tl, nt)
      for (i = 1; i <= nt; i++) printf "- `%s` -- %d files\n", tl[i], tests[tl[i]]
      if (nt == 0) print "- none by location; test files are recognised by filename only"

      print "\n## Shared surfaces (a NEW file here must state what it reuses)\n"
      ns = 0; for (s in shared) sl[++ns] = s
      asort_str(sl, ns)
      for (i = 1; i <= ns; i++) printf "- `%s` -- %d files\n", sl[i], shared[sl[i]]
      if (ns == 0) print "- none declared, or none with code yet"

      print "\n## Code outside every root (NOT guarded)\n"
      nl = 0; for (l in loose) ll[++nl] = l
      asort_str(ll, nl)
      for (i = 1; i <= nl && i <= 30; i++) printf "- `%s` -- %d files\n", ll[i], loose[ll[i]]
      if (nl > 30) printf "- ... %d more\n", nl - 30
      if (nl == 0) print "- none: every tracked code file is under a declared root"
      else print "\nEdits here skip the plan and test phases. Add a root in docs/setup/PROFILE.md and re-run configure.sh if that is not intended."
    }
    # Portable insertion sort: asort() is gawk-only, and macOS ships BSD awk.
    function asort_str(a, n,   i, j, v) {
      for (i = 2; i <= n; i++) { v = a[i]; j = i - 1
        while (j > 0 && a[j] > v) { a[j + 1] = a[j]; j-- }
        a[j + 1] = v }
    }'

  printf '\n## Code graph\n\n'
  if [ -f graphify-out/GRAPH_REPORT.md ]; then
    g_sha=$(git log -1 --format=%h -- graphify-out/GRAPH_REPORT.md 2>/dev/null)
    behind=""
    [ -n "$g_sha" ] && behind=$(git rev-list --count "$g_sha"..HEAD 2>/dev/null)
    printf -- '- `graphify-out/GRAPH_REPORT.md` exists'
    if [ -n "$behind" ]; then printf ', committed %s commit(s) behind HEAD.\n' "$behind"; else printf ' (uncommitted).\n'; fi
    printf -- '- Read it before exploring. Edges tagged INFERRED or AMBIGUOUS are hints: open the file before citing one.\n'
  else
    printf -- '- none. Optional: graphify (see the codebase-map skill).\n'
  fi
}

case "$MODE" in
  --print) render ;;
  write|"")
    mkdir -p "$(dirname "$OUT")"
    render > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
    echo "layout-map: wrote ${OUT#"$STUDIO_HOME"/} ($(wc -l < "$OUT" | tr -d ' ') lines, commit $HEAD_SHA)"
    ;;
  -h|--help) sed -n '2,24p' "$SELF" | sed 's/^# \{0,1\}//' ;;
  *) echo "usage: layout-map.sh [--check|--print]" >&2; exit 1 ;;
esac
