#!/usr/bin/env bash
#
# Does coverage-gate.sh read the RIGHT number out of real runner output?
#
#   bash test/coverage.sh
#
# The gate parses five ecosystems. Until this suite existed, one of them had
# been exercised — with text somebody typed to match the pattern they had just
# written. That is not a test of a parser, it is a test of a regex against
# itself, and it passed while four of the five parsers were wrong:
#
#   go test -cover ./...    read the LAST PACKAGE's figure as the project total:
#                           50.0% on a tree whose real total was 28.6%
#   SimpleFormatter         read the LAST FILE's figure as the project total:
#                           100.0% on the same kind of output
#   go tool cover -func     Go's only genuine total — rejected
#   PHPUnit                 claimed in a comment, matched by nothing
#   SimpleCov               matched a line SimpleCov has never printed
#
# Two of those five are the dangerous shape: not a refusal, a confident wrong
# number. A coverage floor is written down once and trusted for years, so an
# overstatement here is not a failed run — it is a gate that certifies a
# standard the tree never met.
#
# Fixtures and their provenance: test/fixtures/coverage/README.md. Every one of
# them keeps the per-unit rows a real run prints, and at least one of those rows
# is deliberately HIGHER than the total, so a parser that grabs the last
# percentage it sees fails here instead of in somebody's CI a year from now.
#
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$SRC/test/fixtures/coverage"

PASS=0; FAIL=0
ok()  { printf '  \033[32mok  \033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n       %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

W="$(mktemp -d)"
trap 'cd /; rm -rf "$W"' EXIT INT TERM HUP
mkdir -p "$W/.claude/scripts" "$W/.claude/state"
cp "$SRC/templates/common/scripts/coverage-gate.sh" "$W/.claude/scripts/coverage-gate.sh"
cd "$W" || exit 1

gate() { bash .claude/scripts/coverage-gate.sh "$@" 2>&1; }
# Exit status separately: `gate | grep` would report grep's status under
# pipefail, and this gate exits 1 exactly when the message under test is
# produced — the same inversion that made test/ratchet.sh assert a correct
# message had failed.
rc() { bash .claude/scripts/coverage-gate.sh "$@" >/dev/null 2>&1; echo $?; }

# measured <fixture> -- the number the gate reports with the floor UNARMED.
measured() {
  gate "$FIX/$1.txt" | grep -oE 'Coverage measured: [0-9.]+%' | grep -oE '[0-9.]+'
}

# reads <fixture> <expected> <why this fixture is a trap>
reads() {
  local got; got="$(measured "$1")"
  if [ "$got" = "$2" ]; then
    ok "$1 -> $2%  ($3)"
  else
    bad "$1 -> $2%  ($3)" "it read '${got:-nothing}'"
  fi
}

# refuses <fixture> <fragment the message must contain>
refuses() {
  local out; out="$(gate "$FIX/$1.txt")"
  if [ "$(rc "$FIX/$1.txt")" != 1 ]; then
    bad "$1 is refused" "it exited 0 — a wrong number that exits 0 becomes the floor"
    return
  fi
  case "$out" in
    *"$2"*) ok "$1 is refused, and the message says why" ;;
    *) bad "$1 refusal names the cause" "expected '$2' in: $(printf '%s' "$out" | head -2)" ;;
  esac
}

rm -f .claude/state/coverage-floor.txt

head_ "1. The total, not a per-unit figure that happens to be nearby"
# Each fixture's decoy is named, because that is the whole assertion. A fixture
# whose only percentage is the total cannot fail, and so proves nothing.
reads istanbul   70     "beta.js shows 100 — higher than the 70 total"
reads coveragepy 56     "pkg/beta.py shows 62 — higher than the 56 TOTAL"
reads pest       42.7   "UserService shows 91.6, and sorts after the Total line"
reads phpunit    42.86  "a per-class 'Lines: 85.71%' follows the summary"
reads simplecov  26.97  "'Branch coverage: 75.00%' is the last line of the run"
reads go-single  20.0   "one package, so that line genuinely is the total"
reads go-func    28.6   "per-function rows include two 100.0% entries"

head_ "2. Output with no total in it is refused, not guessed at"
# The two cases that used to return a confident wrong number.
refuses go-multi "no total"
refuses simplecov-simpleformatter "per-file"

# And the refusal has to be actionable, or it gets worked around by loosening
# the pattern — which is how the wrong number got in.
case "$(gate "$FIX/go-multi.txt")" in
  *"go tool cover -func"*) ok "the go-multi refusal names the command that does produce a total" ;;
  *) bad "the go-multi refusal names the fix" "it does not mention go tool cover -func" ;;
esac

head_ "3. Regression: the exact numbers the old parser reported"
# Pinned as numbers, not as "is correct". If someone reintroduces `tail -1` over
# an unanchored pattern these come back, and a named constant makes the
# reintroduction obvious in the diff rather than a subtle percentage change.
[ "$(measured go-multi)" != "50.0" ] \
  && ok "go-multi no longer reports 50.0 (the last package's figure)" \
  || bad "go-multi no longer reports 50.0" "it is reading the last package again"
[ "$(measured simplecov-simpleformatter)" != "100.0" ] \
  && ok "SimpleFormatter no longer reports 100.0 (the last file's figure)" \
  || bad "SimpleFormatter no longer reports 100.0" "it is reading the last file again"

head_ "4. Unparseable output fails closed"
printf 'Tests: 12 passed\nDone in 4.2s\n' > no-coverage.txt
[ "$(rc no-coverage.txt)" = 1 ] \
  && ok "output with no coverage figure at all exits 1" \
  || bad "output with no coverage figure exits 1" "it exited 0"
[ "$(rc missing-file.txt)" = 1 ] \
  && ok "a missing output file exits 1" \
  || bad "a missing output file exits 1" "it exited 0"
:> empty.txt
[ "$(rc empty.txt)" = 1 ] \
  && ok "an empty output file exits 1" \
  || bad "an empty output file exits 1" "it exited 0 — a died-early run must not pass"

head_ "5. The floor ratchets in both directions"
# 70 is what istanbul.txt measures.
echo 68 > .claude/state/coverage-floor.txt
[ "$(rc "$FIX/istanbul.txt")" = 0 ] \
  && ok "70% against a 68% floor passes" \
  || bad "70% against a 68% floor passes" "$(gate "$FIX/istanbul.txt" | head -2)"

echo 75 > .claude/state/coverage-floor.txt
[ "$(rc "$FIX/istanbul.txt")" = 1 ] \
  && ok "70% against a 75% floor FAILS — coverage went backwards" \
  || bad "below the floor fails" "it passed"

# Far above: a floor that drifts below reality certifies nothing while still
# looking like a gate, which is this script's own stated failure mode.
echo 40 > .claude/state/coverage-floor.txt
[ "$(rc "$FIX/istanbul.txt")" = 1 ] \
  && ok "70% against a 40% floor FAILS, demanding the floor be raised" \
  || bad "far above the floor demands a raise" "it passed silently"
case "$(gate "$FIX/istanbul.txt")" in
  *"coverage-floor.txt"*) ok "the raise message gives the command to run" ;;
  *) bad "the raise message is actionable" "$(gate "$FIX/istanbul.txt" | head -2)" ;;
esac

head_ "6. An unarmed floor reports loudly rather than passing quietly"
rm -f .claude/state/coverage-floor.txt
[ "$(rc "$FIX/istanbul.txt")" = 0 ] \
  && ok "an unarmed floor does not fail a build over a number nobody has seen" \
  || bad "an unarmed floor exits 0" "it failed"
# Exiting 0 makes the job green and indistinguishable from a passing gate.
# Nobody reads stdout in a green job, so the annotation is the actual control.
case "$(gate "$FIX/istanbul.txt")" in
  *"::warning title=Coverage floor is not armed"*) ok "it emits a CI annotation, which a green job cannot hide" ;;
  *) bad "an unarmed floor emits a ::warning annotation" "no annotation in the output" ;;
esac
# A commented-out or blank floor file is 'unset', not 0 — 0 would pass forever.
printf '# not armed yet\n' > .claude/state/coverage-floor.txt
case "$(gate "$FIX/istanbul.txt")" in
  *"NOT ARMED"*) ok "a comment-only floor file reads as unset, not as 0" ;;
  *) bad "a comment-only floor file reads as unset" "$(gate "$FIX/istanbul.txt" | head -2)" ;;
esac

head_ "7. Against a live runner, where one is installed"
# The fixtures are the contract; this is the check that the contract still
# matches reality. CI runners ship Go and Python, so this section is where a
# runner CHANGING its summary format gets noticed — a fixture cannot notice
# that on its own, which is the one thing fixtures are bad at.
LIVE=0
if command -v go >/dev/null 2>&1; then
  LIVE=1
  mkdir -p live/go/beta
  printf 'module example.com/cov\n\ngo 1.21\n' > live/go/go.mod
  printf 'package cov\n\nfunc Add(a, b int) int { return a + b }\n\nfunc Sub(a, b int) int { return a - b }\n' > live/go/alpha.go
  printf 'package cov\n\nimport "testing"\n\nfunc TestAdd(t *testing.T) {\n\tif Add(1, 2) != 3 {\n\t\tt.Fatal("bad")\n\t}\n}\n' > live/go/alpha_test.go
  printf 'package beta\n\nfunc Up(s string) string { return s + "!" }\n\nfunc Unused() int { return 1 }\n' > live/go/beta/beta.go
  printf 'package beta\n\nimport "testing"\n\nfunc TestUp(t *testing.T) {\n\tif Up("a") != "a!" {\n\t\tt.Fatal("bad")\n\t}\n}\n' > live/go/beta/beta_test.go
  (
    cd live/go || exit 1
    GOFLAGS=-mod=mod GOCACHE="$W/gocache" go test -cover ./... > "$W/live-go-multi.txt" 2>&1
    GOFLAGS=-mod=mod GOCACHE="$W/gocache" go test -coverprofile="$W/c.out" ./... >/dev/null 2>&1
    GOCACHE="$W/gocache" go tool cover -func="$W/c.out" > "$W/live-go-func.txt" 2>&1
  )
  if [ -s live-go-multi.txt ] && grep -q 'of statements' live-go-multi.txt; then
    [ "$(rc live-go-multi.txt)" = 1 ] \
      && ok "live multi-package 'go test -cover ./...' is refused" \
      || bad "live multi-package go output is refused" "it reported: $(gate live-go-multi.txt | head -2)"
  else
    printf '  \033[33mskip\033[0m live go test produced no coverage output\n'
  fi
  if [ -s live-go-func.txt ] && grep -q '^total:' live-go-func.txt; then
    got="$(gate live-go-func.txt | grep -oE 'Coverage measured: [0-9.]+%' | grep -oE '[0-9.]+')"
    exp="$(grep '^total:' live-go-func.txt | grep -oE '[0-9]+(\.[0-9]+)?%' | tail -1 | tr -d '%')"
    [ -n "$got" ] && [ "$got" = "$exp" ] \
      && ok "live 'go tool cover -func' parses to its own total line ($exp%)" \
      || bad "live go tool cover -func parses to its total" "gate read '${got:-nothing}', the total line says '$exp'"
  else
    printf '  \033[33mskip\033[0m go tool cover produced no total line\n'
  fi
fi
if python3 -c 'import coverage' >/dev/null 2>&1 && python3 -c 'import pytest' >/dev/null 2>&1; then
  LIVE=1
  mkdir -p live/py/pkg
  printf 'def add(a, b):\n    return a + b\n\n\ndef sub(a, b):\n    return a - b\n\n\ndef unused(a):\n    if a > 0:\n        return "p"\n    return "n"\n' > live/py/pkg/alpha.py
  : > live/py/pkg/__init__.py
  printf 'from pkg.alpha import add\n\n\ndef test_add():\n    assert add(1, 2) == 3\n' > live/py/test_alpha.py
  ( cd live/py && python3 -m pytest --cov=pkg --cov-report=term -q > "$W/live-py.txt" 2>&1 )
  if grep -qE '^TOTAL[[:space:]]' live-py.txt; then
    got="$(gate live-py.txt | grep -oE 'Coverage measured: [0-9.]+%' | grep -oE '[0-9.]+')"
    exp="$(grep -E '^TOTAL[[:space:]]' live-py.txt | grep -oE '[0-9]+%' | tail -1 | tr -d '%')"
    [ -n "$got" ] && [ "$got" = "$exp" ] \
      && ok "live pytest-cov parses to its own TOTAL row ($exp%)" \
      || bad "live pytest-cov parses to its TOTAL row" "gate read '${got:-nothing}', TOTAL says '$exp'"
  else
    printf '  \033[33mskip\033[0m pytest-cov produced no TOTAL row\n'
  fi
fi
[ "$LIVE" = 0 ] && printf '  \033[33mskip\033[0m no supported runner installed; fixtures only\n'

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && { printf 'A coverage gate that reads the wrong number is worse than none.\n'; exit 1; }
printf 'Every parser reads the total, and output without one is refused.\n'
exit 0
