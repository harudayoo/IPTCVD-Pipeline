#!/usr/bin/env bash
#
# claude-studio configure
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
