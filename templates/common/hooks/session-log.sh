#!/usr/bin/env bash
# SessionStart: records how each session began, and what the gate was doing at
# the time. Fails OPEN, always: a recorder that can block a session start is a
# recorder that gets deleted.
#
# WHY THIS EXISTS
#
# `/clear` between phases is the single largest token lever in this pipeline and
# the only major one nothing measures. Three clears per feature is the
# difference between a feature costing one context window and costing four --
# the README says so, CLAUDE.md says so, and the feature skill instructs the
# model to remind you. All three are prose. This repo's first claim is that
# prose is advisory, which makes the largest lever the least guarded thing here.
#
# It cannot be ENFORCED: no hook can make somebody type `/clear`, and one that
# tried would be blocking a session from starting. But the unenforceable thing
# can still be made VISIBLE -- the same move as hook-integrity.sh, which does
# not prevent a hook edit and instead turns it into a diff somebody sees.
#
# The `source` field is what makes a row worth keeping:
#
#   clear    somebody ran /clear -- the lever being pulled
#   compact  the window filled up instead. A compact where a clear belonged is
#            the failure this log exists to surface: the context was recycled
#            by the runtime at full price rather than dropped at zero.
#   startup  a fresh session
#   resume   picked an old one back up, full history re-sent
#
# The gate phase alongside it says WHERE in the pipeline it happened, which is
# the part that turns a count into a diagnosis: clears landing after PLAN and
# after CREATE is the documented rhythm; compacts landing mid-CREATE is a
# feature that overran its window.
set -uo pipefail

INPUT=$(cat 2>/dev/null || true)

# _guard.sh is SOURCED for studio_locate and studio_brief, but studio_guard is
# never called, deliberately. This hook carries no configure-time placeholder,
# and a recorder that refused to record until the pipeline was configured
# would miss exactly the sessions where somebody is still setting it up.
SELF="${BASH_SOURCE[0]}"
# shellcheck source=/dev/null
. "$(dirname "$SELF")/_guard.sh" 2>/dev/null || exit 0
studio_locate "$SELF"
STATE="$STUDIO_STATE"
LOG="$STATE/session-log.tsv"
field() {   # field <key> -- best-effort, never fatal
  local k="$1" v=""
  if command -v jq >/dev/null 2>&1; then
    v=$(printf '%s' "$INPUT" | jq -r ".$k // \"\"" 2>/dev/null) || v=""
  fi
  [ -z "$v" ] && v=$(printf '%s' "$INPUT" \
    | grep -o "\"$k\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" 2>/dev/null \
    | head -1 | sed "s/.*:[[:space:]]*\"//; s/\"$//") || true
  printf '%s' "${v:-}"
}

SOURCE=$(field source);  [ -n "$SOURCE" ] || SOURCE="unknown"
SESSION=$(field session_id); [ -n "$SESSION" ] || SESSION="-"

# Each parser must SUCCEED AND RETURN SOMETHING before it counts; the "-"
# default is applied once, at the end. Seeding PHASE with "-" up front made the
# sentinel mean both "not resolved yet" and "give up", so the grep fallback
# below could never fire -- in exactly the jq-degraded case it exists for.
PHASE=""
if [ -f "$STATE/gate.json" ]; then
  if command -v jq >/dev/null 2>&1; then
    PHASE=$(jq -r '.phase // ""' "$STATE/gate.json" 2>/dev/null) || PHASE=""
  fi
  case "$PHASE" in ""|null) PHASE=$(grep -o '"phase"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE/gate.json" 2>/dev/null \
      | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//') || PHASE="" ;;
  esac
fi
[ -n "$PHASE" ] || PHASE="-"

mkdir -p "$STATE" 2>/dev/null || true
printf '%s\t%s\t%s\t%s\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)" \
  "$SOURCE" "$PHASE" "${SESSION:0:8}" >> "$LOG" 2>/dev/null || true

# --- watch the enforcement layer's own doors --------------------------------
#
# hook-integrity.sh already runs in CI, which catches a tampered hook after it
# is already committed and, on a branch nobody is watching, after it has
# already run. This runs the same check here, at the START of every session,
# so the same drift is loud in THIS session's own transcript before a single
# Edit lands under it.
#
# Fails OPEN, same as everything else in this hook: a check that could block a
# session from starting would itself become the next thing worth disarming,
# and it cannot block anyway -- SessionStart has nothing to block.
#
# stdout is how it reaches the model: SessionStart is one of the few events
# where Claude Code adds plain-text stdout to context as something Claude can
# see and act on, rather than only logging it for a human to find later.
INTEGRITY_SH="$STUDIO_HOME/.claude/scripts/hook-integrity.sh"
if [ -f "$INTEGRITY_SH" ]; then
  if ! INTEGRITY_OUT=$(bash "$INTEGRITY_SH" 2>&1); then
    echo "INTEGRITY FAIL: the enforcement layer differs from what was last reviewed."
    printf '%s\n' "$INTEGRITY_OUT" | sed 's/^/  /'
    echo "If this change is intended: $(studio_script_cmd hook-integrity.sh) --update"
    echo "If it is not: revert the file(s) named above before trusting any gate here."
    { printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)" \
        session-log "INTEGRITY FAIL" "$PHASE" .claude/scripts/hook-integrity.sh \
        "hooks-differ-from-manifest" >> "$STATE/gate-log.tsv"; } 2>/dev/null || true
  fi
fi

# --- the pipeline's standing orders, every session ---------------------------
# See studio_brief in _guard.sh for why this is stdout and not only CLAUDE.md.
# After a COMPACT in the external layout, the pipeline CLAUDE.md itself is
# re-printed: it arrived through --add-dir, and nothing promises that is
# re-read the way a project-root CLAUDE.md is. Claude Code moves anything past
# 10,000 characters to a file and keeps a preview, so size is bounded anyway.
studio_brief "${PHASE/#-/idle}"
if [ "$STUDIO_EXTERNAL" = 1 ] && [ "$SOURCE" = compact ] && [ -f "$STUDIO_HOME/CLAUDE.md" ]; then
  echo
  echo "Pipeline instructions (re-read after compaction, from $STUDIO_HOME/CLAUDE.md):"
  cat "$STUDIO_HOME/CLAUDE.md" 2>/dev/null || true
fi

exit 0
