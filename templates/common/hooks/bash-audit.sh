#!/usr/bin/env bash
# PreToolUse(Bash) + PostToolUse(Bash): the backstop for whatever bash-gate.sh's
# parser cannot see. bash-gate recognises COMMAND SHAPES -- sed -i, a redirect,
# cp, a package manager add. It will always miss one: a script invoked by
# path, a wrapper this repo has not been taught yet, tomorrow's tool. This hook
# does not try to recognise anything. It snapshots which guarded files are
# dirty before the command runs and which are dirty after, and refuses to let
# a NEW one through, whatever produced it.
#
# Registered TWICE in settings.json, as the SAME script with a different
# trailing argument: `.claude/hooks/bash-audit.sh pre` on PreToolUse(Bash),
# `.claude/hooks/bash-audit.sh post` on PostToolUse(Bash). A build that instead
# identifies the event from the hook payload's `hook_event_name` is also
# handled, so this does not depend on argument passing specifically.
#
# MEASURED, not assumed. The audit's original design compared file mtimes with
# `find <roots> -newer <stamp>`. Against a synthetic 6,000-file source tree on
# Windows/Git Bash -- the platform this hook has to run on, not a Linux CI
# runner -- that took roughly 1.4s, almost all of it `sys` time from MSYS's
# stat() path. `git ls-files`/`git diff --name-only` over the same tree took
# roughly 0.35s. Both would run on EVERY Bash call, not only Edit/Write, so the
# difference compounds here faster than anywhere else in this design. git wins
# outright, not merely as a fallback, so this hook never touches mtime at all:
# no stamp file, and no same-second tie to work around with `touch -d`.
#
# A plain before/after set of DIRTY PATHS is not enough, and the first draft
# of this hook shipped that gap before it was caught here in review: dirty is
# a boolean, and a file that is already dirty from a PRIOR Bash call (the
# model ignored the first BLOCKED message, or simply has not reverted yet)
# stays dirty without changing state, so a SECOND write to it during a later
# call would show identically in both snapshots and never be flagged. The
# `find -newer <stamp>` design this replaced did not have that gap, because it
# re-touched its stamp fresh on every single call; matching that per-call
# precision is the actual bar, not merely "detects an eventual write".
#
# So each snapshot line is `path<TAB>content-hash` via `git hash-object`, not
# just a path. Two files: `git diff --name-only HEAD` (tracked, differs from
# HEAD -- catches a write later `git add`ed within the same call, which `git
# ls-files -m` alone would miss once staged) and `git ls-files -o
# --exclude-standard` (brand new, untracked). `comm -13` between the sorted
# PRE and POST `path<TAB>hash` sets then catches both a newly-dirty path AND a
# CONTENT CHANGE to a path that was already dirty, because the hash moves
# either way. `git hash-object` only runs over the (usually small) set of
# already-dirty/untracked paths, never the whole tree, so this stays cheap
# regardless of repository size.
#
# Residual gap, named rather than hidden: restoring a file to the EXACT bytes
# it had at the start of this call, mid-call, leaves its hash unchanged and is
# invisible here -- a write that erases its own evidence. That shape has no
# legitimate reason to exist and is far more elaborate than any bypass this
# repo has measured; accepted as out of scope, the same call the original
# mtime design made about `touch -r`.
set -uo pipefail
SELF="${BASH_SOURCE[0]}"
HOOKDIR="$(cd "$(dirname "$SELF")" && pwd)"
# shellcheck source=/dev/null
. "$HOOKDIR/_guard.sh"

cd "$HOOKDIR/../.." 2>/dev/null || exit 0
studio_guard "$SELF" >/dev/null 2>&1 || exit 0

# --- which event is this? -----------------------------------------------
MODE="${1:-}"
if [ "$MODE" != pre ] && [ "$MODE" != post ]; then
  INPUT_PEEK=$(cat 2>/dev/null || true)
  case "$INPUT_PEEK" in
    *'"hook_event_name"'*'"PreToolUse"'*)  MODE=pre ;;
    *'"hook_event_name"'*'"PostToolUse"'*) MODE=post ;;
    *) exit 0 ;;   # neither argument nor payload says which -- nothing to audit
  esac
fi

# --- roots this hook watches --------------------------------------------
PROTECTED="{{SOURCE_ROOTS_REGEX}}"
# "^(src|app)(/|$)" -> "src|app" -> split into git PATHSPECS, not a regex --
# unlike bash-gate.sh's ROOT_ALT (used only inside grep -E, where the outer
# parens are harmless regex grouping), this one feeds `git diff --/-- <paths>`
# directly, and git has no idea what to do with a literal "(src)" pathspec.
ROOT_ALT="${PROTECTED#^}"; ROOT_ALT="${ROOT_ALT%'(/|$)'}"
ROOT_ALT="${ROOT_ALT#\(}"; ROOT_ALT="${ROOT_ALT%\)}"
[ -n "$ROOT_ALT" ] || exit 0
OLDIFS="$IFS"; IFS='|'; set -- $ROOT_ALT; IFS="$OLDIFS"
ROOTS="$*"
MANIFESTS="package.json composer.json Cargo.toml go.mod pyproject.toml requirements.txt Gemfile build.gradle build.gradle.kts pom.xml"

STAMP=".claude/state/.bash-audit-pre.tsv"

# shellcheck disable=SC2086
snapshot() {
  local f
  { git diff --name-only HEAD -- $ROOTS $MANIFESTS 2>/dev/null
    git ls-files -o --exclude-standard -- $ROOTS $MANIFESTS 2>/dev/null
  } | sort -u | while IFS= read -r f; do
      [ -n "$f" ] && [ -f "$f" ] || continue
      printf '%s\t%s\n' "$f" "$(git hash-object -- "$f" 2>/dev/null)"
    done
}

if [ "$MODE" = pre ]; then
  mkdir -p .claude/state 2>/dev/null || true
  snapshot > "$STAMP" 2>/dev/null || true
  exit 0
fi

# --- post: only matters once the phase says source should be untouched ---
PHASE=""
if [ -f .claude/state/gate.json ]; then
  if command -v jq >/dev/null 2>&1; then
    PHASE=$(jq -r '.phase // ""' .claude/state/gate.json 2>/dev/null) || PHASE=""
  fi
  [ -n "$PHASE" ] || PHASE=$(grep -o '"phase"[[:space:]]*:[[:space:]]*"[^"]*"' .claude/state/gate.json 2>/dev/null \
    | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')
fi
[ -n "$PHASE" ] || PHASE="idle"
[ "$PHASE" = "create" ] && exit 0

# No pre-snapshot means the PreToolUse half never ran for this call (a fresh
# install mid-configure, or the pair somehow did not both fire). Nothing to
# compare against -- fail OPEN, the same as every other measurement in this
# hook set. bash-gate.sh is still the pre-emptive door; this is its backstop,
# not the only lock.
[ -f "$STAMP" ] || exit 0

AFTER="$(snapshot)"
BEFORE="$(cat "$STAMP" 2>/dev/null || true)"
# Each line is `path<TAB>hash`; comm on the full line catches BOTH a path new
# to the dirty set and a hash change on a path already in it. The path alone
# (cut -f1) is what gets reported and reverted -- and de-duplicated, in case a
# file's hash somehow appears twice (it cannot, but a report should never
# repeat a filename regardless).
NEW="$(comm -13 <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") 2>/dev/null \
       | sed '/^$/d' | cut -f1 | sort -u)"
[ -n "$NEW" ] || exit 0

echo "BLOCKED: this Bash command changed a guarded file, and the gate phase is" >&2
echo "  '$PHASE', not 'create'. No parser recognised the command that did it --" >&2
echo "  bash-gate.sh only catches shapes it knows; this is the backstop for the" >&2
echo "  ones it does not." >&2
printf '%s\n' "$NEW" | sed 's/^/    /' >&2
FILELIST="$(printf '%s' "$NEW" | tr '\n' ' ')"
echo "Revert it:  git checkout -- $FILELIST" >&2
echo "Or open the gate properly:  bash .claude/scripts/gate.sh create --problem \"...\" --red \"...\"" >&2
while IFS= read -r f; do
  [ -n "$f" ] || continue
  studio_log_gate bash-audit BYPASS "$PHASE" "$f" post-hoc
done <<EOF
$NEW
EOF
exit 2
