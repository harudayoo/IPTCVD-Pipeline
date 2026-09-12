#!/usr/bin/env bash
#
# Can the test suites fail?
#
#   bash test/mutation.sh            # every mutation
#   bash test/mutation.sh gate       # only ids containing 'gate'
#   bash qa.sh --mutate              # same thing, through the front door
#
#   MUTATE_JOBS=8 bash test/mutation.sh    # wider; default 4
#
# A green suite is evidence of nothing until you have seen it go red. This
# repository learned that twice in one week, and both times the suite was
# already "passing":
#
#   - a newline guard used "$(printf '\n')", which command substitution strips
#     to the empty string. The pattern became `**`, which matches everything, so
#     eight refusal cases reported PASS while the guard rejected every valid
#     value. Two bugs cancelling to green.
#   - test/hooks.sh called fail() with one argument where it takes three. Under
#     `set -u` the drift check aborted the suite -- exit 0, no summary line,
#     real detection swallowed.
#
# Neither is visible from a passing run. Both are obvious the moment you ask a
# suite to catch a defect it claims to catch.
#
# So: reintroduce each defect this repository has actually shipped, one at a
# time, into a COPY of the tree, and require the named suite to go red. A
# mutation that survives is an assertion that cannot fail -- a line in a test
# file that costs CI time and buys nothing.
#
# Every mutation below is a real regression, not an invented one. The comment on
# each says what shipped.
#
# THREE outcomes, and the third is the one people get wrong:
#
#   caught    the suite went red. The assertion is load-bearing.
#   ESCAPED   the suite stayed green with the defect present. A gap.
#   BROKEN    the mutation did not apply -- its anchor text no longer exists.
#             NOT a pass. An un-applied mutation runs a clean tree and of
#             course it is green; counting that as `caught` is how a mutation
#             suite rots into a very slow way of running the tests twice.
#
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILTER="${1:-}"
JOBS="${MUTATE_JOBS:-4}"

W="$(mktemp -d)"
trap 'cd /; rm -rf "$W"' EXIT INT TERM HUP
SPEC="$W/spec"
: > "$SPEC"
N=0

head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# mutate <id> <suite> <file> <old> <new> <what shipped>
#
# Records the mutation; nothing runs until the pool below. The replacement must
# match EXACTLY ONCE. Not "at least once": a mutation firing in two places may
# be testing something other than what its name says, and one firing in none is
# the BROKEN case above.
mutate() {
  case "$1" in *"$FILTER"*) ;; *) return ;; esac
  N=$((N + 1))
  local n; n=$(printf '%03d' "$N")
  printf '%s\n' "$4" > "$W/$n.old"
  printf '%s\n' "$5" > "$W/$n.new"
  printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$1" "$2" "$3" "$6" >> "$SPEC"
}
section() { printf 'SECTION\t%s\n' "$1" >> "$SPEC"; }

# ============================================================ the mutations

section "1. The gate itself"

# Shipped: the gate authorised the STRING it was handed rather than the file
# that string resolves to. Six of seven path spellings walked through a closed
# gate, including the absolute path Claude Code always sends.
mutate gate-canonicalisation test/hooks.sh \
  templates/common/hooks/gate-check.sh \
  'if ! studio_normalise_path FILE; then' \
  'if false; then' \
  'gate authorises the raw path string, not the resolved file'

# Shipped: `*test*` matched anywhere in a path, so LatestReport.ts and
# InspectorController.ts were ungated by filename coincidence.
mutate gate-substring-allow qa.sh \
  templates/common/hooks/gate-check.sh \
  '  docs/*|.claude/*|*.md) exit 0 ;;' \
  '  docs/*|.claude/*|*.md|*test*|*spec*) exit 0 ;;' \
  'allow rule matches a substring anywhere in the path'

# Shipped: the gate stored only {"phase":"create"} -- it certified that a plan
# existed, never what it said.
mutate gate-empty-problem test/hooks.sh \
  templates/common/scripts/gate.sh \
  '    [ -z "$PROBLEM" ] && MISSING="--problem"' \
  '    MISSING="$MISSING"' \
  'the gate opens with no problem stated at all'

# A one-token answer is the box-tick the phase gate replaced.
mutate gate-keystroke-answer test/hooks.sh \
  templates/common/scripts/gate.sh \
  'if [ ${#P_C} -lt 12 ]; then' \
  'if [ ${#P_C} -lt 0 ]; then' \
  'a single keystroke passes as the IDEA phase'

section "2. The second door"

# Shipped: gate-check registered on Edit|Write only, so `sed -i`, `cat >`, `cp`
# and every package manager walked past it.
mutate bashgate-unregistered qa.sh \
  templates/tiers/pro/settings.json.tmpl \
  'bash-gate.sh' 'bash-gate-disabled.sh' \
  'the shell door is not registered on Bash'

mutate bashgate-ignores-sed test/hooks.sh \
  templates/common/hooks/bash-gate.sh \
  '    sed)' '    sed-disabled)' \
  'sed -i is no longer recognised as a write'

section "3. The evidence the gates read"

# Shipped: `cmd | grep | head` reports the LAST command's status, so a red
# suite, a failed build and a high-severity audit finding all exited 0 --
# through the tool whose entire job is producing the evidence.
mutate filter-exit-status qa.sh \
  templates/common/hooks/filter-output.sh \
  '__rc=\${PIPESTATUS[0]}' '__rc=0' \
  'a failing command reports success through the filter'

section "4. The measurements"

mutate ratchet-allows-growth test/ratchet.sh \
  templates/common/scripts/ratchet.sh \
  'elif [ "$n" -gt "$was" ]; then' \
  'elif [ "$n" -gt 999999 ]; then' \
  'a baselined file may grow -- so it is not a ratchet'

mutate ratchet-ignores-crossing test/ratchet.sh \
  templates/common/scripts/ratchet.sh \
  'echo "SIZE: $f is $n lines, over the $BAR-line bar, and is not baselined." >&2' \
  ': "$f $n $BAR"' \
  'an unlisted file may cross the bar freely'

# Found by writing test/coverage.sh: `go test -cover ./...` prints one line per
# package and no total, and `tail -1` made whichever package sorted last into
# the project figure -- 50.0% measured on a tree whose real total was 28.6%.
mutate coverage-go-last-package test/coverage.sh \
  templates/common/scripts/coverage-gate.sh \
  '  if [ "${n:-0}" -gt 1 ]; then' \
  '  if [ "${n:-0}" -gt 999 ]; then' \
  'the last Go package figure is reported as the project total'

# Same shape in Ruby: SimpleFormatter prints per-file rows and no total.
mutate coverage-perfile-total test/coverage.sh \
  templates/common/scripts/coverage-gate.sh \
  "  n=\$(grep -cE '\\(coverage:[[:space:]]*[0-9]+(\\.[0-9]+)?%\\)' \"\$OUT\" 2>/dev/null)" \
  '  n=0' \
  'a per-file percentage is accepted as the project total'

mutate coverage-below-floor-passes test/coverage.sh \
  templates/common/scripts/coverage-gate.sh \
  'if [ "$M" -lt "$F" ]; then' \
  'if [ "$M" -lt -1 ]; then' \
  'coverage below the floor still passes'

mutate coverage-unparsed-passes test/coverage.sh \
  templates/common/scripts/coverage-gate.sh \
  '  echo "  Refusing to report a pass off a number that was never parsed." >&2' \
  '  exit 0' \
  'output with no coverage figure at all reports a pass'

section "5. The template contract"

mutate agent-name-mismatch qa.sh \
  templates/agents/planner.md \
  'name: planner' 'name: planner-renamed' \
  'an agent frontmatter name no longer matches its filename'

mutate auditor-can-write qa.sh \
  templates/agents/code-reviewer.md \
  'tools: Read, Grep, Glob, Bash' \
  'tools: Read, Grep, Glob, Bash, Write, Edit' \
  'a read-only VERIFY auditor is granted Write'

mutate skill-model-invocable qa.sh \
  templates/skills/feature/SKILL.md \
  'disable-model-invocation: true' \
  'disable-model-invocation: false' \
  'a side-effecting skill can be invoked unprompted'

mutate rule-loads-everywhere qa.sh \
  templates/rules/testing.md \
  'paths:' 'globs:' \
  'a path-scoped rule loses its scope and loads in every session'

mutate readme-count-drift qa.sh \
  README.md \
  '| **Pro** | 7 | 7 | 5 |' \
  '| **Pro** | 9 | 7 | 5 |' \
  'the README advertises a tier size the manifest contradicts'

# Shipped: bash-gate was added because Edit|Write is not the only way to write a
# file, and the docs went on saying "four hooks" afterwards -- including §10 of
# DESIGN-RATIONALE, the section a reader is told to read BEFORE changing a
# tier's shape, which described the four-hook design with the hole still in it.
# A reader who counts four goes looking for four and finds four.
mutate hook-count-drift qa.sh \
  docs/DESIGN-RATIONALE.md \
  "Every tier shares §10's five hooks" \
  "Every tier shares §10's four hooks" \
  'the docs name a hook count the shipped hooks contradict'

# The count can stay honest while a hook sits inert: five files in
# templates/common/hooks, one of them registered by nobody. `verify.sh` audits
# an INSTALL; this is the same question asked of the templates, before anything
# is installed at all.
mutate hook-never-registered qa.sh \
  templates/tiers/pro/settings.json.tmpl \
  '.claude/hooks/bash-gate.sh' \
  '.claude/hooks/bash-gate-DISABLED.sh' \
  'a shipped hook is never registered by a tier'

# Shipped: the output filter's saving -- the largest single token lever here --
# was asserted in three documents and measured by nothing. verify.sh checked
# that `updatedInput` appeared in the hook's stdout, which proves the hook has
# an opinion and nothing about whether that opinion is worth anything. A filter
# that quietly stopped matching would keep emitting `updatedInput` forever and
# return the entire suite every time, and every check would stay green.
# An empty alternative makes grep -E match every line. This is the exact shape
# of a defect this repo already shipped once: a newline guard collapsed to `**`
# and matched everything, and eight refusal cases reported PASS while the guard
# rejected every valid value. Two bugs cancelling to green.
mutate filter-stops-filtering test/hooks.sh \
  templates/common/hooks/filter-output.sh \
  "-B2 -A8 -E '(FAIL" \
  "-B2 -A8 -E '(|FAIL" \
  'the output filter matches every line and returns the whole run'

# The 150-line cap is the second limiter and binds only when grep itself
# matches a lot -- a suite with 200 failures, where the filter is working
# perfectly and the result is still far too much to send back. Raising it is
# invisible to any test that only checks a mostly-passing run, which is why the
# first version of this mutation ESCAPED.
mutate filter-cap-removed test/hooks.sh \
  templates/common/hooks/filter-output.sh \
  "awk 'NR<=150'" \
  "awk 'NR<=100000'" \
  'the output filter loses its cap on a run that is nearly all failures'

# The same defect one layer down: the filter still filters, but stops recording
# what it saved, so the number goes back to being a claim.
mutate filter-stops-recording test/hooks.sh \
  templates/common/hooks/filter-output.sh \
  '>> .claude/state/filter-log.tsv' \
  '>> /dev/null' \
  'the output filter stops recording what it saved'

# A session recorder that cannot tell a /clear from a compact still produces
# rows, still looks healthy in `savings.sh`, and answers the only question it
# was built for -- was the window DROPPED or was it RE-SENT -- with nothing.
mutate session-log-conflates-source test/hooks.sh \
  templates/common/hooks/session-log.sh \
  'SOURCE=$(field source);  [ -n "$SOURCE" ] || SOURCE="unknown"' \
  'SOURCE="session"' \
  'the session recorder stops telling a /clear from a compact'

# A --record that appends rather than replaces doubles the project total every
# time a monthly report is regenerated -- and it doubles it inside a COMMITTED
# file, where nobody re-derives it. Same failure as the coverage parser that
# reported the last package's number: not a crash, a plausible wrong figure.
mutate savings-record-appends test/hooks.sh \
  templates/common/scripts/savings.sh \
  '{ [ -f "$F" ] && grep -v "^$RECORD	" "$F" 2>/dev/null; printf' \
  '{ [ -f "$F" ] && cat "$F" 2>/dev/null; printf' \
  'the shared rollup appends instead of replacing, doubling the project total'

# The scope caveat has to be COUNTED, not asserted. A hardcoded "this machine
# only" is correct on the day it is written and wrong the moment a teammate
# commits a file -- at which point the report understates the project and says
# so confidently.
mutate savings-scope-hardcoded test/hooks.sh \
  templates/common/scripts/savings.sh \
  'if [ "$nshared" -le 1 ]; then' \
  'if true; then' \
  'the scope line claims machine-only even when teammates have recorded'

section "6. Documentation drift that stops the pipeline"

# Shipped: PR #2 made the gate demand problem/red without updating the six
# phase skills, which all still said "set phase to create". main briefly
# deadlocked at CREATE -- the one phase whose purpose is unblocking source --
# and every hook test passed throughout, because they drove gate.sh directly.
mutate skill-names-dead-command test/hooks.sh \
  templates/skills/phase-create/SKILL.md \
  '.claude/scripts/gate.sh advance verify' \
  '.claude/scripts/gate.sh promote verify' \
  'a phase skill names a gate.sh subcommand that does not exist'

mutate skill-cannot-run-gate test/hooks.sh \
  templates/skills/phase-create/SKILL.md \
  'Bash(bash .claude/scripts/gate.sh *)' \
  'Bash(bash .claude/scripts/nothing.sh *)' \
  'a phase skill is told to run gate.sh but not permitted to'

section "7. Profile values that corrupt a hook"

# Shipped in the config format itself: a markdown table cell cannot contain `|`.
# The parser splits on it, so `vitest run | tee out.txt` configured the hook
# with `vitest run` -- silently. This pipeline's signature failure mode, sitting
# inside its own configuration file.
# check_row_shape is the guard that actually enforces this; the value-level
# `*'|'*` case below it is a second line of defence, and mutating THAT was an
# equivalent mutant -- the row check refused the row first, so the suite stayed
# green because nothing had in fact changed. A mutation must disable the
# load-bearing guard or it measures nothing.
mutate profile-accepts-pipe test/profile-validation.sh \
  configure.sh \
  '      if (lbl == want && NF > 5) {' \
  '      if (lbl == want && NF > 99) {' \
  'a pipe in a profile value is accepted and silently truncates it'

mutate profile-accepts-cr test/profile-validation.sh \
  configure.sh \
  '    *"$_NL"*|*"$_CR"*)' \
  '    *"$_NL$_CR@never@"*)' \
  'a carriage return in a profile value reaches hook source intact'

# ============================================================= the pristine tree
PRISTINE="$W/pristine"
mkdir -p "$PRISTINE"
( cd "$SRC" && tar --exclude=.git --exclude=node_modules --exclude=__pycache__ -cf - . ) \
  | ( cd "$PRISTINE" && tar -xf - )

# ---------------------------------------------------------------- baseline
# If the unmutated tree is already red, every "caught" below is meaningless --
# the suite would have failed whatever we did to it. Same sanity case
# test/profile-validation.sh opens with, and for the same reason: an assertion
# suite that never checks its own baseline can report a perfect score while
# measuring nothing.
#
# Only the suites this run actually uses, so a filtered run stays quick.
head_ "0. Baseline — the unmutated tree must be GREEN in every suite used"
BASELINE_OK=1
USED=$(awk -F'\t' '$1!="SECTION"{print $3}' "$SPEC" | sort -u)
[ -n "$USED" ] || { printf '  no mutations matched the filter %s\n' "'$FILTER'"; exit 0; }
for s in $USED; do
  if ( cd "$PRISTINE" && QA_SKIP_SUITES=1 bash "$s" >/dev/null 2>&1 ); then
    printf '  \033[32mgreen \033[0m %s\n' "$s"
  else
    printf '  \033[31mRED   \033[0m %s — mutation results below would be meaningless\n' "$s"
    BASELINE_OK=0
  fi
done
if [ "$BASELINE_OK" != 1 ]; then
  printf '\n\033[31mBaseline is not green. Fix the suite before reading mutation results.\033[0m\n'
  exit 1
fi

# ================================================================== the pool
# One mutation per worker, each in its own copy. Windows spawns processes an
# order of magnitude more slowly than Linux, and these suites are almost all
# process spawn, so serial execution here ran past forty minutes.
run_one() {  # run_one <n> <id> <suite> <file>
  local n="$1" id="$2" suite="$3" file="$4"
  local T="$W/t-$n"
  mkdir -p "$T"
  ( cd "$PRISTINE" && tar -cf - . ) | ( cd "$T" && tar -xf - )

  MUT_OLD_FILE="$W/$n.old" MUT_NEW_FILE="$W/$n.new" \
  python3 - "$T/$file" <<'PY'
import io, os, sys
p = sys.argv[1]
if not os.path.exists(p):
    sys.exit(3)
# Read from files, never from argv or the environment as inline text: these
# patterns carry newlines, quotes and backslashes, and Git Bash rewrites
# arguments that merely look like absolute paths.
old = io.open(os.environ["MUT_OLD_FILE"], encoding="utf-8").read()[:-1]
new = io.open(os.environ["MUT_NEW_FILE"], encoding="utf-8").read()[:-1]
s = io.open(p, encoding="utf-8").read()
if s.count(old) != 1:
    sys.exit(3)
io.open(p, "w", encoding="utf-8", newline="").write(s.replace(old, new))
PY
  if [ "$?" != 0 ]; then
    printf 'BROKEN' > "$W/r-$n"
    return
  fi

  # QA_SKIP_SUITES: qa.sh's section 13 runs the behaviour suites itself, and
  # those are driven directly by their own mutations here. Letting qa.sh re-run
  # them once per mutated tree quadruples the cost for no extra signal.
  if ( cd "$T" && QA_SKIP_SUITES=1 bash "$suite" >/dev/null 2>&1 ); then
    printf 'ESCAPED' > "$W/r-$n"
  else
    printf 'caught' > "$W/r-$n"
  fi
  rm -rf "$T"
}

running=0
while IFS=$'\t' read -r n id suite file why; do
  [ "$n" = "SECTION" ] && continue
  run_one "$n" "$id" "$suite" "$file" &
  running=$((running + 1))
  if [ "$running" -ge "$JOBS" ]; then wait -n 2>/dev/null || wait; running=$((running - 1)); fi
done < "$SPEC"
wait

# ==================================================================== report
# Printed in declaration order, not completion order, so the output is stable
# across runs and diffable.
CAUGHT=0; ESCAPED=0; BROKEN=0
# The section header is held back until something under it actually prints, so
# a filtered run (`bash test/mutation.sh coverage`) shows the one section it
# matched instead of seven empty ones.
PENDING_SECTION=""
emit_section() {
  [ -n "$PENDING_SECTION" ] || return 0
  head_ "$PENDING_SECTION"
  PENDING_SECTION=""
}
while IFS=$'\t' read -r n id suite why; do
  if [ "$n" = "SECTION" ]; then PENDING_SECTION="$id"; continue; fi
  emit_section
  case "$(cat "$W/r-$n" 2>/dev/null)" in
    caught)
      printf '  \033[32mcaught \033[0m %-28s %s\n' "$id" "$why"; CAUGHT=$((CAUGHT+1)) ;;
    ESCAPED)
      printf '  \033[31mESCAPED\033[0m %-28s %s stayed GREEN — %s\n' "$id" "$suite" "$why"
      ESCAPED=$((ESCAPED+1)) ;;
    *)
      printf '  \033[33mBROKEN \033[0m %-28s anchor not found exactly once in %s\n' "$id" "$suite"
      BROKEN=$((BROKEN+1)) ;;
  esac
done < <(awk -F'\t' 'BEGIN{OFS="\t"} $1=="SECTION"{print $1,$2,"",""; next} {print $1,$2,$3,$5}' "$SPEC")

printf '\n\033[1m%d caught, %d escaped, %d broken\033[0m\n' "$CAUGHT" "$ESCAPED" "$BROKEN"

if [ "$BROKEN" -gt 0 ]; then
  printf '\n\033[33mA BROKEN mutation is not a pass.\033[0m Its anchor text no longer exists, so it\n'
  printf 'ran against a clean tree. Re-point it at the current source, or delete it if the\n'
  printf 'defect it describes is now impossible by construction.\n'
fi
if [ "$ESCAPED" -gt 0 ]; then
  printf '\n\033[31mAn ESCAPED mutation is a defect this repository has actually shipped,\n'
  printf 'reintroduced, with its suite still green.\033[0m\n'
fi
if [ "$ESCAPED" -gt 0 ] || [ "$BROKEN" -gt 0 ]; then exit 1; fi
printf 'Every shipped defect, reintroduced, is caught by a suite.\n'
exit 0
