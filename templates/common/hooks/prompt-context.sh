#!/usr/bin/env bash
# UserPromptSubmit: one or two lines in front of every prompt -- the gate phase,
# and in the external layout, where the pipeline lives.
#
# WHY EVERY PROMPT, not only at session start: the field report this answers
# was an agent that followed the pipeline, drifted, was told where the pipeline
# files were, followed it again, and drifted again. SessionStart covers a new
# session, /clear and /compact; it does not cover a long session in which the
# start of the context has simply stopped being attended to. Claude Code adds
# this hook's stdout to context on every prompt, so the phase and the location
# are always the most recent thing the model was told, not the oldest.
#
# Cost is the reason it stays this short: ~60 tokens a prompt, against a
# pipeline whose whole account is kept in tokens. The long form is
# studio_brief at SessionStart; this is the reminder, not the manual.
#
# Fails OPEN and SILENT: a hook that errors on UserPromptSubmit shows the user
# an error on every message, and a reminder is not worth that.
set -uo pipefail
SELF="${BASH_SOURCE[0]}"
# shellcheck source=/dev/null
. "$(dirname "$SELF")/_guard.sh" 2>/dev/null || exit 0
studio_locate "$SELF"
cat >/dev/null 2>&1 || true   # drain the payload; nothing in it is needed
studio_brief "$(studio_gate_phase "$STUDIO_STATE/gate.json")" 2>/dev/null || true
exit 0
