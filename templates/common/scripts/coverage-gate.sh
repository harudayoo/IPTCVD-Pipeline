#!/usr/bin/env bash
# Test-coverage floor, ratcheted in BOTH directions.
#
#   <test command> | tee coverage.txt
#   bash .claude/scripts/coverage-gate.sh coverage.txt
#
# `.claude/rules/testing.md` states a coverage minimum. On the codebase this
# pipeline was extracted from, every CI job set `coverage: none` and the test
# config declared no coverage driver, so the number was never produced -- an
# 80% bar that had never once been measured. That is not a lax gate, it is a
# decorative one: it looks like a control and certifies nothing.
#
# This does not pretend a tree is at any particular number. It makes the REAL
# number visible and stops it falling.
#
#   below the floor        -> FAIL. Coverage went backwards.
#   far above the floor    -> FAIL, asking for the floor to be RAISED. A floor
#                             that drifts far below reality certifies nothing
#                             while still looking like a gate.
#
# The floor starts "unset" so the first run REPORTS the real number rather than
# failing a build over a figure nobody has seen. Commit that number to arm it;
# the run prints the exact command.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

FLOOR_FILE=".claude/state/coverage-floor.txt"
SLACK=5           # percentage points of drift tolerated before demanding a raise
OUT="${1:-}"

if [ -z "$OUT" ] || [ ! -f "$OUT" ]; then
  echo "coverage-gate: need the test output file" >&2
  echo "  usage: <test command> | tee coverage.txt && bash .claude/scripts/coverage-gate.sh coverage.txt" >&2
  exit 1
fi

# --- find the total ---------------------------------------------------------
# One pattern per ecosystem, tried in order. Each is anchored to that runner's
# SUMMARY line rather than to a bare number, because a per-file percentage
# anywhere in the output would otherwise be read as the total.
#
# Adding a runner here is the right way to extend this. Loosening a pattern
# until it matches something is not: a wrong number silently becomes the floor.
extract() {
  local v=""
  # Pest / PHPUnit:            "  Total: 42.7 %"
  v=$(grep -oE '^[[:space:]]*Total:[[:space:]]*[0-9]+(\.[0-9]+)?[[:space:]]*%' "$OUT" 2>/dev/null \
      | tail -1 | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
  [ -n "$v" ] && { printf '%s' "$v"; return; }
  # Istanbul / jest / vitest:  "All files |   82.35 |"
  v=$(grep -E '^[[:space:]]*All files[[:space:]]*\|' "$OUT" 2>/dev/null \
      | tail -1 | awk -F'|' '{gsub(/ /,"",$2); print $2}' | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
  [ -n "$v" ] && { printf '%s' "$v"; return; }
  # coverage.py / pytest-cov:  "TOTAL   1234   56   95%"
  v=$(grep -E '^TOTAL[[:space:]]' "$OUT" 2>/dev/null \
      | tail -1 | grep -oE '[0-9]+(\.[0-9]+)?%' | tail -1 | tr -d '%')
  [ -n "$v" ] && { printf '%s' "$v"; return; }
  # Go:                        "coverage: 78.4% of statements"
  v=$(grep -oE 'coverage:[[:space:]]*[0-9]+(\.[0-9]+)?%' "$OUT" 2>/dev/null \
      | tail -1 | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
  [ -n "$v" ] && { printf '%s' "$v"; return; }
  # SimpleCov (Ruby):          "Line Coverage: 91.2%"
  v=$(grep -oE '[Ll]ine [Cc]overage:[[:space:]]*[0-9]+(\.[0-9]+)?%' "$OUT" 2>/dev/null \
      | tail -1 | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
  printf '%s' "${v:-}"
}
MEASURED=$(extract)

if [ -z "${MEASURED:-}" ]; then
  echo "coverage-gate: could not find a coverage total in $OUT." >&2
  echo "  Either the runner changed its summary format, coverage was not enabled" >&2
  echo "  for this run, or the run died before printing it." >&2
  echo "  Refusing to report a pass off a number that was never parsed." >&2
  exit 1
fi

FLOOR="unset"
[ -f "$FLOOR_FILE" ] && FLOOR=$(grep -vE '^[[:space:]]*#' "$FLOOR_FILE" 2>/dev/null | tr -d ' \r\n\t')
[ -n "$FLOOR" ] || FLOOR="unset"

if [ "$FLOOR" = "unset" ]; then
  echo "=============================================================="
  echo " Coverage measured: ${MEASURED}%  —  the floor is NOT ARMED."
  echo " Arm it by writing that number into $FLOOR_FILE:"
  echo "   echo ${MEASURED%.*} > $FLOOR_FILE"
  echo " Until then this step reports and never fails."
  echo "=============================================================="

  # An unarmed floor exits 0, so the job goes green and looks EXACTLY like a
  # passing gate -- the same "certifies nothing while looking like a gate"
  # failure this script's own header warns about, one level up. Nobody reads
  # stdout in a green job. An annotation surfaces on the run and on the PR, and
  # the step summary puts the number where it has to be copied from anyway.
  # Both are inert outside GitHub Actions.
  echo "::warning title=Coverage floor is not armed::Coverage is ${MEASURED}% and ${FLOOR_FILE} says 'unset', so this gate cannot fail. Arm it: echo ${MEASURED%.*} > ${FLOOR_FILE}"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### ⚠️ Coverage floor NOT armed"
      echo ""
      echo "Measured coverage: **${MEASURED}%**"
      echo ""
      echo "This gate is reporting only — it cannot fail a build until the floor is armed:"
      echo ""
      echo '```bash'
      echo "echo ${MEASURED%.*} > ${FLOOR_FILE}"
      echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 0
fi

# Integer comparison in tenths, so 42.7 vs 42 needs no bc/awk dependency at
# comparison time and no locale-sensitive float parsing.
to_tenths() { printf '%s' "$1" | awk -F. '{ printf "%d", ($1*10) + (NF>1 ? substr($2"0",1,1) : 0) }'; }
M=$(to_tenths "$MEASURED"); F=$(to_tenths "$FLOOR"); S=$((SLACK * 10))

if [ "$M" -lt "$F" ]; then
  echo "COVERAGE: ${MEASURED}% is below the ${FLOOR}% floor." >&2
  echo "  Add tests for what this change touched. Lowering the floor to pass is the" >&2
  echo "  one move that makes this gate worthless -- do that only with a reason stated" >&2
  echo "  in the commit." >&2
  exit 1
fi

if [ "$M" -gt "$((F + S))" ]; then
  echo "COVERAGE: ${MEASURED}% is more than ${SLACK} points above the ${FLOOR}% floor." >&2
  echo "  Raise it so the gate keeps meaning something:" >&2
  echo "    echo ${MEASURED%.*} > $FLOOR_FILE" >&2
  exit 1
fi

echo "coverage-gate: OK (${MEASURED}%, floor ${FLOOR}%)"
