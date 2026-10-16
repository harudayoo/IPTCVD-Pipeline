#!/usr/bin/env bash
#
# IPTCVD Pipeline configure
#
# Reads docs/setup/PROFILE.md (which YOU have confirmed by running each
# command) and substitutes the placeholders left behind by install.sh.
#
# Refuses to run if the profile still contains NEEDS_REVIEW. That refusal is
# the point: a half-configured hook that silently matches nothing is worse
# than no hook at all.
#
# Tier-aware: which pieces get pruned on a project with no UI comes from the
# installed tier's manifest, not from a list hardcoded here.
#
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$(pwd)"
DRY_RUN=0
ALLOW_INCOMPLETE=0

c_red() { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn() { printf '\033[32m%s\033[0m\n' "$*"; }
c_yel() { printf '\033[33m%s\033[0m\n' "$*"; }
c_dim() { printf '\033[2m%s\033[0m\n' "$*"; }
die()   { c_red "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --target|--home) TARGET="$(cd "$2" && pwd)"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --allow-incomplete) ALLOW_INCOMPLETE=1; shift ;;
    -h|--help)
      echo "usage: ./configure.sh [--target DIR] [--dry-run] [--allow-incomplete]"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

# TARGET is where the pipeline lives. PROJECT is the codebase it guards: the
# same directory, unless install.sh --home put the pipeline outside the
# repository and recorded the codebase in .claude/project-dir. Every check
# about source roots, test roots and tracked code runs against PROJECT.
PROJECT="$TARGET"
if [ -f "$TARGET/.claude/project-dir" ]; then
  IFS= read -r PROJECT < "$TARGET/.claude/project-dir" || true
  PROJECT="${PROJECT%$'\r'}"
  [ -d "$PROJECT" ] || die "the project recorded in .claude/project-dir does not exist: $PROJECT"
fi

P="$TARGET/docs/setup/PROFILE.md"
[ -f "$P" ] || die "no profile at docs/setup/PROFILE.md — run install.sh first"

# ------------------------------------------------------------- installed tier
STUDIO_STATE="$TARGET/.claude/state/studio.json"
read_tier() {
  [ -f "$STUDIO_STATE" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r '.tier // empty' "$STUDIO_STATE" 2>/dev/null
  else
    tr -d '\n' < "$STUDIO_STATE" \
      | grep -o '"tier"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//'
  fi
}

PLAN="$(read_tier || true)"
if [ -z "$PLAN" ] || [ ! -f "$SRC/templates/tiers/$PLAN/manifest.conf" ]; then
  c_yel "warning: cannot read the installed tier from .claude/state/studio.json."
  c_dim "  Falling back to the Pro manifest for UI pruning. Re-run install.sh to fix."
  PLAN="pro"
fi
# shellcheck source=/dev/null
. "$SRC/templates/tiers/$PLAN/manifest.conf"

if grep -q 'NEEDS_REVIEW' "$P" && [ "$ALLOW_INCOMPLETE" = 0 ]; then
  c_red "PROFILE.md still contains NEEDS_REVIEW:"
  grep -n 'NEEDS_REVIEW' "$P" | sed 's/^/  /'
  echo
  c_dim "Fill these in and run every command to confirm it works, then re-run."
  c_dim "To proceed anyway (hooks will stay inert and warn): --allow-incomplete"
  exit 1
fi

# A markdown table cell cannot contain a `|`. The parser below splits on it, so
# a value like `vitest run | tee out.txt` silently becomes `vitest run` -- the
# profile says one thing, the hook is configured with another, and nothing
# reports a problem. That is the precise failure shape this pipeline exists to
# remove, sitting in the file every hook is configured FROM.
#
# So: detect the extra cell and refuse. A well-formed row is
# `| label | value | status |`, which awk -F'|' sees as 5 fields (the empty
# strings either side of the leading and trailing pipes count).
check_row_shape() {
  awk -F'|' -v want="$1" '
    $0 ~ /^\|/ {
      lbl = $2; gsub(/^[ 	]+|[ 	]+$/, "", lbl)
      if (lbl == want && NF > 5) {
        printf "%s", $0
        exit 1
      }
    }' "$P" && return 0
  return 1
}

# Pull a value out of the profile's markdown table by row label.
field() {
  local label="$1"
  awk -F'|' -v want="$label" '
    $0 ~ /^\|/ {
      gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $3)
      gsub(/`/, "", $3)
      if ($2 == want) { print $3; exit }
    }' "$P"
}

PROJECT_NAME="$(field 'Project name')"
STACK_LINE="$(field 'Stack')"
DEV_COMMAND="$(field 'Dev command')"
TEST_COMMAND="$(field 'Test command (non-watching)')"
SINGLE_TEST_COMMAND="$(field 'Single-test command')"
FORMAT_COMMAND="$(field 'Format command (fixes)')"
TYPECHECK_COMMAND="$(field 'Type-check command')"
BUILD_COMMAND="$(field 'Build command')"
DEPENDENCY_AUDIT_COMMAND="$(field 'Dependency audit command')"
SOURCE_ROOTS="$(field 'Source roots')"
FRONTEND_ROOT="$(field 'Front-end root')"
TEST_ROOT="$(field 'Test root')"
SHARED_SURFACES="$(field 'Shared surfaces')"
EXTRA_TEST_PATTERNS_RAW="$(field 'Extra test patterns')"
TOKEN_FILE="$(field 'Design token file')"
HAS_UI="$(field 'Has UI')"

# Normalise backslashes to forward slashes BEFORE anything treats these as
# directory names. Tested: "WebCoreApi\Website" passed the validation below
# unchanged and compiled into "^(WebCoreApi\Website)/" -- an UNESCAPED
# backslash in an ERE either errors or eats the character after it, so the
# root matched nothing and was silently unguarded. Every affected field is a
# comma-separated list of repo-relative paths, so a global backslash-to-slash
# swap is safe: nothing legitimate in any of them needs one.
SOURCE_ROOTS=$(printf '%s' "$SOURCE_ROOTS" | tr '\\' '/')
FRONTEND_ROOT=$(printf '%s' "$FRONTEND_ROOT" | tr '\\' '/')
TEST_ROOT=$(printf '%s' "$TEST_ROOT" | tr '\\' '/')
SHARED_SURFACES=$(printf '%s' "$SHARED_SURFACES" | tr '\\' '/')

[ -n "$TEST_COMMAND" ]  || die "could not read 'Test command' from the profile"

# Refuse a row whose value contains a pipe BEFORE anything is substituted.
for _lbl in "Dev command" "Test command (non-watching)" "Single-test command"             "Format command (fixes)" "Type-check command" "Build command"             "Dependency audit command" "Source roots" "Front-end root" "Test root"             "Shared surfaces" "Extra test patterns" "Design token file"; do
  if _row=$(check_row_shape "$_lbl"); then :; else
    c_red "error: the '$_lbl' row has more cells than a markdown table row can hold."
    c_dim "  row: $_row"
    c_dim "  A '|' inside the value splits the cell, so the value is silently truncated"
    c_dim "  at the pipe and the hook is configured with something you did not write."
    c_dim "  Put the pipeline into a script and name the script here instead."
    exit 1
  fi
done


# ---------------------------------------------------- profile value validation
#
# Profile values are substituted into hook SOURCE, and they land in two shapes
# that fail differently:
#
#   EXECUTED   post-edit.sh runs `{{FORMAT_COMMAND}} "$FILE"` on every edit. The
#              value is shell, unquoted -- it has to be, or a two-word command
#              like `npx prettier -w` could not work. So a `;` or a `$(...)` in
#              that field is a second command running on every single edit.
#
#   MATCHED    filter-output.sh puts commands inside `case` PATTERNS. A `)` or a
#              `|` there does not inject anything -- it ends the pattern early
#              and leaves the file syntactically broken, so the hook dies on
#              every Bash call and the harness reports a hook error rather than
#              anything about the actual problem.
#
# PROFILE.md is the project owner's own file, confirmed by running each command,
# so this is not a defence against an attacker who already has commit access.
# It is a defence against a paste, a stray character, and a hook that silently
# becomes a syntax error -- which, in a pipeline whose entire claim is that its
# gates are deterministic, is the expensive failure.
# A `case` pattern cannot come from a VARIABLE. Bash expands $pat and then
# treats the result as a single pattern -- the `|` inside it is an ordinary
# character, not alternation, so a helper taking the pattern as an argument
# silently matched nothing. It was doing that while eight test cases reported
# PASS, because a separate bug was rejecting every value for another reason.
# Two wrongs cancelling out is the worst shape a green suite can have, so the
# patterns below are written literally, once per field.
_die_val() {  # _die_val <label> <value> <what is wrong>
  c_red "error: '$1' contains $3."
  c_dim "  value: $2"
  c_dim "  Profile values are substituted into hook SOURCE, so this would leave the"
  c_dim "  hooks broken, or running something you did not intend, on every edit."
  c_dim "  Use a plain command; put any chaining into a script and name the script."
  exit 1
}

# EXECUTED: post-edit.sh runs `<format command> "$FILE"` on every edit, unquoted
# -- it has to be, or a two-word command like `npx prettier -w` could not work.
# A `;`, a backtick or a `$(...)` in that field is a second command running on
# every single edit.
for _pair in "Format command (fixes)|$FORMAT_COMMAND" "Type-check command|$TYPECHECK_COMMAND"; do
  _label="${_pair%%|*}"; _val="${_pair#*|}"
  case "$_val" in ""|NEEDS_REVIEW|true) continue ;; esac
  case "$_val" in
    *[\;\|\&\<\>]*|*'`'*|*'$('*)
      _die_val "$_label" "$_val" "a shell metacharacter: one of ; | & backtick dollar-paren < >" ;;
  esac
done

# MATCHED: filter-output.sh puts these inside `case` PATTERNS. A `)` or a bare
# `|` there injects nothing -- it ends the pattern early and leaves the hook
# syntactically broken, so it dies on every Bash call and the harness reports a
# hook error instead of anything about the real problem.
#
# `&&` stays legal: install.sh legitimately builds "composer audit && npm audit",
# and an ampersand inside a case pattern is an ordinary literal.
for _pair in "Test command (non-watching)|$TEST_COMMAND" "Build command|$BUILD_COMMAND" \
             "Dependency audit command|$DEPENDENCY_AUDIT_COMMAND" \
             "Extra test patterns|$EXTRA_TEST_PATTERNS_RAW"; do
  _label="${_pair%%|*}"; _val="${_pair#*|}"
  case "$_val" in ""|NEEDS_REVIEW|true|n/a) continue ;; esac
  case "$_val" in
    *'('*|*')'*|*\\*)
      _die_val "$_label" "$_val" "a parenthesis or a backslash, which breaks a case pattern" ;;
  esac
  # A lone `|` breaks the pattern; `||` is shell chaining and is no better here.
  # "Extra test patterns" is comma-separated and joined with `|` by configure.sh
  # ITSELF when building the substitution -- a `|` typed by hand here would
  # double up and end the pattern early either way.
  case "$_val" in
    *'|'*) _die_val "$_label" "$_val" "a pipe, which ends the case pattern early" ;;
  esac
done

# A newline in any of them corrupts the file outright, whichever shape it takes.
#
# $'\n', NOT "$(printf '\n')". Command substitution strips trailing newlines,
# so the latter evaluates to the EMPTY STRING and the guard becomes
# `case $v in **)` -- which matches every value there is. The first version of
# this check rejected every legitimate profile in the repo while reporting a
# precise, confident reason ("contains a line break"). A guard that is wrong in
# the fail-closed direction is still wrong: this one made configure.sh unusable
# on a correct profile, which is how a check gets deleted rather than fixed.
_NL=$'\n'; _CR=$'\r'
for _pair in "Format command (fixes)|$FORMAT_COMMAND" "Type-check command|$TYPECHECK_COMMAND" \
             "Test command (non-watching)|$TEST_COMMAND" "Build command|$BUILD_COMMAND" \
             "Dependency audit command|$DEPENDENCY_AUDIT_COMMAND" "Source roots|$SOURCE_ROOTS" \
             "Test root|$TEST_ROOT" "Shared surfaces|$SHARED_SURFACES" \
             "Extra test patterns|$EXTRA_TEST_PATTERNS_RAW"; do
  _label="${_pair%%|*}"; _val="${_pair#*|}"
  case "$_val" in
    *"$_NL"*|*"$_CR"*)
      c_red "error: '$_label' contains a line break."
      exit 1 ;;
  esac
done

# Path-ish fields must be paths, not free-form globs or traversals: they are
# anchored into the gate's own regexes, and a `..` there would widen the guard
# rather than narrow it.
#
# ONE wildcard is allowed: `*` as a WHOLE path segment (`packages/*/src`,
# `apps/*`, `services/*/app`). Monorepos and opinionated layouts put the same
# kind of code one directory down in every package, and refusing that left
# them with two bad choices -- list every package by hand and fall out of date
# the day one is added, or guard the whole `packages/` tree including its
# configs. A whole-segment `*` compiles to `[^/]+`: exactly one directory name,
# never a slash, so it cannot reach across a boundary. Partial segments
# (`src*`), `**`, `?`, and a bare `*` are still refused -- each of those is a
# pattern whose reach you cannot read off the profile.
_bad_path_list() {  # _bad_path_list <value> -> prints the reason, returns 0 if bad
  local v="$1" e s
  case "$v" in *..*|*'?'*|/*|*'**'*) echo "'..', '?', '**' or a leading '/'"; return 0 ;; esac
  local OLDIFS="$IFS"; IFS=','
  for e in $v; do
    e="${e//[[:space:]]/}"
    [ -n "$e" ] || continue
    [ "$e" = '*' ] && { IFS="$OLDIFS"; echo "a bare '*' (that is the whole repository)"; return 0; }
    IFS='/'
    for s in $e; do
      case "$s" in *'*'*) [ "$s" = '*' ] || { IFS="$OLDIFS"; echo "a partial-segment wildcard ('$s')"; return 0; } ;; esac
    done
    IFS=','
  done
  IFS="$OLDIFS"
  return 1
}
set -f   # the values below are patterns to validate, never globs to expand here
for _pair in "Source roots|$SOURCE_ROOTS" "Test root|$TEST_ROOT" "Shared surfaces|$SHARED_SURFACES"; do
  _label="${_pair%%|*}"; _val="${_pair#*|}"
  case "$_val" in ""|NEEDS_REVIEW|n/a) continue ;; esac
  if _why=$(_bad_path_list "$_val"); then
    set +f
    c_red "error: '$_label' must be repo-relative directories, comma-separated."
    c_dim "  value: $_val"
    c_dim "  contains $_why."
    c_dim "  Allowed: plain paths (src, app/Http) and '*' as a whole segment"
    c_dim "  (packages/*/src). These compile into the gate's path patterns, where a"
    c_dim "  wildcard you cannot read the reach of widens the gate in ways nobody chose."
    exit 1
  fi
done
set +f


[ -n "$SOURCE_ROOTS" ]  || die "could not read 'Source roots' from the profile"

# ERE-escape ONE path segment. Tested: a root of "Web.Api" compiled unescaped
# into "^(Web.Api)/", where the bare "." matches ANY character -- so it also
# matched "WebXApi", "Web Api", or any other single-character substitution,
# silently WIDENING the guard rather than narrowing it. A directory name is
# not a pattern; every regex metacharacter in it must mean itself.
_ere_escape() { printf '%s' "$1" | sed 's/[][\.^$*+?(){}|]/\\&/g'; }

# A profile path -> its ERE. Segment by segment: a whole-segment `*` becomes
# `[^/]+` (one directory name, never a slash); every other segment is
# _ere_escape'd so its characters mean themselves.
_path_ere() {
  local out="" seg OLDIFS="$IFS"
  set -f; IFS='/'
  for seg in $1; do
    [ -n "$seg" ] || continue
    if [ "$seg" = '*' ]; then seg='[^/]+'; else seg="$(_ere_escape "$seg")"; fi
    out="${out:+$out/}$seg"
  done
  IFS="$OLDIFS"; set +f
  printf '%s' "$out"
}

# Does a profile path (possibly with `*` segments) name at least one directory?
_path_exists() {
  ( set +f; shopt -s nullglob; set -- "$PROJECT"/$1
    for _d in "$@"; do [ -d "$_d" ] && exit 0; done; exit 1 )
}

# Source roots -> an ERE the hooks can grep with:  "app,src"  ->  "^(app|src)(/|$)"
#
# (/|$) rather than a bare trailing /: a BARE root target -- `cp /tmp/a.ts src`,
# which copies INTO the directory named `src`, or a bash-gate delegation whose
# target collapsed to exactly "src" with nothing after it -- named the root
# with no trailing slash at all, and "^(src)/" matched none of it. Measured:
# `cp /tmp/a.ts src` walked straight past a closed gate under the old pattern.
#
# Built segment by segment through _ere_escape, not a blind tr/join: a raw
# `tr ',' '|'` interpolates each root's own text directly into the regex, so
# any metacharacter IN the name (., +, (, a stray |) changes what the pattern
# matches instead of naming the directory literally.
SOURCE_ROOTS_ESC=""
_ROOTS_PRESENT=0
OLDIFS="$IFS"; IFS=','
for _r in $SOURCE_ROOTS; do
  _r="$(printf '%s' "$_r" | tr -d ' ')"
  [ -n "$_r" ] || continue
  if _path_exists "$_r"; then
    _ROOTS_PRESENT=1
  else
    c_yel "  warning: declared source root '$_r' does not exist as a directory under $PROJECT."
  fi
  SOURCE_ROOTS_ESC="${SOURCE_ROOTS_ESC:+$SOURCE_ROOTS_ESC|}$(_path_ere "$_r")"
done
IFS="$OLDIFS"
SOURCE_ROOTS_REGEX="^($SOURCE_ROOTS_ESC)(/|$)"

# NONE of the declared roots exists: the gate would guard nothing, and every
# check verify.sh runs would still pass, because each one probes a path under
# a declared root. Seen in the field: a .NET repo (WebSite/, SQLScripts/,
# Reports/) configured with "src,app,lib" -- installed, "verified", and inert.
# One missing root among real ones stays a warning above; all of them missing
# is a profile describing some other repository.
if [ "$_ROOTS_PRESENT" = 0 ]; then
  c_red "error: none of the declared source roots ($SOURCE_ROOTS) exists under $PROJECT."
  c_dim "  The gate would guard nothing here while every check reports success."
  c_dim "  Set 'Source roots' in docs/setup/PROFILE.md to the directories that hold"
  c_dim "  this project's code. For a project with no code yet, create the directory"
  c_dim "  first."
  exit 1
fi

# Tracked code that NO declared root covers is ungated, and nothing else says
# so. Listed, not refused: a tooling or scripts directory can be left out on
# purpose, but it should be a decision rather than something nobody noticed.
# From `git ls-files`, so ignored and vendored trees never show up here.
#
# Judged per FILE against the compiled pattern -- the same one the gate uses --
# not by comparing directory names. A name comparison could not see that
# `packages/*/src` leaves `packages/web/scripts/` unguarded, and could not
# credit `*/src` with anything. A directory that is partly covered is reported
# one level deeper (`packages/web`), which is where the decision is made.
_CODE_EXT='\.(ts|tsx|js|jsx|mjs|cjs|vue|svelte|py|go|rs|php|rb|java|kt|kts|scala|cs|vb|fs|cshtml|razor|aspx|ascx|swift|c|cc|cpp|h|hpp|sql|dart|ex|exs|erl|clj|lua)$'
_UNCOVERED=""
if git -C "$PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  _UNCOVERED=$(git -C "$PROJECT" -c core.quotePath=false ls-files 2>/dev/null \
    | grep -iE "$_CODE_EXT" | grep / \
    | grep -vE '(^|/)(\.[^/]*|docs|node_modules|vendor|dist|build|out|bin|obj|coverage|test|tests|spec|__tests__|__mocks__|fixtures)/' \
    | RE="$SOURCE_ROOTS_REGEX" awk '
        # ENVIRON, not -v: -v processes backslash escapes, which would turn an
        # escaped `Web\.Api` back into a `.` that matches any character.
        BEGIN { lre = tolower(ENVIRON["RE"]) }
        { lc = tolower($0)
          split($0, p, "/")
          if (lc ~ lre) { covered[p[1]] = 1 } else { miss[NR] = $0 } }
        END {
          for (i in miss) {
            n = split(miss[i], p, "/")
            key = (p[1] in covered && n > 2) ? p[1] "/" p[2] : p[1]
            seen[key] = 1
          }
          for (k in seen) print k
        }' | LC_ALL=C sort | paste -sd, - | sed 's/,/, /g') || _UNCOVERED=""
fi
if [ -n "$_UNCOVERED" ]; then
  c_yel "  warning: code under these top-level directories is NOT guarded by the gate:"
  c_yel "    $_UNCOVERED"
  c_dim "    Add them to 'Source roots' in docs/setup/PROFILE.md, or leave them out on"
  c_dim "    purpose. Edits there skip the plan/test phases entirely."
fi

# Shared surfaces -> an ERE the gate can grep with:
#   "src/components,src/services"  ->  "^(src/components|src/services)/"
#
# Creating a file under one of these has to state what it reuses. Editing an
# existing file never does. An empty value switches the reuse gate off, and the
# hook treats an empty pattern as "no shared surfaces" rather than as "match
# everything" -- an unset guard that matched everything would block the whole
# project and get itself deleted within the hour.
# A TEST ROOT that sits INSIDE a source root is a gate that disables itself.
# `Test root: src` with `Source roots: src` makes the allow rule match every
# file under src/, so the phase gate never fires on anything -- and the install
# still reports success, which is the exact failure mode this repo exists to
# remove. Drop the location rule when it collides and say so; test FILES are
# still recognised by the shape of their name, so the TEST phase keeps working.
#
# Test roots are a LIST now (`tests, packages/*/tests`): a monorepo has one per
# package, and a Maven/Gradle tree keeps them at `src/test` beside `src/main`.
# Each entry is checked on its own, so one colliding entry is dropped without
# taking the others with it. The collision test runs the entry through the
# SAME compiled source-root pattern the gate uses, case-insensitively -- the
# guard is case-folded, so an allow rule that only collides in another case
# still collides.
case "$TEST_ROOT" in NEEDS_REVIEW|n/a) TEST_ROOT="" ;; esac
_KEPT_TESTS=""; TEST_ROOTS_ESC=""
OLDIFS="$IFS"; IFS=','; set -f
for _t in $TEST_ROOT; do
  IFS="$OLDIFS"
  _t="${_t//[[:space:]]/}"; _t="${_t%/}"
  [ -n "$_t" ] || { IFS=','; continue; }
  if printf '%s/x\n' "$_t" | grep -qiE "$SOURCE_ROOTS_REGEX"; then
    c_yel "  warning: test root '$_t' is inside a source root ($SOURCE_ROOTS)."
    c_dim "    A location-based allow rule there would ungate the whole root, so it"
    c_dim "    is dropped. Test files are still matched by filename (*_test.*,"
    c_dim "    *.test.*, *.spec.*, test_*), which is what Go/Rust/JS layouts need."
    c_dim "    For src/main + src/test layouts, declare 'src/main' as the source root."
    IFS=','; continue
  fi
  set +f
  _path_exists "$_t" || c_yel "  warning: declared test root '$_t' does not exist as a directory under $PROJECT."
  set -f
  _KEPT_TESTS="${_KEPT_TESTS:+$_KEPT_TESTS, }$_t"
  TEST_ROOTS_ESC="${TEST_ROOTS_ESC:+$TEST_ROOTS_ESC|}$(_path_ere "$_t")"
  IFS=','
done
IFS="$OLDIFS"; set +f
TEST_ROOT="$_KEPT_TESTS"
# Case-SENSITIVE in the hook, like every allow rule: widening a guard is safe,
# widening an allowlist is how a bypass gets built.
if [ -n "$TEST_ROOTS_ESC" ]; then TEST_ROOTS_REGEX="^($TEST_ROOTS_ESC)/"; else TEST_ROOTS_REGEX=""; fi

if [ -n "$SHARED_SURFACES" ]; then
  SHARED_SURFACES_ESC=""
  OLDIFS="$IFS"; IFS=','
  for _s in $SHARED_SURFACES; do
    _s="$(printf '%s' "$_s" | tr -d ' ')"
    [ -n "$_s" ] || continue
    _path_exists "$_s" || c_yel "  warning: declared shared surface '$_s' does not exist as a directory under $PROJECT."
    SHARED_SURFACES_ESC="${SHARED_SURFACES_ESC:+$SHARED_SURFACES_ESC|}$(_path_ere "$_s")"
  done
  IFS="$OLDIFS"
  SHARED_SURFACE_REGEX="^($SHARED_SURFACES_ESC)/"
else
  SHARED_SURFACE_REGEX=""
fi

# Extra test-filename shapes -> `|pattern1|pattern2`, appended directly inside
# the `case` statement's own pattern list in gate-check.sh and gate.sh, right
# before the closing paren of the built-in shapes. Unlike source roots, these
# are GLOB patterns on purpose (`*_spec.rb`), so they are NOT ERE-escaped --
# only the case-pattern-breaking characters (parenthesis, backslash, pipe)
# were already refused above, by the same "MATCHED" validation every other
# case-pattern field goes through.
EXTRA_TEST_PATTERNS=""
case "$EXTRA_TEST_PATTERNS_RAW" in
  ""|NEEDS_REVIEW|n/a) ;;
  *)
    OLDIFS="$IFS"; IFS=','
    for _t in $EXTRA_TEST_PATTERNS_RAW; do
      _t="$(printf '%s' "$_t" | tr -d ' ')"
      [ -n "$_t" ] || continue
      EXTRA_TEST_PATTERNS="${EXTRA_TEST_PATTERNS}|${_t}"
    done
    IFS="$OLDIFS"
    ;;
esac

# Globs for the rules' `paths:` frontmatter, which is a YAML LIST. Every root,
# not the first: with only the first, `backend.md` and `security.md` loaded for
# `apps/api` and silently never for `apps/worker`. The template holds one
# `  - "{{BACKEND_GLOB}}"` line, so the join closes that item and opens the
# next one -- the file still reads as one item per root.
_yaml_globs() {  # _yaml_globs <comma list>
  local out="" e OLDIFS="$IFS"
  set -f; IFS=','
  for e in $1; do
    e="${e//[[:space:]]/}"; e="${e%/}"
    [ -n "$e" ] || continue
    out="${out:+$out\"
  - \"}$e/**/*"
  done
  IFS="$OLDIFS"; set +f
  printf '%s' "$out"
}
BACKEND_GLOB="$(_yaml_globs "$SOURCE_ROOTS")"
FRONTEND_GLOB="${FRONTEND_ROOT}/**/*"
# No location-based test root left (none declared, or every one collided with a
# source root): the testing rule follows the test FILES instead.
if [ -n "$TEST_ROOT" ]; then TEST_GLOB="$(_yaml_globs "$TEST_ROOT")"; else TEST_GLOB="**/*.test.*\"
  - \"**/*_test.*\"
  - \"**/test_*"; fi

# Case globs for post-edit.sh
FORMAT_GLOB='*.ts|*.tsx|*.js|*.jsx|*.vue|*.php|*.py|*.go|*.rs'
TYPECHECK_GLOB='*.ts|*.tsx'

echo
c_grn "Configuring $TARGET  ·  $TIER_NAME plan"
c_dim "  test:      $TEST_COMMAND"
c_dim "  single:    $SINGLE_TEST_COMMAND"
c_dim "  format:    $FORMAT_COMMAND"
c_dim "  typecheck: $TYPECHECK_COMMAND"
c_dim "  audit:     $DEPENDENCY_AUDIT_COMMAND"
c_dim "  protected: $SOURCE_ROOTS_REGEX"
c_dim "  reuse gate: ${SHARED_SURFACE_REGEX:-(off — none declared)}"
c_dim "  test roots: ${TEST_ROOTS_REGEX:-(none — test files matched by name only)}"
echo

# Literal string replacement via awk. No sed delimiters, so values may safely
# contain |, @, /, & or any other character that would break a sed script.
_replace_all() {  # _replace_all <file> <key=value> ...
  local f="$1"; shift
  awk -v n="$#" 'BEGIN{
        for (i = 1; i <= n; i++) { split(ARGV[i], kv, "="); k[i] = kv[1]
          v[i] = substr(ARGV[i], length(kv[1]) + 2); ARGV[i] = "" }
      }
      { line = $0
        for (i = 1; i <= n; i++) {
          key = "{{" k[i] "}}"
          while ((pos = index(line, key)) > 0)
            line = substr(line, 1, pos - 1) v[i] substr(line, pos + length(key))
        }
        print line }' "$@" "$f" > "$f.studio.tmp" || { rm -f "$f.studio.tmp"; return 1; }
  # Preserve mode: mv would drop the executable bit on hooks.
  cat "$f.studio.tmp" > "$f"
  rm -f "$f.studio.tmp"
}

subst() {
  local f="$1"
  [ -f "$f" ] || return 0
  grep -q '{{[A-Z_]*}}' "$f" || return 0
  if [ "$DRY_RUN" = 1 ]; then c_dim "  would configure ${f#$TARGET/}"; return; fi
  _replace_all "$f" \
    "PROJECT_NAME=$PROJECT_NAME" \
    "STACK_LINE=$STACK_LINE" \
    "DEV_COMMAND=$DEV_COMMAND" \
    "TEST_COMMAND=$TEST_COMMAND" \
    "SINGLE_TEST_COMMAND=$SINGLE_TEST_COMMAND" \
    "FORMAT_COMMAND=$FORMAT_COMMAND" \
    "TYPECHECK_COMMAND=$TYPECHECK_COMMAND" \
    "BUILD_COMMAND=$BUILD_COMMAND" \
    "DEPENDENCY_AUDIT_COMMAND=$DEPENDENCY_AUDIT_COMMAND" \
    "SOURCE_ROOTS=$SOURCE_ROOTS" \
    "SOURCE_ROOTS_REGEX=$SOURCE_ROOTS_REGEX" \
    "SHARED_SURFACES=$SHARED_SURFACES" \
    "SHARED_SURFACE_REGEX=$SHARED_SURFACE_REGEX" \
    "EXTRA_TEST_PATTERNS_RAW=$EXTRA_TEST_PATTERNS_RAW" \
    "EXTRA_TEST_PATTERNS=$EXTRA_TEST_PATTERNS" \
    "FRONTEND_ROOT=$FRONTEND_ROOT" \
    "TEST_ROOT=$TEST_ROOT" \
    "TEST_ROOTS_REGEX=$TEST_ROOTS_REGEX" \
    "TOKEN_FILE=$TOKEN_FILE" \
    "HAS_UI=$HAS_UI" \
    "BACKEND_GLOB=$BACKEND_GLOB" \
    "FRONTEND_GLOB=$FRONTEND_GLOB" \
    "TEST_GLOB=$TEST_GLOB" \
    "FORMAT_GLOB=$FORMAT_GLOB" \
    "TYPECHECK_GLOB=$TYPECHECK_GLOB"
  c_dim "  configured ${f#$TARGET/}"
}

find "$TARGET/.claude" -type f \( -name '*.md' -o -name '*.sh' \) -print0 2>/dev/null \
  | while IFS= read -r -d '' f; do subst "$f"; done
chmod +x "$TARGET/.claude/hooks/"*.sh 2>/dev/null || true
subst "$TARGET/CLAUDE.md"
subst "$TARGET/CLAUDE.studio.md"

# Doc map: source area -> the doc that is supposed to describe it. The audit
# script reads this to compute staleness. Extend it as the project grows.
if [ "$DRY_RUN" = 0 ]; then
  mkdir -p "$TARGET/.claude/state"
  {
    printf '{\n'
    printf '  "%s": "docs/architecture.md"' "${SOURCE_ROOTS%%,*}"
    if [ -n "$FRONTEND_ROOT" ] && [ "$FRONTEND_ROOT" != "NEEDS_REVIEW" ]; then
      printf ',\n  "%s": "docs/design/components.md"' "$FRONTEND_ROOT"
    fi
    # Keys must stay unique — a repeated key silently wins over the earlier one
    # when the audit script parses this, which would drop the mapping above.
    case "${TIER_EXTRA_DOC_DIRS:-}" in
      *docs/runbooks*) printf ',\n  ".github/workflows": "docs/runbooks/ci.md"' ;;
    esac
    printf '\n}\n'
  } > "$TARGET/.claude/state/doc-map.json"
  c_dim "  wrote .claude/state/doc-map.json"
fi

# If there is no UI, drop the UI-only pieces rather than leaving them to rot.
# Which pieces those are is declared per tier, because a Max 20x install has
# six UI agents and a Pro install has one.
if [ "$DRY_RUN" = 0 ] && printf '%s' "$HAS_UI" | grep -qi '^no'; then
  dropped=""
  for a in ${TIER_UI_AGENTS:-}; do
    [ -f "$TARGET/.claude/agents/$a.md" ] || continue
    rm -f "$TARGET/.claude/agents/$a.md"; dropped="$dropped $a"
  done
  for s in ${TIER_UI_SKILLS:-}; do
    [ -d "$TARGET/.claude/skills/$s" ] || continue
    rm -rf "$TARGET/.claude/skills/$s"; dropped="$dropped /$s"
  done
  for r in ${TIER_UI_RULES:-}; do
    [ -f "$TARGET/.claude/rules/$r.md" ] || continue
    rm -f "$TARGET/.claude/rules/$r.md"; dropped="$dropped $r.md"
  done
  # CLAUDE.md loads in full every session. A frontend-direction block on a
  # service or a library is standing cost for nothing.
  for f in "$TARGET/CLAUDE.md" "$TARGET/CLAUDE.studio.md"; do
    [ -f "$f" ] || continue
    grep -q 'studio:frontend-direction:start' "$f" || continue
    sed -i.studio.bak \
      '/<!-- studio:frontend-direction:start -->/,/<!-- studio:frontend-direction:end -->/d' "$f" \
      && rm -f "$f.studio.bak"
    dropped="$dropped $(basename "$f")#frontend-direction"
  done
  [ -n "$dropped" ] && c_yel "  no UI: removed$dropped"
fi

# Record what the enforcement layer IS, now that it is fully substituted.
# gate-check.sh allows every write under .claude/, which it must -- a session
# has to be able to repair a broken install. The cost is that appending
# `exit 0` to a hook is the cheapest bypass in the whole pipeline, and nothing
# in the working tree would look wrong afterwards. This manifest is what makes
# that edit a visible diff instead of a silent one.
# Arm the size ratchet against the tree as it is TODAY. Recording it here is
# what makes it adoptable: the bar applies to what happens next, not to a
# backlog nobody agreed to fix this week. Without a baseline the first CI run
# fails on a legacy tree and the check gets deleted rather than fixed.
if [ "$DRY_RUN" = 0 ] && [ -x "$TARGET/.claude/scripts/ratchet.sh" ]; then
  ( cd "$TARGET" && bash .claude/scripts/ratchet.sh --update 2>/dev/null )     | sed 's/^/  /' || true
fi

if [ "$DRY_RUN" = 0 ] && [ -x "$TARGET/.claude/scripts/hook-integrity.sh" ]; then
  ( cd "$TARGET" && bash .claude/scripts/hook-integrity.sh --update >/dev/null 2>&1 )     && c_dim "  recorded .claude/state/hooks.sha256"
fi

echo
LEFT=$(grep -rl '{{[A-Z_]*}}' "$TARGET/.claude" "$TARGET/CLAUDE.md" 2>/dev/null || true)
if [ -n "$LEFT" ]; then
  c_yel "Still unresolved:"; printf '%s\n' "$LEFT" | sed "s|$TARGET/|  |"
else
  c_grn "All placeholders resolved. Hooks are live."
fi
echo
c_dim "Next: open Claude Code and run /doctor, /hooks, /context."
c_dim "Then prove the gate fires: ./verify.sh --target ."
