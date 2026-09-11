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

studio_guard() {
  local self="$1"
  if grep -q '{{[A-Z_]*}}' "$self" 2>/dev/null; then
    echo "claude-studio: $(basename "$self") has unresolved placeholders." >&2
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

  # Strip the repo root. Compare case-insensitively: the harness sends "c:/..."
  # while `pwd -W` reports "C:/...", and that one-character difference is enough
  # to defeat prefix stripping entirely. ${v,,} is a bash builtin -- this runs
  # on the latency path of every Edit, and on Windows a spawn costs ~120ms, so
  # a tr/grep pipeline here would cost more than the rest of the hook.
  pwd_w=$(pwd -W 2>/dev/null || true)
  for root in "$PWD" "$pwd_w"; do
    [ -n "$root" ] || continue
    root_l=${root//\\//}; root_l=${root_l,,}
    case "${p,,}" in
      "$root_l"/*) p="${p:$(( ${#root_l} + 1 ))}"; break ;;
    esac
  done

  _out="$p"
  return 0
}

# ------------------------------------------------------------- gate decisions
#
# Nothing recorded whether the pipeline was followed, so the only available
# answer was an impression. One append-only TSV turns it into a query:
# blocks trending down means the workflow is being internalised; source edits
# with zero blocks and no plan on record means a bypass nobody has found yet.
# Best-effort by construction -- a logging failure must never affect a verdict.
studio_log_gate() {  # studio_log_gate <hook> <verdict> <phase> <target> [reason]
  [ -d .claude/state ] || return 0
  { printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$4" "${5:-}" \
      >> .claude/state/gate-log.tsv; } 2>/dev/null || true
  return 0
}
