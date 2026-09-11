#!/usr/bin/env bash
#
# claude-studio hook behaviour test
#
# verify.sh checks an INSTALL. qa.sh checks the TEMPLATES' shape. This checks
# what the hooks actually DO -- against the bypass shapes that have defeated
# them, rather than against the happy path that has always passed.
#
# It exists because the happy path passing is exactly the symptom. Measured on
# 2026-09-12, with the gate closed, against the previous gate-check.sh:
#
#   exit 2  relative path        src/services/dues.ts     <- the only shape tested
#   exit 0  ABSOLUTE path        /home/u/p/src/...        <- what the harness SENDS
#   exit 0  absolute Windows     C:\Users\...
#   exit 0  leading ./           ./src/services/dues.ts
#   exit 0  docs/../ traversal   an allow rule as a prefix
#   exit 0  'test' in filename   src/services/LatestReport.ts
#   exit 0  'spec' in filename   src/http/InspectorController.ts
#
# Six of seven walked through, and verify.sh reported PASS on all of it,
# because it fed the one spelling that worked. A guard's test suite has to
# contain the bypasses or it certifies only that the guard runs.
#
#   bash test/hooks.sh
#
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
pass() { printf '  \033[32mok  \033[0m %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n     expected %s, got %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t studio)"
cleanup() { cd /; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM HUP

# ---------------------------------------------------------------- a fixture
# A synthetic project with the placeholders substituted the way configure.sh
# would substitute them for a src/-rooted TypeScript project.
mkdir -p "$WORK/.claude/hooks" "$WORK/.claude/state" "$WORK/.claude/scripts" \
         "$WORK/src/services" "$WORK/src/components" "$WORK/src/http" \
         "$WORK/docs/specs" "$WORK/tests"

for h in _guard.sh gate-check.sh bash-gate.sh filter-output.sh doc-check.sh post-edit.sh; do
  [ -f "$SRC/templates/common/hooks/$h" ] || continue
  sed -e 's|{{SOURCE_ROOTS_REGEX}}|^(src)/|g' \
      -e 's|{{TEST_ROOT}}|tests|g' \
      -e 's|{{SHARED_SURFACE_REGEX}}|src/(components\|services)/|g' \
      -e 's|{{TEST_COMMAND}}|npm test|g' \
      -e 's|{{BUILD_COMMAND}}|npm run build|g' \
      -e 's|{{TYPECHECK_COMMAND}}|tsc --noEmit|g' \
      -e 's|{{DEPENDENCY_AUDIT_COMMAND}}|npm audit|g' \
      -e 's|{{FORMAT_COMMAND}}|prettier -w|g' \
      -e 's|{{FORMAT_GLOB}}|*.ts|g' \
      -e 's|{{TYPECHECK_GLOB}}|*.ts|g' \
      "$SRC/templates/common/hooks/$h" > "$WORK/.claude/hooks/$h"
done
cp "$SRC/templates/common/scripts/gate.sh" "$WORK/.claude/scripts/" 2>/dev/null || true
chmod +x "$WORK/.claude/hooks/"*.sh "$WORK/.claude/scripts/"*.sh 2>/dev/null || true

: > "$WORK/src/services/dues.ts"
: > "$WORK/package.json"
cd "$WORK" || exit 1

GATE=".claude/state/gate.json"
set_gate() { printf '%s\n' "$1" > "$GATE"; }

# JSON-escape a path the way the harness transports one, so a Windows spelling
# arrives as the hook will really see it.
esc_json() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# g <label> <path> <want-exit>
g() {
  local label="$1" path="$2" want="$3" got
  printf '{"tool_input":{"file_path":"%s"}}' "$(esc_json "$path")" \
    | bash .claude/hooks/gate-check.sh >/dev/null 2>&1
  got=$?
  [ "$got" = "$want" ] && pass "$label" || fail "$label" "exit $want" "exit $got"
}

# b <label> <command> <want-exit>
b() {
  local label="$1" cmd="$2" want="$3" got
  printf '{"tool_input":{"command":"%s"}}' "$(esc_json "$cmd")" \
    | bash .claude/hooks/bash-gate.sh >/dev/null 2>&1
  got=$?
  [ "$got" = "$want" ] && pass "$label" || fail "$label" "exit $want" "exit $got"
}

ABS="$WORK/src/services/dues.ts"
WIN=$(printf '%s' "$ABS" | tr '/' '\\')

# ------------------------------------------------------- 1. the bypass matrix
head_ "1. gate-check · path spellings that must all reach the same verdict"
set_gate '{"phase":"idle"}'
g "relative"                    "src/services/dues.ts"            2
g "absolute (what is sent)"     "$ABS"                            2
g "absolute Windows"            "$WIN"                            2
g "leading ./"                  "./src/services/dues.ts"          2
g "traversal out of docs/"      "docs/../src/services/dues.ts"    2
g "traversal out of tests/"     "tests/../src/services/dues.ts"   2
g "'test' inside a filename"    "src/services/LatestReport.ts"    2
g "'spec' inside a filename"    "src/http/InspectorController.ts" 2
g "'Test' inside a dirname"     "src/TestHarness/real.ts"         2
g "uppercase root"              "SRC/services/dues.ts"            2
g "dependency manifest"         "package.json"                    2

head_ "2. gate-check · what must stay writable with the gate closed"
g "a spec doc"                  "docs/specs/x/plan.md"            0
g "a test file"                 "tests/dues.test.ts"              0
g "claude config"               ".claude/agents/x.md"             0
g "top-level markdown"          "README.md"                       0
g "outside the source roots"    "vite.config.js"                  0
g "vendored code shadowing src" "node_modules/pkg/src/x.ts"       0
g "a vendored manifest"         "node_modules/pkg/package.json"   0

# Go, Rust and most JS layouts keep tests BESIDE the code they cover. A
# location-only allow rule means the TEST phase cannot write the failing test
# that the CREATE phase exists to turn green -- the pipeline would deadlock on
# its own contract. Matching the FILENAME is what keeps that precise: these are
# tests; LatestReport.ts and InspectorController.ts, asserted blocked above,
# are not.
g "a test beside its source"    "src/services/dues.test.ts"       0
g "a Go test beside its source" "src/services/pay_test.go"        0
g "a spec beside its source"    "src/components/Btn.spec.tsx"     0
g "a python test_ prefix"       "src/services/test_dues.py"       0

head_ "2b. gate-check · an UNCONFIGURED install still blocks, but stays repairable"
# Both directions matter. An unsubstituted source-root regex matches nothing,
# so judging source before the config check would allow every write while
# reporting success. But refusing the repair path too means a half-finished
# install can never be fixed from inside a session.
UNCONF="$WORK/.claude/hooks/unconf-gate.sh"
cp "$SRC/templates/common/hooks/gate-check.sh" "$UNCONF"
uc() {
  local label="$1" path="$2" want="$3" got
  printf '{"tool_input":{"file_path":"%s"}}' "$(esc_json "$path")" \
    | bash "$UNCONF" >/dev/null 2>&1
  got=$?
  [ "$got" = "$want" ] && pass "$label" || fail "$label" "exit $want" "exit $got"
}
uc "unconfigured: blocks source"        "src/services/dues.ts"     2
uc "unconfigured: allows the profile"   "docs/setup/PROFILE.md"    0
uc "unconfigured: allows .claude"       ".claude/settings.json"    0
rm -f "$UNCONF"

# ------------------------------------------------- 3. the gate carries content
head_ "3. gate-check · a plan that says nothing does not open the gate"
set_gate '{"phase":"create"}'
g "create, no problem/red"      "src/services/dues.ts"            2
set_gate '{"phase":"create","problem":"only a problem was stated"}'
g "create, no red"              "src/services/dues.ts"            2
set_gate '{"phase":"create","problem":"National finance summed every chapter twice","red":"DuesTest::national_excludes_chapter fails: expected 0 got 41250"}'
g "create, both stated"         "src/services/dues.ts"            0

head_ "4. gate-check · new shared surface needs a reuse verdict"
g "NEW service, no reuse"       "src/services/brand-new.ts"       2
g "NEW component, no reuse"     "src/components/Toolbar.ts"       2
g "EXISTING file is untouched"  "src/services/dues.ts"            0
g "new file, unshared dir"      "src/http/plain.ts"               0
set_gate '{"phase":"create","problem":"National finance summed every chapter twice","red":"n/a: pure token rename, no behaviour","reuse":"new: nothing here models the two-tier scope"}'
g "NEW service, reuse stated"   "src/services/brand-new.ts"       0

head_ "5. gate-check · a dependency is a stated decision"
g "manifest, no deps note"      "package.json"                    2
set_gate '{"phase":"create","problem":"National finance summed every chapter twice","red":"n/a: dependency bump only","deps":"no date helper here; hand-rolled the same parser in 3 places"}'
g "manifest, deps stated"       "package.json"                    0

# --------------------------------------------------------- 6. the other door
head_ "6. bash-gate · the shell door the Edit gate never covered"
set_gate '{"phase":"idle"}'
b "sed -i"                      "sed -i 's/x/y/' src/services/dues.ts"          2
b "redirect >"                  "echo x > src/services/dues.ts"                 2
b "append >>"                   "echo x >> src/services/dues.ts"                2
b "clobber >|"                  "echo x >| src/services/dues.ts"                2
b "heredoc into a new file"     "cat > src/services/brand.ts <<EOF"             2
b "cp onto source"              "cp /tmp/x.ts src/services/dues.ts"             2
b "mv -t into source"           "mv -t src/services /tmp/x.ts"                  2
b "rm source"                   "rm src/services/dues.ts"                       2
b "tee source"                  "echo x | tee src/services/dues.ts"             2
b "perl -i"                     "perl -pi -e 's/a/b/' src/services/dues.ts"     2
b "git checkout --"             "git checkout -- src/services/dues.ts"          2
b "git mv"                      "git mv src/services/dues.ts src/services/d.ts" 2
b "dd of="                      "dd if=/tmp/x of=src/services/dues.ts"          2
b "cd then redirect"            "cd src/services && echo x > dues.ts"           2
b "python open(...,'w')"        "python -c \"open('src/services/dues.ts','w')\"" 2
b "python shutil.copy"          "python -c \"import shutil; shutil.copy('/tmp/x','src/services/dues.ts')\"" 2
b "npm i (rewrites manifest)"   "npm i left-pad"                                2
b "composer require"            "composer require foo/bar"                      2
b "unresolvable \$VAR redirect" "T=src/services/dues.ts; echo x > \$T"          2
b "xargs carrying cp"           "echo src/services/dues.ts | xargs -I{} cp /tmp/x {}" 2

head_ "7. bash-gate · everyday commands must NOT be blocked"
b "reading source"              "cat src/services/dues.ts"                      0
b "grep across source"          "grep -rn foo src/"                             0
b "xargs carrying a read"       "grep -rl foo src | xargs wc -l"                0
b "writing to a doc"            "echo x > docs/specs/x/plan.md"                 0
b "writing to a test"           "echo x > tests/dues.test.ts"                   0
b "a lockfile restore"          "npm ci"                                        0
b "bare install, no operand"    "npm install"                                   0
b "audit fix"                   "npm audit fix"                                 0
b "running the gate script"     "bash .claude/scripts/gate.sh show"             0
b "stderr redirect, not a file" "npm test 2>&1"                                 0
b "the pipeline's own selftest" "bash test/hooks.sh"                            0

head_ "8. bash-gate · the allowlist that used to disarm it"
# An exemption matched by substring against a caller-controlled string is not
# an exemption. Both of these disabled the entire shell gate in one token.
b "trailing comment exemption"  "sed -i 's/x/y/' src/services/dues.ts # .claude/hooks/" 2
b "echoed exemption path"       "echo .claude/scripts/gate.sh; sed -i 's/x/y/' src/services/dues.ts" 2

head_ "9. bash-gate · opens with the rest of the gate"
set_gate '{"phase":"create","problem":"National finance summed every chapter twice","red":"DuesTest::national_excludes_chapter fails: expected 0 got 41250"}'
b "sed -i on existing source"   "sed -i 's/x/y/' src/services/dues.ts"          0
b "heredoc into a NEW surface"  "cat > src/services/brand.ts <<EOF"             2

# ------------------------------------------------------- 10. the output filter
head_ "10. filter-output · a failing command must still report failure"
set_gate '{"phase":"idle"}'
REWRITE=$(printf '{"tool_input":{"command":"npm test"}}' | bash .claude/hooks/filter-output.sh 2>/dev/null)
case "$REWRITE" in
  *updatedInput*) pass "rewrites the test command" ;;
  *) fail "rewrites the test command" "updatedInput" "$REWRITE" ;;
esac
# Extract the rewritten command and run it against a stub that FAILS.
CMD_OUT=$(printf '%s' "$REWRITE" | sed 's/.*"command":"//; s/"}}}$//' | sed 's/\\"/"/g; s/\\\\/\\/g')
cat > "$WORK/npm" <<'STUB'
#!/usr/bin/env bash
echo "FAIL  src/services/dues.test.ts"
echo "Tests: 1 failed, 2 passed"
exit 1
STUB
chmod +x "$WORK/npm"
RC=$(PATH="$WORK:$PATH" bash -c "$CMD_OUT" >/dev/null 2>&1; echo $?)
[ "$RC" = "1" ] && pass "preserves a non-zero exit status" \
                || fail "preserves a non-zero exit status" "exit 1" "exit $RC"

cat > "$WORK/npm" <<'STUB'
#!/usr/bin/env bash
echo "Tests: 3 passed"
exit 0
STUB
chmod +x "$WORK/npm"
OUT=$(PATH="$WORK:$PATH" bash -c "$CMD_OUT" 2>&1)
RC=$?
[ "$RC" = "0" ] && pass "preserves a zero exit status" \
                || fail "preserves a zero exit status" "exit 0" "exit $RC"
# A pass has to leave evidence behind: a gate that closes on an artifact needs
# an artifact, and filtering to failure patterns alone returns nothing at all.
[ -n "$OUT" ] && pass "a passing run still returns its verdict line" \
              || fail "a passing run still returns its verdict line" "some output" "(empty)"

printf '{"tool_input":{"command":"ls -la"}}' | bash .claude/hooks/filter-output.sh 2>/dev/null \
  | grep -q '^{}$' && pass "ignores unrelated commands" || fail "ignores unrelated commands" "{}" "other"
printf '{"tool_input":{"command":"npm test | tee out.txt"}}' | bash .claude/hooks/filter-output.sh 2>/dev/null \
  | grep -q '^{}$' && pass "leaves an already-piped command alone" || fail "leaves an already-piped command alone" "{}" "other"

# ------------------------------------------------------------ 11. the recorder
head_ "11. gate decisions are recorded"
if [ -s .claude/state/gate-log.tsv ]; then
  pass "gate-log.tsv has entries ($(wc -l < .claude/state/gate-log.tsv | tr -d ' ') decisions)"
  grep -q 'BLOCK' .claude/state/gate-log.tsv && pass "blocks are recorded" || fail "blocks are recorded" "a BLOCK row" "none"
  grep -q 'ALLOW' .claude/state/gate-log.tsv && pass "allows are recorded" || fail "allows are recorded" "an ALLOW row" "none"
else
  fail "gate-log.tsv has entries" "a non-empty log" "empty or missing"
fi

# ------------------------------------------------------------ 12. gate.sh CLI
head_ "12. gate.sh refuses an answer that is not an answer"
if [ -f .claude/scripts/gate.sh ]; then
  # One field poisoned at a time, the other left VALID. With both short, this
  # exits 1 whichever guard fires, so neutering either one leaves the suite
  # green -- which is exactly what qa.sh --mutate caught.
  GOOD_P="National finance summed every chapter twice"
  GOOD_R="DuesServiceTest::test_totals fails on the duplicate join"

  bash .claude/scripts/gate.sh create --problem "x" --red "$GOOD_R" >/dev/null 2>&1 \
    && fail "refuses a one-token problem" "exit 1" "exit 0" || pass "refuses a one-token problem"
  bash .claude/scripts/gate.sh create --problem "$GOOD_P" --red "y" >/dev/null 2>&1 \
    && fail "refuses a one-token red" "exit 1" "exit 0" || pass "refuses a one-token red"

  # Omitting a flag entirely is a different code path from supplying a short
  # value, and nothing exercised it. The gate once stored {"phase":"create"}
  # and nothing else, so "the flag was never passed" is the case that shipped.
  #
  # Asserted on the MESSAGE, not just the exit status. An omitted flag is
  # already refused by the dense-length guard further down -- zero characters
  # is under any floor -- so a status-only assertion here passes whether the
  # MISSING check exists or not. qa.sh --mutate proved exactly that: deleting
  # the check left this suite green.
  #
  # What the MISSING check actually buys is the diagnosis. "--problem missing"
  # tells you to pass a flag; "--problem is 0 characters of content" describes
  # a value you never wrote. In a gate whose block message is the most-read
  # text in the pipeline that difference IS the feature, so it is what gets
  # tested.
  m_missing() {  # m_missing <label> <args...>
    local label="$1"; shift
    local out
    out=$(bash .claude/scripts/gate.sh create "$@" 2>&1)
    if bash .claude/scripts/gate.sh create "$@" >/dev/null 2>&1; then
      fail "$label" "exit 1" "exit 0"
    elif printf '%s' "$out" | grep -qi 'missing'; then
      pass "$label"
    else
      fail "$label" "a message naming the missing flag" "$(printf '%s' "$out" | head -1)"
    fi
  }
  m_missing "refuses a missing --problem, and names it" --red "$GOOD_R"
  m_missing "refuses a missing --red, and names it"     --problem "$GOOD_P"
  m_missing "refuses both flags missing, and names them"

  # Whitespace is not an answer. `--problem "            "` is twelve
  # characters and zero content, which is why the guard measures DENSE length.
  bash .claude/scripts/gate.sh create --problem "               " --red "$GOOD_R" >/dev/null 2>&1 \
    && fail "refuses a whitespace-only problem" "exit 1" "exit 0" || pass "refuses a whitespace-only problem"
  bash .claude/scripts/gate.sh create --problem "National finance summed every chapter twice" --red "n/a" >/dev/null 2>&1 \
    && fail "refuses a bare n/a red" "exit 1" "exit 0" || pass "refuses a bare n/a red"
  bash .claude/scripts/gate.sh create --problem "National finance summed every chapter twice" --red "n/a: a design token has no behaviour to pin" >/dev/null 2>&1 \
    && pass "accepts n/a with a reason" || fail "accepts n/a with a reason" "exit 0" "exit 1"
  bash .claude/scripts/gate.sh idle >/dev/null 2>&1 \
    && pass "resets to idle" || fail "resets to idle" "exit 0" "nonzero"
else
  fail "gate.sh is installed" "templates/common/scripts/gate.sh" "missing"
fi

# ------------------------------------------- 13. the documented workflow works
head_ "13. The documented phase sequence actually opens and closes the gate"
# This is the test that was missing, and the gap it covers was real: the phase
# skills said "update gate.json: set phase to create", which written literally
# produces {"phase":"create"} and ERASES the problem/red notes. Every hook test
# passed, because they all drove gate.sh directly -- and the pipeline would have
# deadlocked at the CREATE phase, the exact phase it exists to unblock.
#
# A guard suite that only exercises the guard is not enough. The workflow that
# OPERATES the guard has to be walked too.
SRCF="src/services/dues.ts"
step() {  # step <label> <gate.sh args...> ; then assert source reachability
  local label="$1"; shift
  local want="$1"; shift
  bash .claude/scripts/gate.sh "$@" >/dev/null 2>&1
  local rc=$?
  if [ "$rc" -ne 0 ]; then fail "$label (gate.sh refused)" "exit 0" "exit $rc"; return; fi
  printf '{"tool_input":{"file_path":"%s"}}' "$SRCF" | bash .claude/hooks/gate-check.sh >/dev/null 2>&1
  local got=$?
  [ "$got" = "$want" ] && pass "$label" || fail "$label" "source exit $want" "exit $got"
}

step "idle: source blocked"              2 idle
step "plan: source blocked"              2 plan
step "test: source blocked"              2 test
step "create: source OPEN"               0 create \
     --problem "National finance summed every chapter's dues into the total" \
     --red     "DuesTest::national_excludes_chapter fails: expected 0, got 41250"
step "advance verify: source still OPEN" 0 advance verify
step "advance document: source blocked"  2 advance document
step "idle: re-armed for the next slice" 2 idle

# The regression that motivated `advance`: a phase change must not erase the
# slice's answers. Writing gate.json by hand is what did.
bash .claude/scripts/gate.sh create \
  --problem "National finance summed every chapter's dues into the total" \
  --red "DuesTest::national_excludes_chapter fails: expected 0, got 41250" >/dev/null 2>&1
bash .claude/scripts/gate.sh advance verify >/dev/null 2>&1
if grep -q '"problem"' .claude/state/gate.json && grep -q '"red"' .claude/state/gate.json; then
  pass "advance carries problem and red forward"
else
  fail "advance carries problem and red forward" "both notes kept" "notes erased"
fi

# And it must not be a way AROUND stating them.
printf '{"phase":"plan"}\n' > "$GATE"
bash .claude/scripts/gate.sh advance create >/dev/null 2>&1 \
  && fail "advance into create still demands the notes" "exit 1" "exit 0" \
  || pass "advance into create still demands the notes"

head_ "14. The skills only name gate.sh commands that exist"
# Documentation drift in the other direction: a skill telling the agent to run
# a subcommand that was renamed is a pipeline that stops at that phase.
DRIFT=0
# Anchored on the SLASH before the name. Without it, `gate\.sh` also matches the
# tail of `coverage-gate.sh`, and the very first sibling script added to
# .claude/scripts/ made this check report a phantom subcommand ('coverage') that
# no skill had ever named. A drift check that invents drift gets switched off
# as fast as one that misses it.
for c in $(grep -rhoE '/gate\.sh (advance )?[a-z]+' "$SRC"/templates/skills "$SRC"/templates/agents "$SRC"/templates/tiers 2>/dev/null \
           | sed 's|^/gate\.sh ||; s/^advance //' | sort -u); do
  case "$c" in
    idle|plan|test|create|verify|document|show|log|advance) ;;
    *) fail "a skill names a gate.sh command that does not exist" "a known subcommand" "'$c'"; DRIFT=1 ;;
  esac
done
[ "$DRIFT" = 0 ] && pass "every gate.sh command named in the skills exists"

# The phase skills must be ALLOWED to run it, or the instruction is decoration.
MISSING_TOOL=""
for f in "$SRC"/templates/skills/phase-*/SKILL.md "$SRC"/templates/skills/feature/SKILL.md; do
  [ -f "$f" ] || continue
  grep -q 'allowed-tools:.*gate\.sh' "$f" || MISSING_TOOL="$MISSING_TOOL $(basename "$(dirname "$f")")"
done
[ -z "$MISSING_TOOL" ] && pass "every phase skill may run gate.sh" \
  || fail "every phase skill may run gate.sh" "allowed-tools carries gate.sh" "missing in:$MISSING_TOOL"

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && { printf 'A guard that fails its own bypass suite is not a guard.\n'; exit 1; }
printf 'Every bypass shape reaches the same verdict as the plain one.\n'
exit 0
