#!/usr/bin/env bash
# Stop hook: source changed this session but documentation did not.
# Fails OPEN (warns, never blocks) if git is unavailable.
set -uo pipefail
SELF="${BASH_SOURCE[0]}"
# shellcheck source=/dev/null
. "$(dirname "$SELF")/_guard.sh"
studio_guard "$SELF" || exit 0
command -v git >/dev/null 2>&1 || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# `git diff HEAD` lists TRACKED modifications only, so a brand-new controller
# or service that had never been `git add`ed did not appear here at all -- the
# change most likely to need a new doc was the one change this gate waved
# through. `ls-files --others` adds the untracked side; --exclude-standard
# keeps .gitignore'd build output from ever reaching the regex.
CHANGED=$( { git diff --name-only HEAD 2>/dev/null
             git ls-files --others --exclude-standard 2>/dev/null; } \
           | grep -E "{{SOURCE_ROOTS_REGEX}}" || true)

# --- what phase is the work in? ---------------------------------------------
# This hook fires on EVERY Stop, and exit 2 does not merely warn -- it refuses
# the stop and forces another turn. So an unconditional block means that from
# the first source edit until the doc is written, the session cannot hand
# control back to the user AT ALL: no mid-implementation check-in, no course
# correction, and every forced turn re-sends the entire conversation.
#
# That is a large, invisible token cost charged for a rule that only has to
# hold at the END of the work -- and a gate that makes the session unusable is
# a gate that gets switched off, which costs more than the rule was worth.
#
# gate.json already models the distinction. `create`/`verify` means a slice is
# in flight; the document phase resets it to `idle`. So: nudge while in flight,
# block once the work claims to be finished. The rule is unchanged -- source
# cannot ship undocumented -- only the moment it is enforced.
GATE=".claude/state/gate.json"
PHASE="idle"
[ -f "$GATE" ] && PHASE="$(json_field "$(cat "$GATE")" 'phase')"
[ -n "${PHASE:-}" ] || PHASE="idle"

DOCS_TOUCHED=$(git status --short docs/ 2>/dev/null)

if [ -z "$CHANGED" ]; then
  # No source in flight. A gate left open stops guarding anything, and the next
  # change -- possibly next session -- silently skips the plan requirement.
  # Nothing checked for this before; the document phase was the only thing
  # standing between an open gate and an ungated change.
  case "$PHASE" in
    create|verify)
      echo "note: gate.json is still {\"phase\":\"$PHASE\"} and no source is changed." >&2
      echo "      Left open it stops gating the next change:  bash .claude/scripts/gate.sh idle" >&2
      ;;
  esac
  exit 0
fi

case "$PHASE" in
  create|verify)
    # Work in flight: remind, do not block. The block lands at handoff instead.
    if [ -z "$DOCS_TOUCHED" ]; then
      echo "reminder: source is changed and docs/ is not. That is fine mid-phase, but" >&2
      echo "          resetting the gate to idle with the doc unwritten will block." >&2
    fi
    exit 0
    ;;
esac

if [ -z "$DOCS_TOUCHED" ]; then
  echo "Source changed but docs/ did not. Run /handoff, or state why no doc change is needed." >&2
  studio_log_gate doc-check BLOCK "$PHASE" docs/ undocumented-source
  exit 2
fi
exit 0
