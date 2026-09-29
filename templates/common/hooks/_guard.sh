#!/usr/bin/env bash
# Shared helpers for studio hooks.
#
# Four jobs:
#   1. An UNCONFIGURED hook must be LOUD, never silently inert.
#   2. Read JSON without hard-depending on jq. jq is used when present
#      because it is correct; the fallbacks keep hooks working without it.
#   3. CANONICALISE a path before anything authorises against it. A guard that
#      matches the string the caller typed, rather than the file that string
#      resolves to, is not a guard.
#   4. Record every gate decision, so "is the pipeline followed?" is a query
#      rather than an opinion.

# The vocabulary a test/build/lint/audit runner uses to say "something is
# wrong", as opposed to merely exiting non-zero -- a crash or a syntax error in
# the runner ITSELF is non-zero too, and is not evidence that the test you
# meant to write actually failed. Declared once: filter-output.sh's rewrite
# and gate.sh's `test --red-cmd` both match against this, so the definition of
# "looks like a real failure" cannot drift between the two doors that check it.
STUDIO_ASSERTION_PATTERN='(FAIL|ERROR|Error|error:|✕|✗|✘|✖|^ *[0-9]+:[0-9]+ +(error|warning)|problems? \(|assert|Exception|vulnerabilit|advisor|Timed out|^ *Tests?: |^ *Duration: |\[OK\]|built in |No security vulnerability|[0-9]+ (passed|failed|vulnerabilities))'

# ------------------------------------------------------------- where things are
#
# studio_locate <path-of-calling-script>
#
# Two directories that used to be one:
#   STUDIO_HOME     the directory holding the .claude/ this script lives in --
#                   where state, scripts, skills and the pipeline docs are
#   STUDIO_PROJECT  the codebase the gate guards -- where git runs, tests run,
#                   and every source-root path is relative to
#
# In the ordinary layout they are the same directory. In the EXTERNAL layout
# (install.sh --home DIR, for a repository that may not hold Claude or
# pipeline files) the home is elsewhere and .claude/project-dir names the
# codebase on one line. Also sets STUDIO_STATE, STUDIO_GATE_SEAL,
# STUDIO_EXTERNAL (0/1) and STUDIO_GATE_CMD, the command block messages tell
# the model to run -- which must be the one that works in THIS layout, or the
# model is told to run a script that is not there and the pipeline drifts.
#
# Builtins only: gate-check.sh calls this on every Edit/Write.
studio_locate() {
  local self="${1//\\//}" d
  case "$self" in /*|[A-Za-z]:/*) ;; *) self="${PWD//\\//}/$self" ;; esac
  d="${self%/*}"        # .../.claude/hooks  or  .../.claude/scripts
  d="${d%/*}"           # .../.claude
  STUDIO_HOME="${d%/*}"
  case "$STUDIO_HOME" in "") STUDIO_HOME="/" ;; esac
  STUDIO_PROJECT="$STUDIO_HOME"; STUDIO_EXTERNAL=0
  if [ -f "$STUDIO_HOME/.claude/project-dir" ]; then
    IFS= read -r STUDIO_PROJECT < "$STUDIO_HOME/.claude/project-dir" || true
    STUDIO_PROJECT="${STUDIO_PROJECT%$'\r'}"
    if [ -n "$STUDIO_PROJECT" ]; then STUDIO_EXTERNAL=1; else STUDIO_PROJECT="$STUDIO_HOME"; fi
  fi
  STUDIO_STATE="$STUDIO_HOME/.claude/state"
  STUDIO_GATE_SEAL="$STUDIO_STATE/gate.seal"
}

# studio_gate_phase <gate.json> -- the phase on record, or "idle" when there
# is no file or no phase in it. jq when it works, grep when it does not.
studio_gate_phase() {
  local g="$1" p=""
  [ -f "$g" ] || { printf 'idle'; return; }
  if command -v jq >/dev/null 2>&1; then
    p=$(jq -r '.phase // ""' "$g" 2>/dev/null) || p=""
  fi
  case "$p" in ""|null) p=$(grep -o '"phase"[[:space:]]*:[[:space:]]*"[^"]*"' "$g" 2>/dev/null \
      | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//') || p="" ;;
  esac
  printf '%s' "${p:-idle}"
}

# studio_brief -- the pipeline's standing orders in a few lines, for the
# SessionStart and UserPromptSubmit hooks to put in front of the model.
#
# Why this exists: CLAUDE.md is context, and context drifts. In the external
# layout it is worse -- the pipeline's CLAUDE.md is loaded through --add-dir,
# and nothing promises it is re-read after /compact the way a project-root
# CLAUDE.md is. Reported from the field: the agent followed the pipeline,
# drifted, was told where the files were, followed it again, drifted again.
# A hook's stdout on these two events is added to context every time, so the
# location and the phase stop depending on the model remembering them.
studio_brief() {  # studio_brief <phase>
  local phase="$1" state="blocked"
  [ "$phase" = create ] && state="open"
  printf 'IPTCVD pipeline: gate phase is %s, so source edits are %s. Change the phase only with: %s <phase> ...\n' \
    "$phase" "$state" "$(studio_script_cmd gate.sh)"
  if [ "${STUDIO_EXTERNAL:-0}" = 1 ]; then
    printf 'The pipeline lives OUTSIDE this repository, at %s -- its CLAUDE.md, skills, agents, specs (docs/specs/) and state are there. This repository may not hold Claude or pipeline files: never create .claude/, CLAUDE.md or pipeline docs in it.\n' \
      "$STUDIO_HOME"
  fi
}

# studio_script_cmd <script.sh> -- how to run one of the pipeline's scripts,
# spelled for THIS layout. Every message that tells the model to run a script
# goes through this: a message naming `.claude/scripts/` in a repository that
# has no .claude/ sends the model looking for a file that is not there, which
# is exactly the drift the external layout was reported for.
studio_script_cmd() {
  if [ "${STUDIO_EXTERNAL:-0}" = 1 ]; then
    printf 'bash "%s/.claude/scripts/%s"' "$STUDIO_HOME" "$1"
  else
    printf 'bash .claude/scripts/%s' "$1"
  fi
}

studio_guard() {
  local self="$1"
  if grep -q '{{[A-Z_]*}}' "$self" 2>/dev/null; then
    echo "iptcvd-pipeline: $(basename "$self") has unresolved placeholders." >&2
    echo "  Fill docs/setup/PROFILE.md, then run ./configure.sh" >&2
    return 1
  fi
  return 0
}

# json_field <json> <dotted.path>
# Handles the shallow paths studio hooks need, e.g. tool_input.file_path
#
# Three parsers, in order, and the ORDER IS LOAD-BEARING: whichever branch a
# machine takes is the only one that machine ever exercises, so they have to
# agree byte for byte. The regex branch is last because it is the weakest --
# its escape class must be backslash-then-any and not a literal dot, or any
# value containing a quote or a backslash reads back EMPTY. A hook whose input
# parses to "" exits 0, which turns a guard into decoration while it still
# reports success.
json_field() {
  local json="$1" path="$2" key="${2##*.}" py out

  # Each parser FALLS THROUGH rather than returning unconditionally. A parser
  # that is present but broken -- a jq built against the wrong libc, a python
  # shim that exits 127, an interpreter shadowed by something else on PATH --
  # otherwise hands back an empty string, and every caller here treats empty
  # input as "no file path, nothing to check" and exits 0. That is a guard
  # silently turned into decoration by a dependency it never chose, and it is
  # indistinguishable from a guard that works.
  #
  # The cost is one extra grep when a key is genuinely absent. That is the
  # correct trade for a hook whose failure mode is allowing writes.
  if command -v jq >/dev/null 2>&1; then
    out=$(printf '%s' "$json" | jq -r ".${path} // empty" 2>/dev/null) \
      && [ -n "$out" ] && { printf '%s' "$out"; return; }
  fi
  if py="$(command -v python3 2>/dev/null || command -v python 2>/dev/null)" && [ -n "$py" ]; then
    out=$(printf '%s' "$json" | "$py" -c 'import json,sys
sys.stdout.reconfigure(newline="")   # Windows text mode would turn each \n into \r\n
try:
    d = json.load(sys.stdin)
    for k in sys.argv[1].split("."):
        d = d.get(k, "") if isinstance(d, dict) else ""
    sys.stdout.write(str(d) if d else "")
except Exception:
    pass' "$path" 2>/dev/null) \
      && [ -n "$out" ] && { printf '%s' "$out"; return; }
  fi
  printf '%s' "$json" \
    | tr -d '\n' \
    | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"\(\\\\.\|[^\"\\\\]\)*\"" \
    | head -1 \
    | sed 's/^"[^"]*"[[:space:]]*:[[:space:]]*"//; s/"$//; s/\\"/"/g'
}

# json_escape <string>  -> a JSON string body (no surrounding quotes)
json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037'
}

# ---------------------------------------------------------------- path canon
#
# Claude Code sends an ABSOLUTE file_path, and on Windows it arrives
# backslash-separated. Every source-root pattern a hook can be configured with
# is anchored at ^, so without this step the gate matches NOTHING on a real
# edit and fails open on exactly the files it exists to guard. That shape was
# measured: six of seven path spellings walked past a closed gate, including
# the plain absolute path that every single Edit call actually uses.
#
# Each of these was verified defeating a ^-anchored root match:
#
#   /home/u/proj/src/x.ts      absolute -- what the harness really sends
#   C:\Users\u\proj\src\x.ts   absolute, Windows
#   ./src/x.ts                 leading ./
#   docs/../src/x.ts           an ALLOW rule used as a prefix to reach source
#   SRC/x.ts                   case, and on Windows this IS src/x.ts
#
# Normalise, then authorise. CWE-22 (traversal) and CWE-178 (case).

# studio_canon <value> -- resolve . and .. segments, result in $STUDIO_CANON.
#
# Value in, global out, deliberately: an earlier version took a nameref and was
# called through a SECOND nameref from studio_normalise_path. Namerefs do not
# chain the way that reads, and the silent result was a path with every
# separator stripped -- which matched no rule at all and therefore allowed
# everything. A guard must not have a clever calling convention.
#
# read -ra splits on IFS and does NOT glob, which plain $(...) word-splitting
# would: a path containing * must not expand against the working tree.
studio_canon() {
  local rest="$1" pfx="" seg out="" oldIFS
  local -a parts=()
  case "$rest" in [A-Za-z]:/*) pfx="${rest%%:*}:"; rest="${rest#*:}" ;; esac
  oldIFS="$IFS"; IFS=/ read -ra parts <<< "$rest"; IFS="$oldIFS"
  for seg in "${parts[@]}"; do
    case "$seg" in
      ""|.) continue ;;
      ..)   out="${out%/*}" ;;
      *)    out="$out/$seg" ;;
    esac
  done
  STUDIO_CANON="$pfx$out"
}

# A lexical canon cannot see a SYMLINK. `docs/link/x.ts`, where docs/link ->
# src/, reads as docs/ (an allow rule) but writes into a guarded root: the same
# allowlist-as-vector shape as `..`, one indirection further out. Resolving
# every path with realpath would put a process spawn on every edit; DETECTING
# one is free, because [ -L ] is a shell builtin. So a spawn is paid only when
# a symlink is genuinely in the path, which in a normal tree is never.
studio_has_symlink_ancestor() {
  local probe="$1"
  while [ -n "$probe" ]; do
    [ -L "$probe" ] && return 0
    case "$probe" in
      */*) probe="${probe%/*}" ;;
      *)   break ;;
    esac
    case "$probe" in ""|[A-Za-z]:) break ;; esac
  done
  return 1
}

# studio_normalise_path <varname>
# Absolute-or-relative, any slash style -> repo-relative POSIX where possible.
# Returns 1 only when a symlink is present and cannot be resolved; the caller
# must treat that as a refusal, never as a pass.
#
# ONE nameref, assigned once at the end. Everything in between is a plain
# local -- see the note on studio_canon for why that matters.
#
# Sets the GLOBAL $STUDIO_ROOT as a side effect -- the directory the path was
# stripped relative to, forward-slash form. A caller that needs to read or
# write THIS FILE's gate (gate-check.sh, deciding where .claude/state/
# gate.json lives) reads it back afterward, so an edit inside a worktree is
# judged by the worktree's own gate, not the main checkout's.
studio_normalise_path() {
  local -n _out=$1
  local p resolved root root_l pwd_w
  p=${_out//\\//}

  # Relative paths are repo-relative (hooks run with cwd at the repo root), so
  # absolutise before resolving `..` -- otherwise `../<repo>/src/x` cannot be
  # reasoned about at all. $PWD is a bash variable: no subshell.
  case "$p" in
    /*|[A-Za-z]:/*) ;;
    *) p="${PWD//\\//}/$p" ;;
  esac
  studio_canon "$p"; p="$STUDIO_CANON"

  if studio_has_symlink_ancestor "$p"; then
    resolved=$(realpath -m -- "$p" 2>/dev/null) \
      || resolved=$(readlink -f -- "$p" 2>/dev/null) || resolved=""
    [ -n "$resolved" ] || return 1
    p=${resolved//\\//}
    studio_canon "$p"; p="$STUDIO_CANON"
  fi

  # The ROOT to strip is the nearest ancestor directory carrying its OWN
  # .claude/state/gate.json, not necessarily $PWD -- see studio_find_root.
  # Falls back to the ORIGINAL $PWD/`pwd -W` matching when no gate.json
  # exists anywhere up the tree (pre-configuration, or a repo layout this
  # cannot see), so an unconfigured install behaves exactly as it did before
  # this existed. Compared case-insensitively either way: the harness sends
  # "c:/..." while `pwd -W` reports "C:/...", and that one-character
  # difference is enough to defeat prefix stripping entirely. ${v,,} is a
  # bash builtin -- this runs on the latency path of every Edit, and on
  # Windows a spawn costs ~120ms, so a tr/grep pipeline here would cost more
  # than the rest of the hook.
  studio_find_root "$p"
  if [ -n "$STUDIO_ROOT" ]; then
    root_l=${STUDIO_ROOT,,}
    case "${p,,}" in "$root_l"/*) p="${p:$(( ${#STUDIO_ROOT} + 1 ))}" ;; esac
  else
    pwd_w=$(pwd -W 2>/dev/null || true)
    # The PROJECT first: in the external layout the hook's cwd is the
    # codebase too, but a Bash `cd` must not change what a path is relative to.
    for root in "${STUDIO_PROJECT:-}" "$PWD" "$pwd_w"; do
      [ -n "$root" ] || continue
      root_l=${root//\\//}; root_l=${root_l,,}
      case "${p,,}" in
        "$root_l"/*) p="${p:$(( ${#root_l} + 1 ))}"; STUDIO_ROOT="$root_l"; break ;;
      esac
    done
  fi

  _out="$p"
  return 0
}

# studio_find_root <abs-canonical-path>
#
# Sets the global $STUDIO_ROOT to the directory of the nearest ancestor
# carrying its OWN .claude/state/gate.json, walking UP from the file's
# directory -- so a worktree's own gate is found before the main checkout's,
# since the walk reaches the worktree root first. Sets $STUDIO_ROOT="" if
# none exists anywhere up to the filesystem root; the caller then falls back
# to $PWD, exactly as this behaved before worktrees were considered at all.
#
# Builtins only -- no spawn -- because this runs on the Edit/Write hot path
# alongside studio_normalise_path, which is the only caller.
studio_find_root() {
  local p="$1" d
  case "$p" in */*) d="${p%/*}" ;; *) d="." ;; esac
  [ -n "$d" ] || d="/"
  while :; do
    if [ -f "$d/.claude/state/gate.json" ]; then STUDIO_ROOT="$d"; return 0; fi
    # A LINKED WORKTREE with no gate.json of its own is still its own root.
    # Walking past it lands on the main checkout, the path strips to
    # `.worktrees/feat/src/x.ts`, and `^src/` never matches it -- measured
    # walking through a closed gate. Stopping here instead points $GATE at a
    # file that does not exist, which blocks: the fail-closed direction.
    # Only a worktree's `.git` FILE counts ("gitdir: .../worktrees/<name>"); a
    # submodule's says ".../modules/<name>" and is left to the walk, so a
    # submodule under a source root stays guarded by the outer checkout.
    # `read` from a redirect is a builtin, and runs only when a .git file exists.
    if [ -f "$d/.git" ]; then
      local gitdir_line=""
      IFS= read -r gitdir_line < "$d/.git" 2>/dev/null || true
      case "$gitdir_line" in
        gitdir:*/worktrees/*) STUDIO_ROOT="$d"; return 0 ;;
      esac
    fi
    case "$d" in
      /|[A-Za-z]:) break ;;                       # filesystem root or bare drive: nothing higher
      */*) d="${d%/*}"; [ -n "$d" ] || d="/" ;;
      *) break ;;                                  # no separator left to strip -- give up
    esac
  done
  STUDIO_ROOT=""
}

# ------------------------------------------------------------- the gate seal
#
# Edit/Write and every shell shape bash-gate.sh knows are refused on
# gate.json, but an interpreter writing it -- `python -c "open(...)"` -- is not
# a shape any parser sees. gate.sh records the checksum of every gate.json it
# writes; bash-audit.sh restores any gate.json a Bash call changed to content
# that is neither sealed nor the committed HEAD version. One definition, so the
# writer and the checker cannot hash differently.
#
# cksum, not git hash-object: gate.sh must seal in a directory that is not a
# git repository, and a seal that silently failed to write would make the
# audit revert gate.sh's own legitimate write.
STUDIO_GATE_SEAL="${STUDIO_GATE_SEAL:-.claude/state/gate.seal}"   # studio_locate sets the real one
studio_gate_sum() { cksum < "$1" 2>/dev/null | cut -d' ' -f1-2; }

# ------------------------------------------------------------- gate decisions
#
# Nothing recorded whether the pipeline was followed, so the only available
# answer was an impression. One append-only TSV turns it into a query:
# blocks trending down means the workflow is being internalised; source edits
# with zero blocks and no plan on record means a bypass nobody has found yet.
# Best-effort by construction -- a logging failure must never affect a verdict.
studio_log_gate() {  # studio_log_gate <hook> <verdict> <phase> <target> [reason]
  # $STUDIO_ROOT, when set by a prior studio_normalise_path call, is the
  # worktree (or main checkout) the DECISION was actually made for -- the
  # log lives beside the gate.json that produced it, not always beside $PWD's.
  # $STUDIO_LOG_STATE, when a caller sets it, is the state directory of the
  # gate that actually decided -- the home's, in the external layout.
  local dir="${STUDIO_LOG_STATE:-${STUDIO_ROOT:-.}/.claude/state}"
  [ -d "$dir" ] || return 0
  { printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$4" "${5:-}" \
      >> "$dir/gate-log.tsv"; } 2>/dev/null || true
  return 0
}

# ------------------------------------------------------------ content floors
#
# `{"phase":"create","problem":"x","red":"x","reuse":"x"}`, written by hand,
# used to open the gate: gate-check.sh checked only that problem/red were
# NON-EMPTY, while gate.sh's own `create` command refused the identical
# one-character values. Two implementations of "the plan says something" that
# happened to agree until somebody wrote gate.json directly, which is the
# ordinary shape of the bypass the reuse and dependency gates exist to name --
# except this time it was the CONTENT check itself with two doors.
#
# One function, called from both, so there is exactly one floor to change.
#
# studio_validate_notes <problem> <red> [reuse] [deps]
#
# Checks problem, then red, then reuse and deps (only if non-empty -- an
# absent reuse/deps is a PRESENCE question the caller already asks
# separately; this only judges a value that was actually supplied). Prints
# the reason for the FIRST failing floor to stderr and returns 1. Returns 0
# and sets STUDIO_INVALID_KEY="" when every supplied note clears its floor.
#
# Builtins only -- ${v//[[:space:]]/} and ${v,,}, no `tr`, no pipe -- because
# gate-check.sh calls this on every guarded Edit/Write. The original _dense in
# gate.sh piped through `tr`, which is fine for a CLI invoked a few times a
# session and would be one more spawn per edit here.
studio_validate_notes() {
  local problem="$1" red="$2" reuse="${3:-}" deps="${4:-}" dense name val

  dense="${problem//[[:space:]]/}"
  if [ ${#dense} -lt 12 ]; then
    STUDIO_INVALID_KEY="problem"
    echo "invalid problem: ${#dense} characters of content (need at least 12)." >&2
    echo "  The IDEA phase is what BREAKS and what is out of scope -- a sentence, not a token." >&2
    return 1
  fi

  case "${red,,}" in
    n/a*)
      local reason="${red#*:}"
      [ "$reason" = "$red" ] && reason=""   # no colon at all
      dense="${reason//[[:space:]]/}"
      if [ ${#dense} -lt 8 ]; then
        STUDIO_INVALID_KEY="red"
        echo 'invalid red: "n/a" without a reason is not an answer.' >&2
        echo '  Use: "n/a: <why this change has no failing test to point at>"' >&2
        return 1
      fi
      ;;
    *)
      dense="${red//[[:space:]]/}"
      if [ ${#dense} -lt 12 ]; then
        STUDIO_INVALID_KEY="red"
        echo "invalid red: ${#dense} characters of content (need at least 12, or \"n/a: <why>\")." >&2
        echo '  The TEST phase names the test that fails NOW, or says "n/a: <why>".' >&2
        return 1
      fi
      ;;
  esac

  for name in reuse deps; do
    val="${!name}"
    [ -n "$val" ] || continue
    dense="${val//[[:space:]]/}"
    if [ ${#dense} -lt 12 ]; then
      STUDIO_INVALID_KEY="$name"
      echo "invalid $name: ${#dense} characters of content (need at least 12)." >&2
      echo "  Name what you checked first and why it does not cover this." >&2
      return 1
    fi
  done

  STUDIO_INVALID_KEY=""
  return 0
}
