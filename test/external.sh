#!/usr/bin/env bash
#
# The EXTERNAL layout: install.sh --home DIR, for a repository that may not
# hold Claude or pipeline files.
#
# Two field reports shaped it. Users who could not store these files in the
# repository either could not install at all, or moved the files by hand --
# and then the agent followed the pipeline only while somebody kept pointing
# it at the other location, and drifted again. So this checks three things:
#
#   1. the repository is never written, by install, configure, verify or use
#   2. the gate guards the repository exactly as it does in the ordinary layout
#   3. every message and every instruction names paths that exist in THIS
#      layout -- a pointer to .claude/scripts/ in a repo that has none is how
#      an agent gets lost
#
#   bash test/external.sh
#
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
ok()  { printf '  \033[32mok  \033[0m %s\n' "$1"; PASS=$((PASS+1)); }
no()  { printf '  \033[31mFAIL\033[0m %s\n       %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
hd()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

W="$(mktemp -d)"; W="$(cd "$W" && pwd -P)"
trap 'cd /; rm -rf "$W"' EXIT INT TERM HUP
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m -l "$1"; else printf '%s' "$1"; fi; }

REPO="$W/repo"
HOME_D="$W/pipeline home"          # a space, on purpose: Windows user profiles have them
mkdir -p "$REPO/src/services" "$REPO/tests"
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t
  printf '{"name":"r","scripts":{"test":"node -e 0"}}\n' > package.json
  printf 'export const a = 1;\n' > src/services/dues.ts
  git add -A && git commit -qm init ) >/dev/null 2>&1

repo_is_clean() {  # repo_is_clean <label>
  local extra
  extra=$(cd "$REPO" && git status --porcelain --ignored 2>/dev/null)
  [ -z "$extra" ] && ok "$1" || no "$1" "$(printf '%s' "$extra" | head -3 | tr '\n' ' ')"
}

# ----------------------------------------------------------------- install
hd "1. Install writes nothing to the repository"
bash "$SRC/install.sh" --plan pro --target "$REPO" --home "$HOME_D" >"$W/install.log" 2>&1 \
  && ok "install.sh --home succeeds" || no "install.sh --home succeeds" "$(tail -3 "$W/install.log")"
repo_is_clean "repository untouched after install (not even .gitignore)"
[ -f "$HOME_D/.claude/project-dir" ] && [ "$(cat "$HOME_D/.claude/project-dir")" = "$(native "$REPO")" ] \
  && ok "the home records the project it guards" \
  || no "the home records the project it guards" "$(cat "$HOME_D/.claude/project-dir" 2>/dev/null)"
for l in iptcvd-claude iptcvd-claude.ps1 iptcvd-claude.cmd; do
  [ -f "$HOME_D/$l" ] && ok "launcher written: $l" || no "launcher written: $l"
done
grep -q -- '--add-dir' "$HOME_D/iptcvd-claude" && grep -q -- '--settings' "$HOME_D/iptcvd-claude" \
  && grep -q 'CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1' "$HOME_D/iptcvd-claude" \
  && ok "the launcher loads settings, skills/agents and CLAUDE.md from the home" \
  || no "the launcher loads settings, skills/agents and CLAUDE.md from the home"

hd "2. Nothing the pipeline tells the model points at a path this layout lacks"
LEFT=$(grep -rlE --include='*.md' '(^|[^A-Za-z0-9_./~-])(\.claude/(scripts|state|hooks)/|docs/(specs|reports|adr|handoff|setup)/)' \
         "$HOME_D/.claude/agents" "$HOME_D/.claude/skills" "$HOME_D/.claude/rules" "$HOME_D/CLAUDE.md" 2>/dev/null \
       | grep -v '\.py$' || true)
[ -z "$LEFT" ] && ok "skills, agents, rules and CLAUDE.md name the home's paths" \
  || no "skills, agents, rules and CLAUDE.md name the home's paths" "$(printf '%s' "$LEFT" | head -3 | tr '\n' ' ')"
HN="$(native "$HOME_D")"
grep -qF "\"$HN/.claude/scripts/gate.sh\"" "$HOME_D/.claude/skills/feature/SKILL.md" \
  && ok "a skill names gate.sh by its quoted home path" \
  || no "a skill names gate.sh by its quoted home path"
if command -v jq >/dev/null 2>&1; then
  n_rel=$(jq '[.hooks[][] | .hooks[] | .command | select(startswith(".claude/"))] | length' "$HOME_D/.claude/settings.json")
  [ "$n_rel" = 0 ] && ok "every hook command is absolute" || no "every hook command is absolute" "$n_rel relative"
  jq -e '.permissions.deny | index("Write(/hooks/**)")' "$HOME_D/.claude/settings.json" >/dev/null \
    && ok "deny rules anchor at the home's .claude/ (a --settings file's own directory)" \
    || no "deny rules anchor at the home's .claude/"
fi

# --------------------------------------------------------------- configure
hd "3. configure and verify check the PROJECT, still write only the home"
P="$HOME_D/docs/setup/PROFILE.md"
sed -i 's/NEEDS_REVIEW/true/g' "$P"
sed -i 's/^| Source roots | [^|]*|/| Source roots | src |/; s/^| Test root | [^|]*|/| Test root | tests |/' "$P"
bash "$SRC/configure.sh" --home "$HOME_D" >"$W/cfg.log" 2>&1 \
  && ok "configure.sh --home accepts roots that exist in the project" \
  || no "configure.sh --home accepts roots that exist in the project" "$(grep -m1 error "$W/cfg.log")"
bash "$SRC/verify.sh" --home "$HOME_D" >"$W/verify.log" 2>&1 \
  && ok "verify.sh --home passes ($(grep -oE '[0-9]+ passed' "$W/verify.log"))" \
  || no "verify.sh --home passes" "$(grep FAIL "$W/verify.log" | head -2 | tr '\n' ' ')"
repo_is_clean "repository untouched after configure and verify"

# ------------------------------------------------------------------- gates
hd "4. The gate guards the project from the home"
# By the NATIVE path, the way the absolute hook commands in settings.json name
# them: a hook works out its home from its own path.
H="$HN/.claude/hooks"; GATE="$HOME_D/.claude/state/gate.json"
RN="$(native "$REPO")"
gc() {  # gc <label> <path> <want>
  local got
  got=$(cd "$REPO" && printf '{"tool_input":{"file_path":"%s"}}' "$2" | bash "$H/gate-check.sh" >/dev/null 2>&1; echo $?)
  [ "$got" = "$3" ] && ok "$1" || no "$1" "expected exit $3, got $got"
}
bg() {  # bg <label> <command> <want>
  local got
  got=$(cd "$REPO" && printf '{"tool_input":{"command":"%s"}}' "$(printf '%s' "$2" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
        | bash "$H/bash-gate.sh" >/dev/null 2>&1; echo $?)
  [ "$got" = "$3" ] && ok "$1" || no "$1" "expected exit $3, got $got"
}
bash "$HOME_D/.claude/scripts/gate.sh" idle >/dev/null 2>&1
gc "project source, absolute (what the harness sends), blocks"  "$RN/src/services/dues.ts" 2
gc "project source, relative, blocks"                            "src/services/dues.ts"     2
gc "project test file stays writable"                            "$RN/tests/x.test.ts"      0
bg "a shell redirect into project source blocks"                 "echo x > src/services/dues.ts" 2
gc "the home's gate.json is an enforcement file"                 "$HN/.claude/state/gate.json" 2
gc "the home's hooks are enforcement files"                      "$HN/.claude/hooks/gate-check.sh" 2
gc "the home's project-dir is an enforcement file"               "$HN/.claude/project-dir" 2
gc "the launcher is an enforcement file"                         "$HN/iptcvd-claude" 2
gc "the home's settings.json is an enforcement file"             "$HN/.claude/settings.json" 2
bg "a shell redirect into the home's gate.json blocks"           "echo {} > \"$HN/.claude/state/gate.json\"" 2
gc "a spec in the home stays writable (it is how the plan gets written)" "$HN/docs/specs/x/plan.md" 0
gc "agent memory in the home stays writable"                     "$HN/.claude/agent-memory/x.md" 0

OUT=$(cd "$REPO" && printf '{"tool_input":{"file_path":"src/services/dues.ts"}}' | bash "$H/gate-check.sh" 2>&1 >/dev/null)
case "$OUT" in
  *"bash \"$HN/.claude/scripts/gate.sh\" create"*) ok "the block message names gate.sh by its home path" ;;
  *) no "the block message names gate.sh by its home path" "$(printf '%s' "$OUT" | grep gate.sh | head -1)" ;;
esac

hd "5. gate.sh keeps state in the home and runs the test in the project"
# Run from an unrelated directory: gate.sh must enter the PROJECT itself. The
# red command only fails the way a test does if package.json is beside it,
# and the new test file must be recorded relative to the project.
printf 'test("dues", () => {});\n' > "$REPO/tests/dues.test.ts"
( cd "$W" && bash "$HOME_D/.claude/scripts/gate.sh" test --red-cmd 'test -f package.json && { echo "FAIL dues.test.ts: expected 0"; false; }' ) >"$W/red.log" 2>&1
grep -q '"red_files":"tests/dues.test.ts' "$GATE" \
  && ok "the red run executes in the project and records its test file project-relative" \
  || no "the red run executes in the project and records its test file project-relative" "$(tail -2 "$W/red.log")"
rm -f "$REPO/tests/dues.test.ts"
bash "$HOME_D/.claude/scripts/gate.sh" create --problem "National total sums chapter dues twice" \
  --red "n/a: fixture for the external layout test" >/dev/null 2>&1
gc "gate.sh create opens the project's source"                  "$RN/src/services/dues.ts" 0
bash "$HOME_D/.claude/scripts/gate.sh" idle >/dev/null 2>&1
gc "gate.sh idle closes it again"                                "$RN/src/services/dues.ts" 2
[ -f "$HOME_D/.claude/state/gate.seal" ] && ok "the seal is written in the home" || no "the seal is written in the home"

hd "6. bash-audit watches the project and the home's gate"
( cd "$REPO" && bash "$H/bash-audit.sh" pre </dev/null >/dev/null 2>&1
  echo x > src/services/sneaky.ts
  bash "$H/bash-audit.sh" post </dev/null >/dev/null 2>&1 ); rc=$?
[ "$rc" = 2 ] && ok "a script-invoked write to project source is caught" || no "a script-invoked write to project source is caught" "exit $rc"
rm -f "$REPO/src/services/sneaky.ts"
( cd "$REPO" && bash "$H/bash-audit.sh" pre </dev/null >/dev/null 2>&1
  printf '{"phase":"create","problem":"forged by an interpreter write","red":"n/a: forged gate for the test"}\n' > "$GATE"
  bash "$H/bash-audit.sh" post </dev/null >/dev/null 2>&1 ); rc=$?
[ "$rc" = 2 ] && grep -q '"phase":"idle"' "$GATE" \
  && ok "a rewritten home gate.json is caught and put back" \
  || no "a rewritten home gate.json is caught and put back" "exit $rc, $(cat "$GATE")"

hd "7. The pipeline's location reaches the model on every session and prompt"
OUT=$(cd "$REPO" && printf '{"source":"startup","session_id":"abc"}' | bash "$H/session-log.sh" 2>/dev/null)
case "$OUT" in *"OUTSIDE this repository, at $HN"*) ok "session start names the home" ;; *) no "session start names the home" "$OUT" ;; esac
case "$OUT" in *"gate phase is idle"*) ok "session start states the phase" ;; *) no "session start states the phase" "$OUT" ;; esac
OUT=$(cd "$REPO" && printf '{"source":"compact","session_id":"abc"}' | bash "$H/session-log.sh" 2>/dev/null)
case "$OUT" in *"re-read after compaction"*) ok "after /compact the pipeline CLAUDE.md is re-injected" ;; *) no "after /compact the pipeline CLAUDE.md is re-injected" ;; esac
OUT=$(cd "$REPO" && printf '{"prompt":"hi"}' | bash "$H/prompt-context.sh" 2>/dev/null)
case "$OUT" in *"$HN"*"never create .claude/"*) ok "every prompt carries the home and the do-not-write rule" ;; *) no "every prompt carries the home and the do-not-write rule" "$OUT" ;; esac
repo_is_clean "repository untouched after the hooks ran"

hd "8. Refused layouts"
mkdir -p "$W/outer/repo2"
( cd "$W/outer/repo2" && git init -q ) >/dev/null 2>&1
bash "$SRC/install.sh" --plan pro --target "$W/outer/repo2" --home "$W/outer/repo2/.pipeline" >/dev/null 2>&1 \
  && no "a home inside the project is refused" || ok "a home inside the project is refused"
bash "$SRC/install.sh" --plan pro --target "$W/outer/repo2" --home "$W/outer" >/dev/null 2>&1 \
  && no "a home around the project is refused" || ok "a home around the project is refused"

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
