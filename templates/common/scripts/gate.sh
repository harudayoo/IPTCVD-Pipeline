#!/usr/bin/env bash
# Reads and writes .claude/state/gate.json -- the plan record the hooks enforce.
#
# The gate began as a boolean ({"phase":"create"}) and certified only that a
# plan EXISTED, never what it said. The two phases with an artifact but nothing
# gate-readable are reliably the two that get skipped -- IDEA, because stating
# the problem feels like overhead once you can already see the fix, and TEST,
# because writing the test after the code still produces a green suite. A test
# written after the implementation is worse than no test: it reads as coverage
# while having never once failed.
#
# So the phases now carry their answer in the same place the phase name does.
#
#   bash .claude/scripts/gate.sh create \
#     --problem "National finance summed every chapter's dues into the total" \
#     --red     "DuesTest::national_excludes_chapter fails: expected 0, got 41250" \
#     [--reuse  "extend DuesScope; it already models the two tiers"] \
#     [--deps   "no date helper here; hand-rolled the same parser in 3 places"]
#
#   bash .claude/scripts/gate.sh advance verify   # next phase, SAME notes
#   bash .claude/scripts/gate.sh advance document
#   bash .claude/scripts/gate.sh idle      # handoff -- reset, so the default
#                                          # is blocked again
#   bash .claude/scripts/gate.sh show      # what is on record right now
#   bash .claude/scripts/gate.sh log       # the decision history
#
# Use `advance` for every transition INSIDE a slice. A phase change is not a new
# plan. Writing the phase by hand -- which is what "update gate.json: set phase
# to create" means when read literally -- erases the notes and slams the gate
# shut on a change that had answered everything correctly, one phase after the
# mistake was made.
#
# --reuse is required to CREATE a file under a shared-surface directory.
# --deps is required to edit a dependency manifest.
#
# --red takes either the evidence that a test went red before the code existed,
# or an honest "n/a: <reason>" -- a design token has no failing test to write.
# The hook cannot judge testability, so it requires the answer to be STATED
# rather than guessing; the reviewing agent checks the answer against the diff.
set -uo pipefail

# Resolve this script's own path BEFORE changing directory. usage() reads the
# header back out of $0, and after the cd a relative $0 no longer resolves --
# so `--help` printed a sed error and exited 0, which is a help text that
# reports success while telling you nothing.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# The content floors (problem/red/reuse/deps, how long is long enough) live in
# _guard.sh's studio_validate_notes now, not here -- a hand-written gate.json
# used to open the gate on notes this CLI would have refused, because the two
# checks were separate implementations that happened to agree. One function,
# sourced by both.
GUARD_SH="$(dirname "$SELF")/../hooks/_guard.sh"
if [ -f "$GUARD_SH" ]; then
  # shellcheck source=/dev/null
  . "$GUARD_SH"
else
  echo "gate.sh: cannot find _guard.sh at $GUARD_SH -- the content floors live there now." >&2
  exit 1
fi

cd "$(dirname "$0")/../.." || exit 1
GATE=".claude/state/gate.json"

# JSON-escape: backslash and quote, then control characters that would break
# the file. These values arrive from a human sentence, not a machine.
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037'; }

# The header IS the help text, so it cannot drift from the implementation.
# The range ends at `set -u`, found rather than hardcoded: a hardcoded line
# number silently truncates the help the first time the header grows.
usage() {
  sed -n "2,$(( $(grep -n '^set -u' "$SELF" | head -1 | cut -d: -f1) - 1 ))p" "$SELF" \
    | sed 's/^# \{0,1\}//'
}

CMD="${1:-show}"
[ $# -gt 0 ] && shift

case "$CMD" in
  idle|plan|test|document)
    mkdir -p "$(dirname "$GATE")"
    printf '{"phase":"%s"}\n' "$([ "$CMD" = "idle" ] && echo idle || echo "$CMD")" > "$GATE"
    echo "gate: $CMD — source edits are blocked."
    ;;

  show)
    if [ -f "$GATE" ]; then cat "$GATE"; else echo "no $GATE (treated as idle)"; fi
    ;;

  advance)
    # Move to the next phase WITHOUT restating the notes.
    #
    # The phase skills hand off between themselves several times per slice
    # (test -> create -> verify), and every one of those transitions used to be
    # "write phase=X into gate.json". Against a gate that also wants `problem`
    # and `red`, that silently erases them -- so the CREATE phase would open the
    # gate and the very next transition would slam it shut on a slice that had
    # answered everything correctly. A phase change is not a new plan; it should
    # carry the plan it already has.
    NEXT="${1:-}"
    case "$NEXT" in
      idle|plan|test|create|verify|document) ;;
      *) echo "usage: gate.sh advance <plan|test|create|verify|document|idle>" >&2; exit 1 ;;
    esac
    if [ ! -f "$GATE" ]; then
      echo "refusing: no $GATE to advance. Open the slice with: gate.sh create --problem ... --red ..." >&2
      exit 1
    fi

    read_key() {  # read_key <name> -- prints the value, or nothing
      if command -v jq >/dev/null 2>&1; then
        v=$(jq -r --arg k "$1" '.[$k] // ""' "$GATE" 2>/dev/null) && [ -n "$v" ] && { printf '%s' "$v"; return; }
      fi
      grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"\(\\\\.\|[^\"\\\\]\)*\"" "$GATE" 2>/dev/null \
        | head -1 | sed "s/^\"$1\"[[:space:]]*:[[:space:]]*\"//; s/\"$//; s/\\\\\"/\"/g"
    }
    PROBLEM=$(read_key problem); RED=$(read_key red)
    VAULT=$(read_key vault); REUSE=$(read_key reuse); DEPS=$(read_key deps)

    # Advancing INTO a source-writing phase still requires the answers, and
    # requires them to clear the same floor `create`/`verify` enforce below --
    # a hand-written gate.json is one `advance` away from carrying "x" as its
    # problem note forever, since advance only ever CARRIES notes forward, it
    # never used to check them.
    case "$NEXT" in
      create|verify)
        if [ -z "$PROBLEM" ] || [ -z "$RED" ]; then
          echo "refusing to advance to '$NEXT': the slice on record carries no problem/red note." >&2
          echo "  Open it properly instead:" >&2
          echo "    bash .claude/scripts/gate.sh $NEXT --problem \"<what breaks>\" --red \"<the failing test, or n/a: why>\"" >&2
          exit 1
        fi
        if ! studio_validate_notes "$PROBLEM" "$RED" "$REUSE" "$DEPS"; then
          echo "refusing to advance to '$NEXT': the note above is on record but does not answer." >&2
          exit 1
        fi
        ;;
    esac

    {
      printf '{"phase":"%s"' "$NEXT"
      [ -n "$PROBLEM" ] && printf ',"problem":"%s"' "$(esc "$PROBLEM")"
      [ -n "$RED" ] && printf ',"red":"%s"' "$(esc "$RED")"
      [ -n "$VAULT" ] && printf ',"vault":"%s"' "$(esc "$VAULT")"
      [ -n "$REUSE" ] && printf ',"reuse":"%s"' "$(esc "$REUSE")"
      [ -n "$DEPS" ] && printf ',"deps":"%s"' "$(esc "$DEPS")"
      printf ',"updated_at":"%s"' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '}\n'
    } > "$GATE"
    echo "gate: $NEXT (notes carried forward)"
    ;;

  log)
    LOG=".claude/state/gate-log.tsv"
    if [ ! -f "$LOG" ]; then echo "no decisions recorded yet"; exit 0; fi
    printf '%-22s %-11s %-6s %-8s %s\n' WHEN HOOK VERDICT PHASE TARGET
    tail -"${1:-40}" "$LOG" | while IFS=$'\t' read -r ts hook verdict phase target reason; do
      printf '%-22s %-11s %-6s %-8s %s %s\n' "$ts" "$hook" "$verdict" "$phase" "$target" "${reason:+($reason)}"
    done
    echo
    echo "blocks: $(grep -c 'BLOCK' "$LOG" 2>/dev/null || echo 0)   allows: $(grep -c 'ALLOW' "$LOG" 2>/dev/null || echo 0)"
    ;;

  create|verify)
    PROBLEM=""; RED=""; VAULT=""; REUSE=""; DEPS=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --problem) shift; PROBLEM="${1:-}" ;;
        --red)     shift; RED="${1:-}" ;;
        --vault)   shift; VAULT="${1:-}" ;;
        --reuse)   shift; REUSE="${1:-}" ;;
        --deps)    shift; DEPS="${1:-}" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown flag: $1" >&2; usage >&2; exit 1 ;;
      esac
      shift
    done

    MISSING=""
    [ -z "$PROBLEM" ] && MISSING="--problem"
    [ -z "$RED" ] && MISSING="${MISSING:+$MISSING and }--red"
    if [ -n "$MISSING" ]; then
      echo "refusing to open the gate: $MISSING missing." >&2
      echo "  --problem is the IDEA phase; --red is the TEST phase. Both are one sentence." >&2
      echo "  No failing test to point at? Say so: --red \"n/a: <why>\"" >&2
      exit 1
    fi

    # Both must carry an ANSWER, not a keystroke. A hook can only check that
    # something was stated; studio_validate_notes checks a SENTENCE was
    # stated -- the same function gate-check.sh calls, so a hand-written
    # gate.json can no longer clear a floor this CLI would have refused.
    if ! studio_validate_notes "$PROBLEM" "$RED" "$REUSE" "$DEPS"; then
      exit 1
    fi

    mkdir -p "$(dirname "$GATE")"
    {
      printf '{"phase":"%s"' "$CMD"
      printf ',"problem":"%s"' "$(esc "$PROBLEM")"
      printf ',"red":"%s"' "$(esc "$RED")"
      [ -n "$VAULT" ] && printf ',"vault":"%s"' "$(esc "$VAULT")"
      [ -n "$REUSE" ] && printf ',"reuse":"%s"' "$(esc "$REUSE")"
      [ -n "$DEPS" ] && printf ',"deps":"%s"' "$(esc "$DEPS")"
      printf ',"updated_at":"%s"' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '}\n'
    } > "$GATE"
    echo "gate: $CMD — source edits unblocked. Reset at handoff: bash .claude/scripts/gate.sh idle"
    ;;

  -h|--help) usage ;;
  *) echo "unknown command: $CMD" >&2; usage >&2; exit 1 ;;
esac
