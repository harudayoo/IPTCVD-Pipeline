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

STATE=".claude/state"
LOG="$STATE/session-log.tsv"

INPUT=$(cat 2>/dev/null || true)

# No _guard.sh here, deliberately. This hook carries no configure-time
# placeholder and has nothing to be misconfigured, and a recorder that refused
# to record until the pipeline was configured would miss exactly the sessions
# where somebody is still setting it up.
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

PHASE="-"
if [ -f "$STATE/gate.json" ]; then
  if command -v jq >/dev/null 2>&1; then
    PHASE=$(jq -r '.phase // "-"' "$STATE/gate.json" 2>/dev/null) || PHASE="-"
  fi
  case "$PHASE" in ""|null) PHASE=$(grep -o '"phase"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE/gate.json" 2>/dev/null \
      | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//') ;;
  esac
fi
[ -n "$PHASE" ] || PHASE="-"

mkdir -p "$STATE" 2>/dev/null || true
printf '%s\t%s\t%s\t%s\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)" \
  "$SOURCE" "$PHASE" "${SESSION:0:8}" >> "$LOG" 2>/dev/null || true

exit 0
