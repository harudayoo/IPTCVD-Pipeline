#!/usr/bin/env bash
#
# claude-studio self-test
#
# Proves the hooks actually fire, and that the installed inventory matches the
# tier that was installed. Run after configure.sh and again any time you change
# a hook or the profile.
#
# A hook you have not watched fire is a hook you do not have.
#
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$(pwd)"
[ "${1:-}" = "--target" ] && { TARGET="$(cd "$2" && pwd)"; shift 2; }
cd "$TARGET" || { echo "cannot enter $TARGET" >&2; exit 1; }

PASS=0; FAIL=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

[ -d .claude/hooks ] || { echo "no .claude/hooks — run install.sh first"; exit 1; }

hook() { printf '%s' "$2" | bash ".claude/hooks/$1" 2>/dev/null; }
rc_of() { printf '%s' "$2" | bash ".claude/hooks/$1" >/dev/null 2>&1; echo $?; }

# ------------------------------------------------------------- installed tier
read_tier() {
  [ -f .claude/state/studio.json ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r '.tier // empty' .claude/state/studio.json 2>/dev/null
  else
    tr -d '\n' < .claude/state/studio.json \
      | grep -o '"tier"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//'
  fi
}
PLAN="$(read_tier || true)"
MANIFEST="$SRC/templates/tiers/$PLAN/manifest.conf"
if [ -n "$PLAN" ] && [ -f "$MANIFEST" ]; then
  # shellcheck source=/dev/null
  . "$MANIFEST"
else
  TIER_NAME="unknown"; TIER_AGENTS=""; TIER_SKILLS=""; TIER_RULES=""
  TIER_UI_AGENTS=""; TIER_UI_SKILLS=""; TIER_UI_RULES=""
fi

printf '\n\033[1mclaude-studio self-test\033[0m  ·  %s plan\n' "$TIER_NAME"

head_ "0. Configuration"
if [ -n "$PLAN" ] && [ -f "$MANIFEST" ]; then
  pass "installed tier recorded: $PLAN"
else
  fail "cannot read the installed tier from .claude/state/studio.json — re-run install.sh"
fi
if grep -rq '{{[A-Z_]*}}' .claude 2>/dev/null; then
  fail "placeholders remain — run ./configure.sh"
  grep -rl '{{[A-Z_]*}}' .claude | sed 's/^/       /'
else
  pass "no unresolved placeholders"
fi
for f in .claude/hooks/*.sh; do
  [ -x "$f" ] && pass "executable: $(basename "$f")" || fail "not executable: $(basename "$f")"
done

GATE=.claude/state/gate.json
SAVED="$(cat "$GATE" 2>/dev/null || echo '{"phase":"idle"}')"
restore() { printf '%s\n' "$SAVED" > "$GATE"; }
trap restore EXIT

head_ "1. Gate blocks source edits outside the create phase"
printf '{"phase":"idle","feature":null,"slug":null,"approved":[]}\n' > "$GATE"
SRC_FILE="$(grep -oE '\^\(([^)]*)\)' .claude/hooks/gate-check.sh | head -1 \
            | sed 's/^\^(//; s/)$//' | cut -d'|' -f1)/probe.ts"
[ "$(rc_of gate-check.sh "{\"tool_input\":{\"file_path\":\"$SRC_FILE\"}}")" = 2 ] \
  && pass "blocks $SRC_FILE" || fail "blocks $SRC_FILE"
# The ABSOLUTE spelling is the one Claude Code really sends. A ^-anchored
# source-root regex does not match it, so this suite once passed while the
# gate was inert in production: it fed the one relative spelling that happened
# to work. Test what ships, not what is convenient to type.
[ "$(rc_of gate-check.sh "{\"tool_input\":{\"file_path\":\"$TARGET/$SRC_FILE\"}}")" = 2 ] \
  && pass "blocks the ABSOLUTE spelling of $SRC_FILE" \
  || fail "blocks the ABSOLUTE spelling of $SRC_FILE - the gate is inert in real use"
[ "$(rc_of gate-check.sh "{\"tool_input\":{\"file_path\":\"./$SRC_FILE\"}}")" = 2 ] \
  && pass "blocks a ./-prefixed path" || fail "blocks a ./-prefixed path"
[ "$(rc_of gate-check.sh "{\"tool_input\":{\"file_path\":\"docs/../$SRC_FILE\"}}")" = 2 ] \
  && pass "blocks traversal out of an allow rule" \
  || fail "blocks traversal out of an allow rule"
[ "$(rc_of gate-check.sh '{"tool_input":{"file_path":"docs/specs/x/idea.md"}}')" = 0 ] \
  && pass "allows docs/" || fail "allows docs/"
[ "$(rc_of gate-check.sh '{"tool_input":{"file_path":"tests/x.test.ts"}}')" = 0 ] \
  && pass "allows tests/" || fail "allows tests/"
[ "$(rc_of gate-check.sh '{"tool_input":{"file_path":".claude/agents/x.md"}}')" = 0 ] \
  && pass "allows .claude/" || fail "allows .claude/"

head_ "1b. The shell door is gated too"
# gate-check.sh is registered on Edit|Write only, so without bash-gate.sh the
# entire pipeline is one `sed -i` away from irrelevant.
if [ -f .claude/hooks/bash-gate.sh ]; then
  [ "$(rc_of bash-gate.sh "{\"tool_input\":{\"command\":\"sed -i s/a/b/ $SRC_FILE\"}}")" = 2 ] \
    && pass "blocks sed -i on $SRC_FILE" || fail "blocks sed -i on $SRC_FILE"
  [ "$(rc_of bash-gate.sh "{\"tool_input\":{\"command\":\"echo x > $SRC_FILE\"}}")" = 2 ] \
    && pass "blocks a shell redirect into source" \
    || fail "blocks a shell redirect into source"
  [ "$(rc_of bash-gate.sh '{"tool_input":{"command":"cat README.md"}}')" = 0 ] \
    && pass "leaves an ordinary read alone" || fail "leaves an ordinary read alone"
  [ "$(rc_of bash-gate.sh '{"tool_input":{"command":"npm ci"}}')" = 0 ] \
    && pass "leaves a lockfile restore alone" || fail "leaves a lockfile restore alone"
else
  fail "bash-gate.sh is installed - without it the gate only guards Edit/Write"
fi

head_ "2. Gate opens in the create phase"
# The gate no longer opens on a phase name alone: it wants the IDEA and TEST
# answers too, because a boolean gate certifies that a plan exists and never
# what it said. A fixture with no problem/red is correctly refused.
printf '{"phase":"create","feature":"probe","slug":"probe","approved":["plan"],"problem":"verify.sh fixture: the probe path stands in for real source","red":"n/a: synthetic fixture, no behaviour to pin"}\n' > "$GATE"
[ "$(rc_of gate-check.sh "{\"tool_input\":{\"file_path\":\"$SRC_FILE\"}}")" = 0 ] \
  && pass "allows $SRC_FILE in create" || fail "allows $SRC_FILE in create"
restore

head_ "3. Output filter"
# filter-output's case list is ANCHORED now -- `"cmd"|"cmd "*)` rather than
# `"cmd"*|` -- because an unanchored match hits the command name anywhere in a
# compound line, and the rewrite ends in `exit`, so everything after it was
# silently swallowed. Read the first quoted command out of that list.
TESTCMD="$(grep -oE '^  "[^"]+"' .claude/hooks/filter-output.sh | head -1 | sed 's/^ *"//; s/"$//')"
if [ -n "$TESTCMD" ]; then
  out="$(hook filter-output.sh "{\"tool_input\":{\"command\":\"$TESTCMD\"}}")"
  case "$out" in *updatedInput*) pass "rewrites: $TESTCMD" ;; *) fail "rewrites: $TESTCMD" ;; esac
else
  fail "could not read the test command out of filter-output.sh"
fi
[ "$(hook filter-output.sh '{"tool_input":{"command":"ls -la"}}')" = "{}" ] \
  && pass "ignores unrelated commands" || fail "ignores unrelated commands"
[ "$(hook filter-output.sh "{\"tool_input\":{\"command\":\"$TESTCMD | tee o.txt\"}}")" = "{}" ] \
  && pass "leaves piped commands alone" || fail "leaves piped commands alone"

head_ "3b. The output filter preserves exit status"
# `cmd | grep | head` returns head's status, so a red suite reported green and
# every VERIFY gate downstream read that 0 as evidence of a pass.
if grep -q 'PIPESTATUS' .claude/hooks/filter-output.sh 2>/dev/null; then
  pass "rewrite preserves the original exit status (PIPESTATUS)"
else
  fail "rewrite preserves exit status - without it a failing suite reports success"
fi

head_ "3c. The enforcement layer is the one that was reviewed"
if [ -x .claude/scripts/hook-integrity.sh ]; then
  if bash .claude/scripts/hook-integrity.sh >/dev/null 2>&1; then
    pass "hooks match .claude/state/hooks.sha256"
  else
    fail "hooks match hooks.sha256 (re-record: bash .claude/scripts/hook-integrity.sh --update)"
  fi
else
  fail "hook-integrity.sh is installed - nothing else makes a disarmed hook visible"
fi

head_ "4. Doc check"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  bash .claude/hooks/doc-check.sh >/dev/null 2>&1
  pass "runs without error (exit $?)"
else
  printf '  \033[33mSKIP\033[0m not a git repository\n'
fi

head_ "5. Inventory ($TIER_NAME roster)"
# A UI-only piece that configure.sh pruned is a SKIP, not a failure.
is_ui_only() {  # is_ui_only <kind> <name>
  local list
  case "$1" in
    agents) list="${TIER_UI_AGENTS:-}" ;;
    skills) list="${TIER_UI_SKILLS:-}" ;;
    rules)  list="${TIER_UI_RULES:-}"  ;;
  esac
  case " $list " in *" $2 "*) return 0 ;; esac
  return 1
}
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; }

if [ -z "${TIER_AGENTS:-}" ]; then
  fail "no manifest for tier '$PLAN' — cannot check the inventory"
else
  for n in $TIER_AGENTS; do
    if [ -f ".claude/agents/$n.md" ]; then pass "agent: $n"
    elif is_ui_only agents "$n";  then skip "agent: $n (removed: no UI)"
    else fail "agent: $n missing"; fi
  done
  for s in $TIER_SKILLS; do
    if [ -f ".claude/skills/$s/SKILL.md" ]; then pass "skill: /$s"
    elif is_ui_only skills "$s";        then skip "skill: /$s (removed: no UI)"
    else fail "skill: /$s missing"; fi
  done
  for r in $TIER_RULES; do
    if [ -f ".claude/rules/$r.md" ]; then pass "rule: $r.md"
    elif is_ui_only rules "$r";     then skip "rule: $r.md (removed: no UI)"
    else fail "rule: $r.md missing"; fi
  done
fi

head_ "6. Nothing extra"
# An agent left behind by a tier switch still costs listing space and can
# shadow delegation. Report it rather than deleting it.
if [ -n "${TIER_AGENTS:-}" ] && [ -d .claude/agents ]; then
  extra=0
  for f in .claude/agents/*.md; do
    [ -e "$f" ] || continue
    n="$(basename "$f" .md)"
    case " $TIER_AGENTS " in *" $n "*) continue ;; esac
    fail "unexpected agent: $n (not in the $TIER_NAME roster — left over from another tier?)"
    extra=1
  done
  [ "$extra" = 0 ] && pass "no agents outside the $TIER_NAME roster"
fi

head_ "7. Context budget"
# Claude Code caps how much of the skill name-and-description listing enters
# context (the blueprint puts it around 1% of the window). Past the cap,
# descriptions are TRUNCATED — nothing errors, skills just silently stop
# auto-triggering. This is an estimate from description length; /context and
# /doctor inside Claude Code are the authority.
if [ -d .claude/skills ]; then
  n_skill=0; desc_chars=0
  for f in .claude/skills/*/SKILL.md; do
    [ -e "$f" ] || continue
    n_skill=$((n_skill + 1))
    d=$(sed -n '/^---$/,/^---$/p' "$f" | sed -n 's/^description:[[:space:]]*//p' | head -1)
    desc_chars=$((desc_chars + ${#d} + ${#f}))
  done
  est=$((desc_chars / 4))
  printf '  \033[2m%d skills · ~%d tokens of listing (estimate)\033[0m\n' "$n_skill" "$est"
  # ~2000 tokens is 1% of a 200k window. Warn at 75% of that.
  if [ "$est" -gt 2000 ]; then
    fail "skill listing ~${est} tokens — likely past the cap; descriptions may be truncated"
  elif [ "$est" -gt 1500 ]; then
    printf '  \033[33mWARN\033[0m listing ~%d tokens — approaching the cap. Run /doctor.\n' "$est"
  else
    pass "skill listing within budget (~$est tokens)"
  fi
  # Skills the tier did not install are third-party. Name them so their cost is
  # attributable — this is the number docs/DESIGN-STACK.md asks you to watch.
  if [ -n "${TIER_SKILLS:-}" ]; then
    foreign=""
    for d in .claude/skills/*/; do
      [ -d "$d" ] || continue
      n="$(basename "$d")"
      case " $TIER_SKILLS " in *" $n "*) continue ;; esac
      foreign="$foreign $n"
    done
    [ -n "$foreign" ] && printf '  \033[2mthird-party skills:%s\033[0m\n' "$foreign"
  fi
fi

head_ "8. Hook audit"
# Two hooks on the same event and matcher both fire on every matching call.
# That is a decision, not a default — see docs/DESIGN-STACK.md section 6.
if [ ! -f .claude/settings.json ]; then
  printf '  \033[33mSKIP\033[0m no .claude/settings.json\n'
elif ! command -v jq >/dev/null 2>&1; then
  printf '  \033[33mSKIP\033[0m jq not installed\n'
else
  for ev in PreToolUse PostToolUse Stop SessionStart UserPromptSubmit; do
    cnt=$(jq --arg e "$ev" '(.hooks[$e] // []) | length' .claude/settings.json 2>/dev/null || echo 0)
    [ "${cnt:-0}" -gt 0 ] || continue
    jq -r --arg e "$ev" '.hooks[$e][] | "\(.matcher // "*")\t\(.hooks[0].command // "?")"' \
      .claude/settings.json 2>/dev/null | while IFS="$(printf '\t')" read -r m c; do
        case "$c" in
          .claude/hooks/*) printf '  \033[2m%-13s %-12s %s\033[0m\n' "$ev" "$m" "$c" ;;
          *)               printf '  \033[33m%-13s %-12s %s  (third-party)\033[0m\n' "$ev" "$m" "$c" ;;
        esac
      done
    # Same event + same matcher, more than once.
    dup=$(jq -r --arg e "$ev" '[.hooks[$e][] | .matcher // "*"] | group_by(.)
                               | map(select(length > 1) | .[0]) | join(",")' \
          .claude/settings.json 2>/dev/null)
    if [ -n "$dup" ]; then
      printf '  \033[33mWARN\033[0m %s: multiple hooks on matcher(s) %s — both fire on every matching call.\n' "$ev" "$dup"
      printf '       \033[2mDeliberate? Design detection is usually worth more at the VERIFY gate\n'
      printf '       than on every edit. See docs/DESIGN-STACK.md section 6.\033[0m\n'
    fi
  done
  studio_hooks=$(jq '[.hooks | to_entries[] | .value[] | .hooks[]?
                      | select(.command // "" | startswith(".claude/hooks/"))] | length' \
                 .claude/settings.json 2>/dev/null || echo 0)
  n_expected=$(find .claude/hooks -name '_*' -prune -o -name '*.sh' -print 2>/dev/null | wc -l | tr -d ' ')
  [ "${studio_hooks:-0}" -ge "${n_expected:-5}" ] \
    && pass "all $n_expected studio hooks registered" \
    || fail "only ${studio_hooks:-0} of $n_expected studio hooks registered in settings.json"
fi

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Fix the failures before trusting the pipeline.\n'; exit 1
fi
printf 'Hooks are live. Next: /doctor and /context in Claude Code.\n'
