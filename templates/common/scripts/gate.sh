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
#   bash .claude/scripts/gate.sh test --red-cmd "npm test -- --filter dues"
#     # runs it, requires it to FAIL with assertion-shaped output, and
#     # records which test file(s) produced the failure plus their content
#     # hash -- not a sentence about a test, the test itself, run.
#
#   bash .claude/scripts/gate.sh create \
#     --problem "National finance summed every chapter's dues into the total" \
#     [--red    "DuesTest::national_excludes_chapter fails: expected 0, got 41250"] \
#     [--reuse  "extend DuesScope; it already models the two tiers"] \
#     [--deps   "no date helper here; hand-rolled the same parser in 3 places"]
#
#   bash .claude/scripts/gate.sh advance verify   # next phase, SAME notes --
#                                          # also re-runs red_cmd and re-hashes
#                                          # red_files; refuses if either moved
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
# --red, if omitted, is filled in from a `test --red-cmd` record when one is on
# file and still describes a real failure. Without a live record, state it by
# hand: either the evidence directly, or an honest "n/a: <reason>" -- a design
# token has no failing test to write. The hook cannot judge testability, so it
# requires the answer to be STATED rather than guessing; the reviewing agent
# checks the answer against the diff. A hand-typed --red is accepted even with
# no record behind it (the n/a escape valve would be pointless otherwise), but
# is logged as `red-manual` rather than `red-recorded` so the rate is visible.
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

# read_key <name> -- prints the value on record for one gate.json field, or
# nothing. Shared by `advance`, `create`/`verify`'s red_cmd fallback, and
# `test --red-cmd`, so there is one reader for every field this file writes.
read_key() {
  if command -v jq >/dev/null 2>&1; then
    v=$(jq -r --arg k "$1" '.[$k] // ""' "$GATE" 2>/dev/null) && [ -n "$v" ] && { printf '%s' "$v"; return; }
  fi
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"\(\\\\.\|[^\"\\\\]\)*\"" "$GATE" 2>/dev/null \
    | head -1 | sed "s/^\"$1\"[[:space:]]*:[[:space:]]*\"//; s/\"$//; s/\\\\\"/\"/g"
}

# read_all_keys -- populates every field this file knows about, from $GATE.
read_all_keys() {
  PROBLEM=$(read_key problem); RED=$(read_key red); VAULT=$(read_key vault)
  REUSE=$(read_key reuse); DEPS=$(read_key deps)
  RED_CMD=$(read_key red_cmd); RED_RC=$(read_key red_rc); RED_AT=$(read_key red_at)
  RED_FILES=$(read_key red_files); RED_SHA=$(read_key red_sha)
}

# write_gate <phase> -- writes every currently-set field (unset ones simply do
# not appear, same as the hand-rolled versions this replaces). One writer, so
# a field added here is a field every caller gets, instead of three call sites
# to keep in sync by hand.
write_gate() {
  {
    printf '{"phase":"%s"' "$1"
    [ -n "${PROBLEM:-}" ]   && printf ',"problem":"%s"'   "$(esc "$PROBLEM")"
    [ -n "${RED:-}" ]       && printf ',"red":"%s"'       "$(esc "$RED")"
    [ -n "${VAULT:-}" ]     && printf ',"vault":"%s"'     "$(esc "$VAULT")"
    [ -n "${REUSE:-}" ]     && printf ',"reuse":"%s"'     "$(esc "$REUSE")"
    [ -n "${DEPS:-}" ]      && printf ',"deps":"%s"'      "$(esc "$DEPS")"
    [ -n "${RED_CMD:-}" ]   && printf ',"red_cmd":"%s"'   "$(esc "$RED_CMD")"
    [ -n "${RED_RC:-}" ]    && printf ',"red_rc":"%s"'    "$(esc "$RED_RC")"
    [ -n "${RED_AT:-}" ]    && printf ',"red_at":"%s"'    "$(esc "$RED_AT")"
    [ -n "${RED_FILES:-}" ] && printf ',"red_files":"%s"' "$(esc "$RED_FILES")"
    [ -n "${RED_SHA:-}" ]   && printf ',"red_sha":"%s"'   "$(esc "$RED_SHA")"
    printf ',"updated_at":"%s"' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '}\n'
  } > "$GATE"
}

CMD="${1:-show}"
[ $# -gt 0 ] && shift

case "$CMD" in
  idle|plan|document)
    mkdir -p "$(dirname "$GATE")"
    printf '{"phase":"%s"}\n' "$CMD" > "$GATE"
    echo "gate: $CMD — source edits are blocked."
    ;;

  test)
    if [ "${1:-}" = "--red-cmd" ]; then
      # --- record red evidence, not a sentence about it -------------------
      #
      # {"phase":"create","red":"n/a"} used to open the gate on a CLAIM. A
      # freely-typed --red was never checked against anything, so "the test
      # fails" and an actual failing test carried identical weight. This
      # requires the SECOND one: run the command, require it to fail, require
      # the failure to read like a test failure rather than a crash, and
      # record which test file(s) produced it and their content hash -- so
      # gate-check.sh can freeze them during CREATE and `advance verify` can
      # catch a red test quietly weakened until it passed.
      RED_CMD_ARG=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --red-cmd) shift; RED_CMD_ARG="${1:-}" ;;
          -h|--help) usage; exit 0 ;;
          *) echo "unknown flag: $1" >&2; usage >&2; exit 1 ;;
        esac
        shift
      done
      [ -n "$RED_CMD_ARG" ] || { echo "refusing: --red-cmd needs a command to run." >&2; exit 1; }

      RCOUT=$(eval "$RED_CMD_ARG" 2>&1); RCRC=$?
      if [ "$RCRC" -eq 0 ]; then
        echo "refusing: --red-cmd exited 0. A red test FAILS before the code exists" >&2
        echo "  -- this command did not." >&2
        exit 1
      fi
      if ! printf '%s' "$RCOUT" | grep -qE "$STUDIO_ASSERTION_PATTERN"; then
        echo "refusing: --red-cmd exited $RCRC, but nothing in its output reads as a" >&2
        echo "  test failure (no FAIL/ERROR/assert-style line). A crash or a syntax" >&2
        echo "  error in the command is not evidence the test you meant to write" >&2
        echo "  actually failed." >&2
        exit 1
      fi

      # red_files: TEST files changed vs HEAD, or untracked, narrowed to the
      # SAME filename shapes gate-check.sh already trusts as tests -- declared
      # there once; matched here by the identical basename patterns so a file
      # this records as evidence is exactly one gate-check.sh would freeze.
      RFILES=""
      while IFS= read -r rf; do
        [ -n "$rf" ] || continue
        case "${rf##*/}" in
          *.test.*|*.spec.*|*_test.*|test_*|*Test.php|*Spec.php|*.Tests.cs|*Tests.cs|*Test.cs|conftest.py{{EXTRA_TEST_PATTERNS}})
            RFILES="$RFILES
$rf" ;;
        esac
      done < <({ git diff --name-only HEAD 2>/dev/null; git ls-files -o --exclude-standard 2>/dev/null; } | sort -u)
      RFILES=$(printf '%s\n' "$RFILES" | sed '/^$/d' | sort -u)

      if [ -z "$RFILES" ]; then
        echo "refusing: --red-cmd failed correctly, but no test file is changed or" >&2
        echo "  untracked. Nothing here can be frozen during create or re-checked at" >&2
        echo "  verify -- write the failing test first, then record it." >&2
        exit 1
      fi

      RSHA=""
      while IFS= read -r rf; do
        [ -n "$rf" ] || continue
        [ -f "$rf" ] || continue
        RSHA="$RSHA
$rf:$(git hash-object -- "$rf" 2>/dev/null)"
      done <<EOF
$RFILES
EOF
      RSHA=$(printf '%s\n' "$RSHA" | sed '/^$/d')

      if [ -f "$GATE" ]; then read_all_keys; else
        PROBLEM=""; RED=""; VAULT=""; REUSE=""; DEPS=""
      fi
      RED_CMD="$RED_CMD_ARG"; RED_RC="$RCRC"
      RED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      RED_FILES="$(printf '%s' "$RFILES" | tr '\n' ',')"
      RED_SHA="$(printf '%s' "$RSHA" | tr '\n' ',')"

      mkdir -p "$(dirname "$GATE")"
      write_gate test
      NFILES=$(printf '%s\n' "$RFILES" | grep -c .)
      echo "gate: red recorded (exit $RCRC, $NFILES test file(s)):"
      printf '%s\n' "$RFILES" | sed 's/^/  /'
      studio_log_gate gate.sh RED test "$RED_CMD_ARG" "rc=$RCRC files=$NFILES"
    else
      mkdir -p "$(dirname "$GATE")"
      printf '{"phase":"test"}\n' > "$GATE"
      echo "gate: test — source edits are blocked."
    fi
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

    read_all_keys

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

    # Advancing INTO verify RE-RUNS the recorded red command and requires it
    # to pass now, and re-hashes every red_files entry against the sha
    # recorded when it was captured. Freezing those files during CREATE
    # (gate-check.sh) stops a direct edit; this is the other half -- without
    # it, a red test could still be weakened by any WRITE gate-check.sh
    # cannot see edit-by-edit, or simply left unrun, and `advance verify`
    # would take the agent's word that CREATE worked. A record with no
    # red_cmd (an `n/a: <reason>` slice, or an old gate.json from before this
    # existed) has nothing to re-run and is waved through unchanged.
    if [ "$NEXT" = "verify" ] && [ -n "${RED_CMD:-}" ]; then
      VOUT=$(eval "$RED_CMD" 2>&1); VRC=$?
      if [ "$VRC" -ne 0 ]; then
        echo "refusing to advance to verify: the recorded red command still fails" >&2
        echo "  (exit $VRC). CREATE exists to turn it green before VERIFY begins." >&2
        echo "  command: $RED_CMD" >&2
        exit 1
      fi
      if [ -n "${RED_SHA:-}" ]; then
        CHANGED=""
        OLDIFS="$IFS"; IFS=','
        for pair in $RED_SHA; do
          [ -n "$pair" ] || continue
          rf="${pair%%:*}"; wanthash="${pair#*:}"
          if [ ! -f "$rf" ]; then CHANGED="$CHANGED $rf(missing)"; continue; fi
          gothash=$(git hash-object -- "$rf" 2>/dev/null)
          [ "$gothash" = "$wanthash" ] || CHANGED="$CHANGED $rf"
        done
        IFS="$OLDIFS"
        if [ -n "$CHANGED" ]; then
          echo "refusing to advance to verify: the red test file(s) changed since they" >&2
          echo "  were recorded as red evidence -- exactly what freezing them during" >&2
          echo "  CREATE exists to prevent:" >&2
          echo " $CHANGED" >&2
          exit 1
        fi
      fi
      # The re-run just proved this passes now; recording the ORIGINAL
      # failing rc from the TEST phase would make the audit trail claim the
      # test is still red at the moment verify was allowed to start.
      RED_RC="0"
    fi

    write_gate "$NEXT"
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
    RED_GIVEN=0
    # Carry forward any red_cmd record BEFORE parsing flags, so `--red`
    # omitted below can fall back to it, and so a record from an earlier
    # `test --red-cmd` run is never silently dropped by opening the gate.
    if [ -f "$GATE" ]; then
      RED_CMD=$(read_key red_cmd); RED_RC=$(read_key red_rc)
      RED_AT=$(read_key red_at); RED_FILES=$(read_key red_files); RED_SHA=$(read_key red_sha)
    else
      RED_CMD=""; RED_RC=""; RED_AT=""; RED_FILES=""; RED_SHA=""
    fi
    while [ $# -gt 0 ]; do
      case "$1" in
        --problem) shift; PROBLEM="${1:-}" ;;
        --red)     shift; RED="${1:-}"; RED_GIVEN=1 ;;
        --vault)   shift; VAULT="${1:-}" ;;
        --reuse)   shift; REUSE="${1:-}" ;;
        --deps)    shift; DEPS="${1:-}" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown flag: $1" >&2; usage >&2; exit 1 ;;
      esac
      shift
    done

    # --red left unstated falls back to a `test --red-cmd` record, if one is
    # on file and still describes an ACTUAL failure (red_rc non-zero -- a
    # record `advance verify` already re-ran successfully reads red_rc=0 and
    # is stale for opening a NEW gate on). Without a live record, --red must
    # be stated by hand: a free-text CLAIM of a failing test with nothing
    # behind it is exactly what this whole slice exists to stop accepting.
    if [ "$RED_GIVEN" = 0 ] && [ -n "$RED_CMD" ] && [ -n "$RED_RC" ] && [ "$RED_RC" != "0" ]; then
      RED="recorded: \`$RED_CMD\` exited $RED_RC ($RED_AT)"
    fi

    MISSING=""
    [ -z "$PROBLEM" ] && MISSING="--problem"
    [ -z "$RED" ] && MISSING="${MISSING:+$MISSING and }--red"
    if [ -n "$MISSING" ]; then
      echo "refusing to open the gate: $MISSING missing." >&2
      echo "  --problem is the IDEA phase; --red is the TEST phase. Both are one sentence." >&2
      echo "  Record real evidence first, and this fills itself in:" >&2
      echo "    bash .claude/scripts/gate.sh test --red-cmd \"<the failing test command>\"" >&2
      echo "  No failing test to point at? Say so by hand: --red \"n/a: <why>\"" >&2
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
    write_gate "$CMD"
    echo "gate: $CMD — source edits unblocked. Reset at handoff: bash .claude/scripts/gate.sh idle"

    # Which KIND of --red this is, logged once per open/re-open: a real
    # `test --red-cmd` record, an honest "n/a: <reason>", or a free-text
    # sentence typed by hand with nothing behind it. /studio-report reads
    # gate-log.tsv already for the compliance section; without this row the
    # n/a-versus-recorded rate is invisible there, which is the same "a
    # standard nothing measures is a preference" gap this whole slice exists
    # to close, one level up -- for the --red answer itself, not just for
    # whether one was stated.
    case "$RED_GIVEN:$(printf '%s' "$RED" | cut -c1-3 | tr '[:upper:]' '[:lower:]')" in
      0:*)   RED_KIND=red-recorded ;;
      1:n/a) RED_KIND=red-na ;;
      *)     RED_KIND=red-manual ;;
    esac
    studio_log_gate gate.sh OPEN "$CMD" - "$RED_KIND"
    ;;

  -h|--help) usage ;;
  *) echo "unknown command: $CMD" >&2; usage >&2; exit 1 ;;
esac
