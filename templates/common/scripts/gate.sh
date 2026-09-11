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

# Dense length: whitespace stripped, so "   ok   " does not read as eight
# characters of content.
_dense() { printf '%s' "$1" | tr -d '[:space:]'; }

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

    # Advancing INTO a source-writing phase still requires the answers. If the
    # slice never had them, this is the moment to say so rather than to open a
    # gate on nothing.
    case "$NEXT" in
      create|verify)
        if [ -z "$PROBLEM" ] || [ -z "$RED" ]; then
          echo "refusing to advance to '$NEXT': the slice on record carries no problem/red note." >&2
          echo "  Open it properly instead:" >&2
          echo "    bash .claude/scripts/gate.sh $NEXT --problem \"<what breaks>\" --red \"<the failing test, or n/a: why>\"" >&2
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

    # Both must carry an ANSWER, not a keystroke. The hook can only check that
    # something was stated; this checks a SENTENCE was stated. `n/a` on its own
    # is the specific evasion worth naming: the entire value of --red is that a
    # change with no failing test has to say WHY, and a bare `--red n/a` turns
    # the phase back into the box-tick it replaced.
    P_C=$(_dense "$PROBLEM")
    if [ ${#P_C} -lt 12 ]; then
      echo "refusing: --problem is ${#P_C} characters of content." >&2
      echo '  The IDEA phase is what BREAKS and what is out of scope — a sentence, not a token.' >&2
      exit 1
    fi
    case $(printf '%s' "$RED" | tr '[:upper:]' '[:lower:]') in
      n/a*)
        REASON="${RED#*:}"
        [ "$REASON" = "$RED" ] && REASON=""   # no colon at all
        R_C=$(_dense "$REASON")
        if [ ${#R_C} -lt 8 ]; then
          echo 'refusing: --red "n/a" without a reason is not an answer.' >&2
          echo '  Use: --red "n/a: <why this change has no failing test to point at>"' >&2
          exit 1
        fi
        ;;
      *)
        R_C=$(_dense "$RED")
        if [ ${#R_C} -lt 12 ]; then
          echo "refusing: --red is ${#R_C} characters of content." >&2
          echo '  The TEST phase names the test that fails NOW, or says "n/a: <why>".' >&2
          exit 1
        fi
        ;;
    esac

    # --reuse and --deps are the same shape of answer and get the same floor.
    # A one-word "yes" here is the box-tick the reuse gate exists to refuse.
    for pair in "reuse:$REUSE" "deps:$DEPS"; do
      name="${pair%%:*}"; val="${pair#*:}"
      [ -n "$val" ] || continue
      V_C=$(_dense "$val")
      [ ${#V_C} -ge 12 ] && continue
      echo "refusing: --$name is ${#V_C} characters of content." >&2
      echo "  Name what you checked first and why it does not cover this — e.g." >&2
      echo "  \"no date helper here; hand-rolled the same parser in 3 places already\"." >&2
      exit 1
    done

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
