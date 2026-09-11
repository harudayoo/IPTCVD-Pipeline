#!/usr/bin/env bash
# File-size ratchet for the project's source roots.
#
#   bash .claude/scripts/ratchet.sh            # check (CI runs this)
#   bash .claude/scripts/ratchet.sh --update   # re-record the baseline
#   bash .claude/scripts/ratchet.sh --list     # every file over the bar, largest first
#
# Why this exists: `.claude/rules/*.md` state a file-size standard, and until
# something measures it the standard is a preference. Measured on the codebase
# this pipeline was extracted from, where the 800-line bar had been written down
# for months and checked by nothing: 13 files were over it, topping out at 2,100
# lines -- and 28 of that codebase's 30 react-hooks violations lived in a single
# 1,476-line file. That is not a coincidence. Nobody refactors a file they cannot
# hold in their head, so defects accumulate where the lines do.
#
# It is a RATCHET, not a cleanup, and that distinction is what makes it
# adoptable on a tree that is already over the bar:
#
#   a baselined file   may SHRINK, never grow
#   an unlisted file   may not cross the bar at all
#
# Regenerating the baseline is allowed -- in the same commit, with a reason. The
# point is not that it is impossible, it is that it is VISIBLE. Without a
# ceiling the cheapest way past a hard limit on a legacy tree is to delete the
# limit, and that happens quietly.
#
# Deliberately counts LINES ONLY. Function length, nesting depth and parameter
# counts need a real parser per language to measure honestly; they stay in the
# rules as stated standards that the reviewing agent checks by reading.
# Claiming to enforce them here would be the "green while broken" failure this
# whole pipeline exists to remove.
#
# The BAR lives in the baseline file, not in this script, so changing it is a
# committed diff somebody can object to rather than an edit to a tool.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

BASELINE=".claude/state/size-baseline.tsv"
DEFAULT_BAR=800
SOURCE_ROOTS="{{SOURCE_ROOTS}}"
MODE="${1:-check}"

if printf '%s' "$SOURCE_ROOTS" | grep -q '{{'; then
  echo "ratchet: not configured (SOURCE_ROOTS is still a placeholder)." >&2
  echo "  Fill docs/setup/PROFILE.md and run ./configure.sh" >&2
  exit 1
fi

# Read the bar out of the baseline header; fall back to the default on a first
# run. `grep -m1` so a stray later line cannot silently change the bar.
read_bar() {
  local b=""
  [ -f "$BASELINE" ] && b=$(grep -m1 -oE '^# bar: *[0-9]+' "$BASELINE" 2>/dev/null | grep -oE '[0-9]+')
  printf '%s' "${b:-$DEFAULT_BAR}"
}
BAR=$(read_bar)

# ONE `wc` spawn for the whole tree, not one per file.
#
# The first version of this in the origin codebase ran `wc -l` inside a per-file
# loop and took over 120 SECONDS on ~1,200 files; the single-pass form below
# takes under a second. On Windows a process spawn costs ~120ms, so a spawn
# inside a loop over a source tree is not a slow script, it is a broken one --
# the same lesson the gate hooks learned about parsing JSON per key.
#
# `wc -l` prints "<count> <path>", so the count is field 1 and the REST is the
# path: a path containing spaces survives. find batches with `+`, so wc emits a
# "total" line per batch, dropped by name below.
scan() {
  local -a roots=()
  local r
  for r in $(printf '%s' "$SOURCE_ROOTS" | tr ',' ' '); do
    [ -d "$r" ] && roots+=("$r")
  done
  [ "${#roots[@]}" -gt 0 ] || return 0
  find "${roots[@]}" -type f \
    \( -name '*.php' -o -name '*.js' -o -name '*.jsx' -o -name '*.ts' -o -name '*.tsx' \
       -o -name '*.vue' -o -name '*.svelte' -o -name '*.py' -o -name '*.go' -o -name '*.rs' \
       -o -name '*.rb' -o -name '*.java' -o -name '*.kt' -o -name '*.cs' -o -name '*.swift' \) \
    -not -path '*/node_modules/*' -not -path '*/vendor/*' -not -path '*/dist/*' \
    -not -path '*/build/*' -not -path '*/.git/*' \
    -exec wc -l {} + 2>/dev/null \
  | awk -v bar="$BAR" '{
      n = $1; $1 = ""; sub(/^[ \t]+/, "")
      if ($0 != "total" && $0 != "" && n + 0 > bar + 0) printf "%s\t%d\n", $0, n
    }' \
  | LC_ALL=C sort
}

case "$MODE" in
  --list)
    printf '%s\n' "$(scan | sort -t"$(printf '\t')" -k2 -nr)"
    exit 0
    ;;

  --update)
    mkdir -p "$(dirname "$BASELINE")"
    TMP="$BASELINE.tmp$$"
    {
      echo "# bar: $BAR"
      echo "# Files over $BAR lines, with the size they were recorded at."
      echo "# Ratchet: a listed file may shrink, never grow."
      echo "#          an unlisted file may not cross $BAR at all."
      echo "# Regenerate deliberately, in the same commit, with a reason --"
      echo "# never to get a build green."
      scan
    } > "$TMP" && mv "$TMP" "$BASELINE"
    echo "ratchet: recorded $(grep -cv '^#' "$BASELINE" | tr -d ' ') file(s) over $BAR lines in $BASELINE"
    exit 0
    ;;
esac

if [ ! -f "$BASELINE" ]; then
  # No baseline is not a pass. Say what to run, and fail -- an unarmed ratchet
  # that exits 0 looks exactly like a passing one.
  echo "ratchet: no baseline at $BASELINE." >&2
  echo "  Record the tree as it is today, then commit it:" >&2
  echo "    bash .claude/scripts/ratchet.sh --update" >&2
  exit 1
fi

# Load the baseline ONCE. Re-grepping it per candidate would reintroduce the
# spawn-in-a-loop cost this script exists to avoid, just at a smaller scale.
declare -A WAS=()
while IFS=$'\t' read -r f n; do
  case "${f:-}" in ""|\#*) continue ;; esac
  WAS["$f"]="${n%$'\r'}"
done < "$BASELINE"

FAIL=0
GREW=0
NEW=0
while IFS=$'\t' read -r f n; do
  [ -n "${f:-}" ] || continue
  was="${WAS[$f]:-}"
  if [ -z "$was" ]; then
    echo "SIZE: $f is $n lines, over the $BAR-line bar, and is not baselined." >&2
    NEW=$((NEW + 1)); FAIL=1
  elif [ "$n" -gt "$was" ]; then
    echo "SIZE: $f grew from $was to $n lines (already over the $BAR-line bar)." >&2
    GREW=$((GREW + 1)); FAIL=1
  fi
done < <(scan)

if [ "$FAIL" != 0 ]; then
  echo >&2
  [ "$NEW" -gt 0 ]  && echo "  $NEW file(s) crossed the bar. Split them into cohesive units." >&2
  [ "$GREW" -gt 0 ] && echo "  $GREW baselined file(s) grew. Oversized files may shrink, never grow -- extract before adding." >&2
  echo "  If it is genuinely unavoidable, re-record in the SAME commit, with a reason:" >&2
  echo "    bash .claude/scripts/ratchet.sh --update" >&2
  exit 1
fi

echo "ratchet: OK ($(grep -cv '^#' "$BASELINE" | tr -d ' ') file(s) baselined over $BAR lines, none grew)"
