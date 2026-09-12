#!/usr/bin/env bash
#
# IPTCVD Pipeline configure
#
# Reads docs/setup/PROFILE.md (which YOU have confirmed by running each
# command) and substitutes the placeholders left behind by install.sh.
#
# Refuses to run if the profile still contains NEEDS_REVIEW. That refusal is
# the point: a half-configured hook that silently matches nothing is worse
# than no hook at all.
#
# Tier-aware: which pieces get pruned on a project with no UI comes from the
# installed tier's manifest, not from a list hardcoded here.
#
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$(pwd)"
DRY_RUN=0
ALLOW_INCOMPLETE=0

c_red() { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn() { printf '\033[32m%s\033[0m\n' "$*"; }
c_yel() { printf '\033[33m%s\033[0m\n' "$*"; }
c_dim() { printf '\033[2m%s\033[0m\n' "$*"; }
die()   { c_red "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$(cd "$2" && pwd)"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --allow-incomplete) ALLOW_INCOMPLETE=1; shift ;;
    -h|--help)
      echo "usage: ./configure.sh [--target DIR] [--dry-run] [--allow-incomplete]"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

P="$TARGET/docs/setup/PROFILE.md"
[ -f "$P" ] || die "no profile at docs/setup/PROFILE.md — run install.sh first"

# ------------------------------------------------------------- installed tier
STUDIO_STATE="$TARGET/.claude/state/studio.json"
read_tier() {
  [ -f "$STUDIO_STATE" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r '.tier // empty' "$STUDIO_STATE" 2>/dev/null
  else
    tr -d '\n' < "$STUDIO_STATE" \
      | grep -o '"tier"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//'
  fi
}

PLAN="$(read_tier || true)"
if [ -z "$PLAN" ] || [ ! -f "$SRC/templates/tiers/$PLAN/manifest.conf" ]; then
  c_yel "warning: cannot read the installed tier from .claude/state/studio.json."
  c_dim "  Falling back to the Pro manifest for UI pruning. Re-run install.sh to fix."
  PLAN="pro"
fi
# shellcheck source=/dev/null
. "$SRC/templates/tiers/$PLAN/manifest.conf"

if grep -q 'NEEDS_REVIEW' "$P" && [ "$ALLOW_INCOMPLETE" = 0 ]; then
  c_red "PROFILE.md still contains NEEDS_REVIEW:"
  grep -n 'NEEDS_REVIEW' "$P" | sed 's/^/  /'
  echo
  c_dim "Fill these in and run every command to confirm it works, then re-run."
  c_dim "To proceed anyway (hooks will stay inert and warn): --allow-incomplete"
  exit 1
fi

# A markdown table cell cannot contain a `|`. The parser below splits on it, so
# a value like `vitest run | tee out.txt` silently becomes `vitest run` -- the
# profile says one thing, the hook is configured with another, and nothing
# reports a problem. That is the precise failure shape this pipeline exists to
# remove, sitting in the file every hook is configured FROM.
#
# So: detect the extra cell and refuse. A well-formed row is
# `| label | value | status |`, which awk -F'|' sees as 5 fields (the empty
# strings either side of the leading and trailing pipes count).
check_row_shape() {
  awk -F'|' -v want="$1" '
    $0 ~ /^\|/ {
      lbl = $2; gsub(/^[ 	]+|[ 	]+$/, "", lbl)
      if (lbl == want && NF > 5) {
        printf "%s", $0
        exit 1
      }
    }' "$P" && return 0
  return 1
}

# Pull a value out of the profile's markdown table by row label.
field() {
  local label="$1"
  awk -F'|' -v want="$label" '
    $0 ~ /^\|/ {
      gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $3)
      gsub(/`/, "", $3)
      if ($2 == want) { print $3; exit }
    }' "$P"
}

PROJECT_NAME="$(field 'Project name')"
STACK_LINE="$(field 'Stack')"
DEV_COMMAND="$(field 'Dev command')"
TEST_COMMAND="$(field 'Test command (non-watching)')"
SINGLE_TEST_COMMAND="$(field 'Single-test command')"
FORMAT_COMMAND="$(field 'Format command (fixes)')"
TYPECHECK_COMMAND="$(field 'Type-check command')"
BUILD_COMMAND="$(field 'Build command')"
DEPENDENCY_AUDIT_COMMAND="$(field 'Dependency audit command')"
SOURCE_ROOTS="$(field 'Source roots')"
FRONTEND_ROOT="$(field 'Front-end root')"
TEST_ROOT="$(field 'Test root')"
SHARED_SURFACES="$(field 'Shared surfaces')"
TOKEN_FILE="$(field 'Design token file')"
HAS_UI="$(field 'Has UI')"

[ -n "$TEST_COMMAND" ]  || die "could not read 'Test command' from the profile"

# Refuse a row whose value contains a pipe BEFORE anything is substituted.
for _lbl in "Dev command" "Test command (non-watching)" "Single-test command"             "Format command (fixes)" "Type-check command" "Build command"             "Dependency audit command" "Source roots" "Front-end root" "Test root"             "Shared surfaces" "Design token file"; do
  if _row=$(check_row_shape "$_lbl"); then :; else
    c_red "error: the '$_lbl' row has more cells than a markdown table row can hold."
    c_dim "  row: $_row"
    c_dim "  A '|' inside the value splits the cell, so the value is silently truncated"
    c_dim "  at the pipe and the hook is configured with something you did not write."
    c_dim "  Put the pipeline into a script and name the script here instead."
    exit 1
  fi
done


# ---------------------------------------------------- profile value validation
#
# Profile values are substituted into hook SOURCE, and they land in two shapes
# that fail differently:
#
#   EXECUTED   post-edit.sh runs `{{FORMAT_COMMAND}} "$FILE"` on every edit. The
#              value is shell, unquoted -- it has to be, or a two-word command
#              like `npx prettier -w` could not work. So a `;` or a `$(...)` in
#              that field is a second command running on every single edit.
#
#   MATCHED    filter-output.sh puts commands inside `case` PATTERNS. A `)` or a
#              `|` there does not inject anything -- it ends the pattern early
#              and leaves the file syntactically broken, so the hook dies on
#              every Bash call and the harness reports a hook error rather than
#              anything about the actual problem.
#
# PROFILE.md is the project owner's own file, confirmed by running each command,
# so this is not a defence against an attacker who already has commit access.
# It is a defence against a paste, a stray character, and a hook that silently
# becomes a syntax error -- which, in a pipeline whose entire claim is that its
# gates are deterministic, is the expensive failure.
# A `case` pattern cannot come from a VARIABLE. Bash expands $pat and then
# treats the result as a single pattern -- the `|` inside it is an ordinary
# character, not alternation, so a helper taking the pattern as an argument
# silently matched nothing. It was doing that while eight test cases reported
# PASS, because a separate bug was rejecting every value for another reason.
# Two wrongs cancelling out is the worst shape a green suite can have, so the
# patterns below are written literally, once per field.
_die_val() {  # _die_val <label> <value> <what is wrong>
  c_red "error: '$1' contains $3."
  c_dim "  value: $2"
  c_dim "  Profile values are substituted into hook SOURCE, so this would leave the"
  c_dim "  hooks broken, or running something you did not intend, on every edit."
  c_dim "  Use a plain command; put any chaining into a script and name the script."
  exit 1
}

# EXECUTED: post-edit.sh runs `<format command> "$FILE"` on every edit, unquoted
# -- it has to be, or a two-word command like `npx prettier -w` could not work.
# A `;`, a backtick or a `$(...)` in that field is a second command running on
# every single edit.
for _pair in "Format command (fixes)|$FORMAT_COMMAND" "Type-check command|$TYPECHECK_COMMAND"; do
  _label="${_pair%%|*}"; _val="${_pair#*|}"
  case "$_val" in ""|NEEDS_REVIEW|true) continue ;; esac
  case "$_val" in
    *[\;\|\&\<\>]*|*'`'*|*'$('*)
      _die_val "$_label" "$_val" "a shell metacharacter: one of ; | & backtick dollar-paren < >" ;;
  esac
done

# MATCHED: filter-output.sh puts these inside `case` PATTERNS. A `)` or a bare
# `|` there injects nothing -- it ends the pattern early and leaves the hook
# syntactically broken, so it dies on every Bash call and the harness reports a
# hook error instead of anything about the real problem.
#
# `&&` stays legal: install.sh legitimately builds "composer audit && npm audit",
# and an ampersand inside a case pattern is an ordinary literal.
for _pair in "Test command (non-watching)|$TEST_COMMAND" "Build command|$BUILD_COMMAND" \
             "Dependency audit command|$DEPENDENCY_AUDIT_COMMAND"; do
  _label="${_pair%%|*}"; _val="${_pair#*|}"
  case "$_val" in ""|NEEDS_REVIEW|true) continue ;; esac
  case "$_val" in
    *'('*|*')'*|*\\*)
      _die_val "$_label" "$_val" "a parenthesis or a backslash, which breaks a case pattern" ;;
  esac
  # A lone `|` breaks the pattern; `||` is shell chaining and is no better here.
  case "$_val" in
    *'|'*) _die_val "$_label" "$_val" "a pipe, which ends the case pattern early" ;;
  esac
done

# A newline in any of them corrupts the file outright, whichever shape it takes.
#
# $'\n', NOT "$(printf '\n')". Command substitution strips trailing newlines,
# so the latter evaluates to the EMPTY STRING and the guard becomes
# `case $v in **)` -- which matches every value there is. The first version of
# this check rejected every legitimate profile in the repo while reporting a
# precise, confident reason ("contains a line break"). A guard that is wrong in
# the fail-closed direction is still wrong: this one made configure.sh unusable
# on a correct profile, which is how a check gets deleted rather than fixed.
_NL=$'\n'; _CR=$'\r'
for _pair in "Format command (fixes)|$FORMAT_COMMAND" "Type-check command|$TYPECHECK_COMMAND" \
             "Test command (non-watching)|$TEST_COMMAND" "Build command|$BUILD_COMMAND" \
             "Dependency audit command|$DEPENDENCY_AUDIT_COMMAND" "Source roots|$SOURCE_ROOTS" \
             "Test root|$TEST_ROOT" "Shared surfaces|$SHARED_SURFACES"; do
  _label="${_pair%%|*}"; _val="${_pair#*|}"
  case "$_val" in
    *"$_NL"*|*"$_CR"*)
      c_red "error: '$_label' contains a line break."
      exit 1 ;;
  esac
done

# Path-ish fields must be paths, not globs or traversals: they are anchored into
# the gate's own regexes, and a `..` there would widen the guard rather than
# narrow it.
for _pair in "Source roots|$SOURCE_ROOTS" "Test root|$TEST_ROOT" "Shared surfaces|$SHARED_SURFACES"; do
  _label="${_pair%%|*}"; _val="${_pair#*|}"
  case "$_val" in ""|NEEDS_REVIEW|n/a) continue ;; esac
  case "$_val" in
    *..*|*'*'*|*'?'*|/*)
      c_red "error: '$_label' must be repo-relative directory names, comma-separated."
      c_dim "  value: $_val"
      c_dim "  No globs, no '..', no leading '/'. These are compiled into the gate's"
      c_dim "  path patterns, where a wildcard widens the guard instead of narrowing it."
      exit 1 ;;
  esac
done


[ -n "$SOURCE_ROOTS" ]  || die "could not read 'Source roots' from the profile"

# Source roots -> an ERE the hooks can grep with:  "app,src"  ->  "^(app|src)/"
SOURCE_ROOTS_REGEX="^($(printf '%s' "$SOURCE_ROOTS" | tr -d ' ' | tr ',' '|'))/"

# Shared surfaces -> an ERE the gate can grep with:
#   "src/components,src/services"  ->  "^(src/components|src/services)/"
#
# Creating a file under one of these has to state what it reuses. Editing an
# existing file never does. An empty value switches the reuse gate off, and the
# hook treats an empty pattern as "no shared surfaces" rather than as "match
# everything" -- an unset guard that matched everything would block the whole
# project and get itself deleted within the hour.
# A TEST ROOT that sits INSIDE a source root is a gate that disables itself.
# `Test root: src` with `Source roots: src` makes the allow rule match every
# file under src/, so the phase gate never fires on anything -- and the install
# still reports success, which is the exact failure mode this repo exists to
# remove. Drop the location rule when it collides and say so; test FILES are
# still recognised by the shape of their name, so the TEST phase keeps working.
for _r in $(printf '%s' "$SOURCE_ROOTS" | tr ',' ' '); do
  case "$TEST_ROOT" in
    "$_r"|"$_r"/*)
      c_yel "  warning: test root '$TEST_ROOT' is inside source root '$_r'."
      c_dim "    A location-based allow rule there would ungate the whole root, so it"
      c_dim "    is dropped. Test files are still matched by filename (*_test.*,"
      c_dim "    *.test.*, *.spec.*, test_*), which is what Go/Rust/JS layouts need."
      TEST_ROOT=""
      ;;
  esac
done

if [ -n "$SHARED_SURFACES" ]; then
  SHARED_SURFACE_REGEX="^($(printf '%s' "$SHARED_SURFACES" | tr -d ' ' | tr ',' '|'))/"
else
  SHARED_SURFACE_REGEX=""
fi

# Globs for the rules
BACKEND_GLOB="${SOURCE_ROOTS%%,*}/**/*"
FRONTEND_GLOB="${FRONTEND_ROOT}/**/*"
TEST_GLOB="${TEST_ROOT}/**/*"

# Case globs for post-edit.sh
FORMAT_GLOB='*.ts|*.tsx|*.js|*.jsx|*.vue|*.php|*.py|*.go|*.rs'
TYPECHECK_GLOB='*.ts|*.tsx'

echo
c_grn "Configuring $TARGET  ·  $TIER_NAME plan"
c_dim "  test:      $TEST_COMMAND"
c_dim "  single:    $SINGLE_TEST_COMMAND"
c_dim "  format:    $FORMAT_COMMAND"
c_dim "  typecheck: $TYPECHECK_COMMAND"
c_dim "  audit:     $DEPENDENCY_AUDIT_COMMAND"
c_dim "  protected: $SOURCE_ROOTS_REGEX"
c_dim "  reuse gate: ${SHARED_SURFACE_REGEX:-(off — none declared)}"
echo

# Literal string replacement via awk. No sed delimiters, so values may safely
# contain |, @, /, & or any other character that would break a sed script.
_replace_all() {  # _replace_all <file> <key=value> ...
  local f="$1"; shift
  awk -v n="$#" 'BEGIN{
        for (i = 1; i <= n; i++) { split(ARGV[i], kv, "="); k[i] = kv[1]
          v[i] = substr(ARGV[i], length(kv[1]) + 2); ARGV[i] = "" }
      }
      { line = $0
        for (i = 1; i <= n; i++) {
          key = "{{" k[i] "}}"
          while ((pos = index(line, key)) > 0)
            line = substr(line, 1, pos - 1) v[i] substr(line, pos + length(key))
        }
        print line }' "$@" "$f" > "$f.studio.tmp" || { rm -f "$f.studio.tmp"; return 1; }
  # Preserve mode: mv would drop the executable bit on hooks.
  cat "$f.studio.tmp" > "$f"
  rm -f "$f.studio.tmp"
}

subst() {
  local f="$1"
  [ -f "$f" ] || return 0
  grep -q '{{[A-Z_]*}}' "$f" || return 0
  if [ "$DRY_RUN" = 1 ]; then c_dim "  would configure ${f#$TARGET/}"; return; fi
  _replace_all "$f" \
    "PROJECT_NAME=$PROJECT_NAME" \
    "STACK_LINE=$STACK_LINE" \
    "DEV_COMMAND=$DEV_COMMAND" \
    "TEST_COMMAND=$TEST_COMMAND" \
    "SINGLE_TEST_COMMAND=$SINGLE_TEST_COMMAND" \
    "FORMAT_COMMAND=$FORMAT_COMMAND" \
    "TYPECHECK_COMMAND=$TYPECHECK_COMMAND" \
    "BUILD_COMMAND=$BUILD_COMMAND" \
    "DEPENDENCY_AUDIT_COMMAND=$DEPENDENCY_AUDIT_COMMAND" \
    "SOURCE_ROOTS=$SOURCE_ROOTS" \
    "SOURCE_ROOTS_REGEX=$SOURCE_ROOTS_REGEX" \
    "SHARED_SURFACES=$SHARED_SURFACES" \
    "SHARED_SURFACE_REGEX=$SHARED_SURFACE_REGEX" \
    "FRONTEND_ROOT=$FRONTEND_ROOT" \
    "TEST_ROOT=$TEST_ROOT" \
    "TOKEN_FILE=$TOKEN_FILE" \
    "HAS_UI=$HAS_UI" \
    "BACKEND_GLOB=$BACKEND_GLOB" \
    "FRONTEND_GLOB=$FRONTEND_GLOB" \
    "TEST_GLOB=$TEST_GLOB" \
    "FORMAT_GLOB=$FORMAT_GLOB" \
    "TYPECHECK_GLOB=$TYPECHECK_GLOB"
  c_dim "  configured ${f#$TARGET/}"
}

find "$TARGET/.claude" -type f \( -name '*.md' -o -name '*.sh' \) -print0 2>/dev/null \
  | while IFS= read -r -d '' f; do subst "$f"; done
chmod +x "$TARGET/.claude/hooks/"*.sh 2>/dev/null || true
subst "$TARGET/CLAUDE.md"
subst "$TARGET/CLAUDE.studio.md"

# Doc map: source area -> the doc that is supposed to describe it. The audit
# script reads this to compute staleness. Extend it as the project grows.
if [ "$DRY_RUN" = 0 ]; then
  mkdir -p "$TARGET/.claude/state"
  {
    printf '{\n'
    printf '  "%s": "docs/architecture.md"' "${SOURCE_ROOTS%%,*}"
    if [ -n "$FRONTEND_ROOT" ] && [ "$FRONTEND_ROOT" != "NEEDS_REVIEW" ]; then
      printf ',\n  "%s": "docs/design/components.md"' "$FRONTEND_ROOT"
    fi
    # Keys must stay unique — a repeated key silently wins over the earlier one
    # when the audit script parses this, which would drop the mapping above.
    case "${TIER_EXTRA_DOC_DIRS:-}" in
      *docs/runbooks*) printf ',\n  ".github/workflows": "docs/runbooks/ci.md"' ;;
    esac
    printf '\n}\n'
  } > "$TARGET/.claude/state/doc-map.json"
  c_dim "  wrote .claude/state/doc-map.json"
fi

# If there is no UI, drop the UI-only pieces rather than leaving them to rot.
# Which pieces those are is declared per tier, because a Max 20x install has
# six UI agents and a Pro install has one.
if [ "$DRY_RUN" = 0 ] && printf '%s' "$HAS_UI" | grep -qi '^no'; then
  dropped=""
  for a in ${TIER_UI_AGENTS:-}; do
    [ -f "$TARGET/.claude/agents/$a.md" ] || continue
    rm -f "$TARGET/.claude/agents/$a.md"; dropped="$dropped $a"
  done
  for s in ${TIER_UI_SKILLS:-}; do
    [ -d "$TARGET/.claude/skills/$s" ] || continue
    rm -rf "$TARGET/.claude/skills/$s"; dropped="$dropped /$s"
  done
  for r in ${TIER_UI_RULES:-}; do
    [ -f "$TARGET/.claude/rules/$r.md" ] || continue
    rm -f "$TARGET/.claude/rules/$r.md"; dropped="$dropped $r.md"
  done
  # CLAUDE.md loads in full every session. A frontend-direction block on a
  # service or a library is standing cost for nothing.
  for f in "$TARGET/CLAUDE.md" "$TARGET/CLAUDE.studio.md"; do
    [ -f "$f" ] || continue
    grep -q 'studio:frontend-direction:start' "$f" || continue
    sed -i.studio.bak \
      '/<!-- studio:frontend-direction:start -->/,/<!-- studio:frontend-direction:end -->/d' "$f" \
      && rm -f "$f.studio.bak"
    dropped="$dropped $(basename "$f")#frontend-direction"
  done
  [ -n "$dropped" ] && c_yel "  no UI: removed$dropped"
fi

# Record what the enforcement layer IS, now that it is fully substituted.
# gate-check.sh allows every write under .claude/, which it must -- a session
# has to be able to repair a broken install. The cost is that appending
# `exit 0` to a hook is the cheapest bypass in the whole pipeline, and nothing
# in the working tree would look wrong afterwards. This manifest is what makes
# that edit a visible diff instead of a silent one.
# Arm the size ratchet against the tree as it is TODAY. Recording it here is
# what makes it adoptable: the bar applies to what happens next, not to a
# backlog nobody agreed to fix this week. Without a baseline the first CI run
# fails on a legacy tree and the check gets deleted rather than fixed.
if [ "$DRY_RUN" = 0 ] && [ -x "$TARGET/.claude/scripts/ratchet.sh" ]; then
  ( cd "$TARGET" && bash .claude/scripts/ratchet.sh --update 2>/dev/null )     | sed 's/^/  /' || true
fi

if [ "$DRY_RUN" = 0 ] && [ -x "$TARGET/.claude/scripts/hook-integrity.sh" ]; then
  ( cd "$TARGET" && bash .claude/scripts/hook-integrity.sh --update >/dev/null 2>&1 )     && c_dim "  recorded .claude/state/hooks.sha256"
fi

echo
LEFT=$(grep -rl '{{[A-Z_]*}}' "$TARGET/.claude" "$TARGET/CLAUDE.md" 2>/dev/null || true)
if [ -n "$LEFT" ]; then
  c_yel "Still unresolved:"; printf '%s\n' "$LEFT" | sed "s|$TARGET/|  |"
else
  c_grn "All placeholders resolved. Hooks are live."
fi
echo
c_dim "Next: open Claude Code and run /doctor, /hooks, /context."
c_dim "Then prove the gate fires: ./verify.sh --target ."
