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
# One pattern per ecosystem, tried MOST SPECIFIC FIRST. Each is anchored to that
# runner's SUMMARY line rather than to a bare number, because a per-file
# percentage anywhere in the output would otherwise be read as the total.
#
# Every pattern below was checked against real output (test/fixtures/coverage/,
# which records what was captured from a live run and what was derived from the
# runner's own format string). That exercise found the parser wrong in four of
# the five ecosystems it claimed, two of them silently:
#
#   go test -cover ./...   reported the LAST PACKAGE's figure as the project
#                          total -- measured 50.0% on a tree whose real total
#                          was 28.6%, and which package sorts last is arbitrary
#   SimpleFormatter        reported the LAST FILE's figure as the project total
#                          (100.0%), because Ruby per-file rows read
#                          `foo.rb (coverage: 100.0%)` and the Go pattern
#                          matched them
#   go tool cover -func    Go's only real total, rejected outright
#   PHPUnit                claimed in a comment, matched by nothing; only Pest
#                          prints `Total: n %`
#   SimpleCov              looked for `Line Coverage: 91.2%`, which SimpleCov
#                          has never printed -- the real line is
#                          `Line coverage: 123 / 456 (26.97%)`
#
# Adding a runner here is the right way to extend this. Loosening a pattern
# until it matches something is not: a wrong number silently becomes the floor,
# and a floor is the one number nobody re-derives later.
#
# Prints either a bare number, or `AMBIGUOUS:<reason>` when the output carries
# per-unit percentages but no total. Refusing there is not pedantry -- picking
# one of them is how a 28.6% tree would arm its floor at 50%.
extract() {
  local v="" n=""

  # Pest: "  Total: 42.7 %". Pest's own renderer, not PHPUnit's.
  v=$(grep -oE '^[[:space:]]*Total:[[:space:]]*[0-9]+(\.[0-9]+)?[[:space:]]*%' "$OUT" 2>/dev/null \
      | tail -1 | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
  [ -n "$v" ] && { printf '%s' "$v"; return; }

  # PHPUnit text report: "  Lines:    42.86% (3/7)" under " Summary:".
  # Anchored to line start on purpose: the per-class block further down prints
  # its own "Lines:  85.71% ( 6/ 7)" MID-LINE, after the summary, so an
  # unanchored match plus `tail -1` reads one class instead of the project.
  v=$(grep -oE '^[[:space:]]*Lines:[[:space:]]+[0-9]+(\.[0-9]+)?%' "$OUT" 2>/dev/null \
      | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
  [ -n "$v" ] && { printf '%s' "$v"; return; }

  # Istanbul / c8 / jest / vitest: "All files |   82.35 |"
  v=$(grep -E '^[[:space:]]*All files[[:space:]]*\|' "$OUT" 2>/dev/null \
      | tail -1 | awk -F'|' '{gsub(/ /,"",$2); print $2}' | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
  [ -n "$v" ] && { printf '%s' "$v"; return; }

  # coverage.py / pytest-cov: "TOTAL   1234   56   95%"
  v=$(grep -E '^TOTAL[[:space:]]' "$OUT" 2>/dev/null \
      | tail -1 | grep -oE '[0-9]+(\.[0-9]+)?%' | tail -1 | tr -d '%')
  [ -n "$v" ] && { printf '%s' "$v"; return; }

  # Go, the only form that carries a real total:
  #   "total:            (statements)    28.6%"   <- go tool cover -func
  v=$(grep -oE '^total:[[:space:]].*[[:space:]][0-9]+(\.[0-9]+)?%' "$OUT" 2>/dev/null \
      | tail -1 | grep -oE '[0-9]+(\.[0-9]+)?%' | tail -1 | tr -d '%')
  [ -n "$v" ] && { printf '%s' "$v"; return; }

  # SimpleCov: "Line coverage: 123 / 456 (26.97%)". Lowercase 'c' -- that is
  # what lib/simplecov/formatter/base.rb formats. Anchored to Line so the
  # "Branch coverage:" line that follows is not read instead; branch coverage
  # is a different measurement and is usually the higher number.
  v=$(grep -oiE '^[[:space:]]*Line coverage:[^(]*\([0-9]+(\.[0-9]+)?%\)' "$OUT" 2>/dev/null \
      | tail -1 | grep -oE '[0-9]+(\.[0-9]+)?%' | tail -1 | tr -d '%')
  [ -n "$v" ] && { printf '%s' "$v"; return; }

  # Go, per-package: "ok  example.com/cov  0.15s  coverage: 20.0% of statements"
  # `of statements` is load-bearing -- without it this also matches Ruby's
  # per-file "(coverage: 100.0%)" rows, which is exactly how a per-file figure
  # became a project total.
  #
  # One package: that line IS the total. More than one: this output contains no
  # total at all, and `tail -1` would silently pick whichever package sorted
  # last. Go prints no aggregate here; `go tool cover -func` does.
  n=$(grep -cE 'coverage:[[:space:]]*[0-9]+(\.[0-9]+)?%[[:space:]]*of statements' "$OUT" 2>/dev/null)
  if [ "${n:-0}" -gt 1 ]; then
    printf 'AMBIGUOUS:%s' "go test -cover ./... printed $n per-package figures and no total.
  Go does not aggregate them; whichever package sorted last would become the floor.
  Produce a real total instead:
    go test -coverprofile=c.out ./... && go tool cover -func=c.out | tee coverage.txt"
    return
  fi
  if [ "${n:-0}" = 1 ]; then
    v=$(grep -oE 'coverage:[[:space:]]*[0-9]+(\.[0-9]+)?%[[:space:]]*of statements' "$OUT" 2>/dev/null \
        | tail -1 | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
    [ -n "$v" ] && { printf '%s' "$v"; return; }
  fi

  # SimpleCov's SimpleFormatter prints per-file rows and NO total:
  #   "/app/lib/beta.rb (coverage: 100.0%)"
  # Reporting the last of those as the project figure is the failure this whole
  # function exists to avoid, so name it rather than guess.
  n=$(grep -cE '\(coverage:[[:space:]]*[0-9]+(\.[0-9]+)?%\)' "$OUT" 2>/dev/null)
  if [ "${n:-0}" -gt 0 ]; then
    printf 'AMBIGUOUS:%s' "this output has $n per-file coverage figures and no project total
  (SimpleCov's SimpleFormatter). Switch to the default formatter, which prints
  Line coverage: <covered> / <total> (<percent>), or any formatter that emits a total."
    return
  fi

  printf ''
}
MEASURED=$(extract)

# A parse that found per-unit numbers but no total is NOT a parse failure to be
# retried with a looser pattern. It is the one case where guessing produces a
# plausible, wrong, permanent number.
case "$MEASURED" in
  AMBIGUOUS:*)
    echo "coverage-gate: $OUT has per-unit percentages but no project total." >&2
    echo "  ${MEASURED#AMBIGUOUS:}" >&2
    echo "  Refusing to arm a floor off a number that is not the project's." >&2
    exit 1
    ;;
esac

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
