#!/usr/bin/env bash
# PreToolUse(Bash): rewrites verbose commands so only failures return to the
# model. Fails OPEN: a broken filter must never block work.
set -uo pipefail
SELF="${BASH_SOURCE[0]}"
# shellcheck source=/dev/null
. "$(dirname "$SELF")/_guard.sh"

INPUT=$(cat)
studio_guard "$SELF" || { echo '{}'; exit 0; }

CMD="$(json_field "$INPUT" 'tool_input.command')"
[ -z "${CMD:-}" ] && { echo '{}'; exit 0; }

# Only the noisy commands whose failures are what matter. ANCHORED: an
# unanchored *...* match hits the script name anywhere in a compound command,
# and since the rewrite ends in `exit`, everything after it in that command
# would be silently swallowed.
case "$CMD" in
  "{{TEST_COMMAND}}"|"{{TEST_COMMAND}} "*) ;;
  "{{BUILD_COMMAND}}"|"{{BUILD_COMMAND}} "*) ;;
  "{{TYPECHECK_COMMAND}}"|"{{TYPECHECK_COMMAND}} "*) ;;
  "{{DEPENDENCY_AUDIT_COMMAND}}"|"{{DEPENDENCY_AUDIT_COMMAND}} "*) ;;
  *) echo '{}'; exit 0 ;;
esac

# Never touch a command the user already piped or redirected themselves.
case "$CMD" in *\|*|*\>*) echo '{}'; exit 0 ;; esac

# --- the rewrite must preserve the ORIGINAL command's exit status -----------
#
# A pipeline reports its LAST command's status, so the previous
# `cmd | grep | head` form returned 0 even when cmd failed. Measured:
#
#   old rewrite  -> exit 0   (original command exited 1)
#   this rewrite -> exit 1   (original command exited 1)
#
# Every VERIFY gate in this pipeline reads that exit code. A red test suite, a
# failed build and a high-severity audit finding all reported success -- which
# is the precise failure this repo's third claim ("done is a claim, not
# evidence") exists to prevent, arriving through the one tool that was supposed
# to be producing the evidence.
#
# ${PIPESTATUS[0]} is the fix, NOT `set -o pipefail`: grep exits 1 when it
# matches nothing, which is the PASSING case here, so pipefail would invert the
# bug and report every clean run as a failure.
#
# awk, not head: head closes the pipe once it has its lines, and the resulting
# SIGPIPE upstream would overwrite the very status being preserved.
#
# --- and it must leave EVIDENCE that a pass happened ------------------------
#
# Filtering to failure patterns alone means a passing suite returns NOTHING:
# the exit code says green while the evidence for it has been filtered away,
# and a gate that must close on an artifact then has no artifact to close on.
# So each runner's one-line verdict is matched too -- anchored rather than by
# bare word, because a per-test "PASS" line would put the whole run back into
# context, which is the cost this hook exists to avoid.
#
# The mark set matters: ESLint's summary bullet is U+2716, which is none of the
# three crosses a test runner uses. A filter that knows only the test
# vocabulary quietly eats a real lint or audit finding and leaves behind an
# exit code nobody can explain.
FILTER="grep -B2 -A8 -E '(FAIL|ERROR|Error|error:|✕|✗|✘|✖|^ *[0-9]+:[0-9]+ +(error|warning)|problems? \(|assert|Exception|vulnerabilit|advisor|Timed out|^ *Tests?: |^ *Duration: |\[OK\]|built in |No security vulnerability|[0-9]+ (passed|failed|vulnerabilities))'"

# --- and it must MEASURE what it claims to save ----------------------------
#
# This is the largest token saving in the pipeline and, until this block, the
# only major one with no instrument on it. The repo's own standard for a
# defensible number (DESIGN-RATIONALE §14) is "sampled unfiltered output
# averaged 11,400 tokens; filtered averaged 890" -- a mechanism, a count and a
# measurement. Nothing produced that sample. `verify.sh` checked only that the
# string `updatedInput` appeared in this hook's stdout, which proves the hook
# has an opinion, not that the opinion ever reaches the model or is worth
# anything when it does.
#
# So the rewrite tees both ends and records the pair. Two `tee`s, no change to
# what the model sees and none to the exit status: ${PIPESTATUS[0]} still names
# $CMD because tee is downstream of it. `bash .claude/scripts/savings.sh` reads
# the log.
#
# Every part of this is `|| true` and `2>/dev/null`. A recorder that can fail a
# build has inverted the point of the hook it lives in: this file fails OPEN,
# and measurement is never the thing that closes it.
LOGGER="__r=\$(mktemp 2>/dev/null) __f=\$(mktemp 2>/dev/null)"
NEW="$LOGGER; $CMD 2>&1 | tee \"\$__r\" 2>/dev/null | $FILTER | awk 'NR<=150' | tee \"\$__f\" 2>/dev/null"
# [0] and not [1]: `$LOGGER` ends in `;`, so the pipeline starts at $CMD. The
# added `tee`s are all DOWNSTREAM of it and shift nothing.
NEW="$NEW; __rc=\${PIPESTATUS[0]}"
NEW="$NEW; { [ -n \"\$__r\" ] && [ -n \"\$__f\" ] && mkdir -p .claude/state && printf '%s\t%s\t%s\t%s\n' \"\$(date -u '+%Y-%m-%dT%H:%M:%SZ')\" \"\$(wc -c < \"\$__r\" | tr -d ' ')\" \"\$(wc -c < \"\$__f\" | tr -d ' ')\" \"\$__rc\" >> .claude/state/filter-log.tsv; } 2>/dev/null || true"
NEW="$NEW; rm -f \"\$__r\" \"\$__f\" 2>/dev/null || true"
NEW="$NEW; [ \"\$__rc\" -ne 0 ] && echo \"[filter-output] command exited \$__rc — output above is matched lines only\"; exit \$__rc"

# -c is load-bearing, not cosmetic. `jq -n` PRETTY-PRINTS by default, so this
# branch would emit multi-line JSON while the printf branch emits one line --
# the same hook speaking two shapes depending on whether jq happens to be
# installed, which is exactly how a check passes on a laptop and fails in CI.
#
# And jq is used only if it WORKS. `command -v jq` succeeding proves a file
# exists on PATH, not that it runs: a jq built against the wrong libc, or a
# shim, exits non-zero and emits nothing. This hook must then still return a
# valid decision object -- emitting nothing at all is not "fail open", it is an
# unparseable hook response, and the command it was rewriting does not run.
OUT=""
if command -v jq >/dev/null 2>&1; then
  OUT=$(jq -n -c --arg cmd "$NEW" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",updatedInput:{command:$cmd}}}' 2>/dev/null) \
    || OUT=""
fi
if [ -n "$OUT" ]; then
  printf '%s\n' "$OUT"
else
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"command":"%s"}}}\n' \
    "$(json_escape "$NEW")"
fi
