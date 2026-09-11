#!/usr/bin/env bash
# PreToolUse(Edit|Write): blocks source edits unless the pipeline has reached
# the 'create' phase AND the plan on record says what it is for.
#
# Fails CLOSED for the configured source roots (no gate file, unreadable gate
# file, unconfigured hook, or the wrong phase all block). Fails OPEN for
# everything outside them, and for docs/tests/.claude/*.md regardless of phase,
# so writing the plan itself is never blocked by the gate meant to require it.
#
# FOUR gates, in the order they fire:
#
#   1. PHASE       -- a plan has been approved and the pipeline is in 'create'.
#   2. CONTENT     -- that plan carries a `problem` and a `red` note. A boolean
#                     gate certifies only that a plan EXISTS, never what it said,
#                     and the two stages with an artifact but nothing
#                     gate-readable are reliably the two that get skipped.
#   3. NEW SURFACE -- creating a file under a shared-surface directory also
#                     needs `reuse`: reuse X / extend X / new because X cannot Y.
#                     "Reuse what is already here" is prose until something asks.
#   4. DEPENDENCY  -- editing a dependency manifest needs `deps`: what
#                     already-present capability was checked first, and why it
#                     does not cover this. A dependency is the most expensive
#                     kind of reuse -- transitive packages, a CVE surface, a
#                     licence, an upgrade obligation -- so it must be a stated
#                     decision, not a reflex.
#
# The hook cannot judge whether a change is testable, so it does not try: it
# requires the answer to be STATED. "n/a: <reason>" is a legitimate `red` for a
# change with no behaviour to pin. The reviewing agent checks the stated answer
# against the shipped diff.
set -uo pipefail
SELF="${BASH_SOURCE[0]}"
# shellcheck source=/dev/null
. "$(dirname "$SELF")/_guard.sh"

INPUT=$(cat)
FILE="$(json_field "$INPUT" 'tool_input.file_path')"
[ -z "$FILE" ] && exit 0

# --- normalise BEFORE authorising ------------------------------------------
# Pure path logic, no configuration needed, so it runs before everything.
if ! studio_normalise_path FILE; then
  echo 'BLOCKED: path traverses a symlink and neither realpath nor readlink can' >&2
  echo '  resolve it. The unresolved path may name an allow rule while the write' >&2
  echo '  lands somewhere guarded. Refusing to guess.' >&2
  exit 2
fi

PROTECTED="{{SOURCE_ROOTS_REGEX}}"
TEST_ROOT="{{TEST_ROOT}}"
SHARED_SURFACE="{{SHARED_SURFACE_REGEX}}"

# Dependency manifests are guarded too. Ecosystem-independent, and matched
# EXACTLY at the repo root so a downloaded package's own manifest under a
# vendored tree can never reach this.
MANIFEST=0
case "$FILE" in
  package.json|composer.json|Cargo.toml|go.mod|pyproject.toml|requirements.txt|Gemfile|build.gradle|build.gradle.kts|pom.xml)
    MANIFEST=1 ;;
esac

# Vendored trees are downloaded artifacts, not this project's source. Checked
# before the allow rules so a vendored path can never be read as anything else.
case "$FILE" in
  node_modules/*|*/node_modules/*|vendor/*|*/vendor/*|.git/*|*/.git/*) exit 0 ;;
esac

# --- always writable --------------------------------------------------------
# Checked BEFORE the configuration guard below, and that ordering is
# load-bearing in both directions:
#
#   - These rules must come first, or an unconfigured install cannot be
#     repaired: the hook would refuse the write to PROFILE.md that fixes it.
#   - The SOURCE-ROOT test must come after, because an unsubstituted
#     {{SOURCE_ROOTS_REGEX}} matches nothing, and testing it early would
#     silently allow every source write while reporting success.
#
# So: allow the repair path unconditionally, then refuse to judge anything else
# until the hook knows what it is guarding.
#
# ANCHORED, every one of them. The previous spelling included *test*|*Test*|*spec*
# matched anywhere in the path, so any source file whose NAME merely contained
# those letters was ungated -- measured on src/services/LatestReport.ts and
# src/http/InspectorController.ts, both of which walked straight through a
# closed gate. An allow rule has to name a location or a whole filename, never
# a substring of a path.
case "$FILE" in
  docs/*|.claude/*|*.md) exit 0 ;;
esac
if [ -n "$TEST_ROOT" ]; then
  case "$FILE" in "$TEST_ROOT"/*) exit 0 ;; esac
fi

# A TEST FILE, identified by the shape of its FILENAME rather than by where it
# sits. Go, Rust and most JS projects keep tests beside the code they cover, so
# a location-only rule means the TEST phase cannot write the failing test that
# the CREATE phase exists to turn green -- the pipeline would deadlock on its
# own contract. Matching the basename keeps that precise: `dues.test.ts` and
# `pay_test.go` are tests; `LatestReport.ts` and `InspectorController.ts` are
# not, and both still block.
case "${FILE##*/}" in
  *.test.*|*.spec.*|*_test.*|test_*|*Test.php|*Spec.php|*.Tests.cs|conftest.py) exit 0 ;;
esac

if ! studio_guard "$SELF"; then
  echo "BLOCKED: claude-studio is not configured, so the phase gate cannot be" >&2
  echo "  trusted. Refusing to edit source. Fill docs/setup/PROFILE.md and run" >&2
  echo "  ./configure.sh, then ./verify.sh to confirm the gate fires." >&2
  exit 2
fi

# --- is this a guarded path at all? ----------------------------------------
#
# Matched case-INSENSITIVELY. On Windows and macOS `APP/Services/x.ts` IS
# `app/Services/x.ts` -- the same file, one spelling the gate could not see, and
# it walked straight past a closed gate when this was `grep -qE`. On a
# case-sensitive filesystem the -i widens the guard instead: a genuinely
# distinct `APP/` directory would also be gated. That is the fail-closed
# direction, which is the safe way to be wrong. CWE-178.
#
# Note the asymmetry with the allow rules above, which stay case-SENSITIVE.
# Widening a guard is safe; widening an allowlist is how you build a bypass.
GUARDED=0
if [ -n "$PROTECTED" ] && printf '%s' "$FILE" | grep -qiE "$PROTECTED"; then
  GUARDED=1
fi

# Still absolute? Root stripping failed (unexpected cwd or layout). Decide from
# path SEGMENTS rather than waving it through -- an unrecognised path shape must
# not become a silent bypass. The segment list is derived from the configured
# regex, so source roots are still declared in exactly one place.
case "$FILE" in
  /*|[A-Za-z]:/*)
    ROOTS=$(printf '%s' "$PROTECTED" | sed 's/^\^(//; s/)\/$//; s/^\^//; s/\/$//')
    FILE_LC=${FILE,,}
    OLDIFS="$IFS"; IFS='|'
    for r in $ROOTS; do
      [ -n "$r" ] || continue
      case "$FILE_LC" in */"${r,,}"/*) GUARDED=1 ;; esac
    done
    IFS="$OLDIFS"
    ;;
esac

[ "$GUARDED" = "1" ] || [ "$MANIFEST" = "1" ] || exit 0

# --- read the whole gate in ONE pass ---------------------------------------
# This hook is on the latency path of every Edit/Write. A version that spawned
# one parser per key cost ~1.7s per invocation and turned the self-test into a
# three-minute run that looked like a hang. One parse, six values.
GATE=".claude/state/gate.json"

unblock_hint() {
  echo "Complete and approve the plan and test phases, then record the decision:" >&2
  echo "  bash .claude/scripts/gate.sh create --problem \"<what breaks>\" --red \"<the failing test, or n/a: why>\"" >&2
  echo "Reset at handoff:  bash .claude/scripts/gate.sh idle" >&2
}

if [ ! -f "$GATE" ]; then
  echo "BLOCKED: no .claude/state/gate.json — treating this as no approved plan." >&2
  studio_log_gate gate-check BLOCK none "$FILE" no-gate-file
  unblock_hint
  exit 2
fi

gate_read_all() {
  # Same fall-through discipline as json_field: a present-but-broken parser
  # must not be able to hand back six empty strings. Here the consequence is
  # merely fail-closed rather than fail-open -- an empty phase blocks -- but a
  # gate that refuses every edit for a reason nobody can see is how the gate
  # gets switched off, which fails open in the end anyway.
  local out
  if command -v jq >/dev/null 2>&1; then
    out=$(jq -r '[.phase//"",.problem//"",.red//"",.vault//"",.reuse//"",.deps//""]|.[]' "$GATE" 2>/dev/null) \
      && [ -n "${out//[$'\n'[:space:]]/}" ] && { printf '%s\n' "$out"; return; }
  fi
  local py
  if py="$(command -v python3 2>/dev/null || command -v python 2>/dev/null)" && [ -n "$py" ]; then
    out=$("$py" -c 'import json,sys
sys.stdout.reconfigure(newline="")
try: d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception: d = {}
if not isinstance(d, dict): d = {}
for k in ("phase","problem","red","vault","reuse","deps"):
    v = d.get(k) or ""
    sys.stdout.write(str(v).replace(chr(10), chr(32)) + chr(10))' "$GATE" 2>/dev/null) \
      && [ -n "${out//[$'\n'[:space:]]/}" ] && { printf '%s\n' "$out"; return; }
  fi
  # ONE LINE PER KEY, always -- including for a key that is absent.
  #
  # The caller reads these six values with six sequential `read` calls, so a key
  # that prints nothing does not read as empty: it SHIFTS every value after it
  # up by one. A gate carrying problem/red/reuse but no `vault` therefore handed
  # `reuse` back as the vault answer and `deps` back as the reuse answer, and a
  # correctly-recorded plan was refused for a note that was plainly there.
  #
  # That fails closed, so it never shipped a bad change -- it just made a valid
  # plan unopenable, which is how a gate earns the reputation that gets it
  # switched off. It only appeared when both richer parsers were unavailable,
  # which is the branch least often exercised and most often shipped.
  local k v
  for k in phase problem red vault reuse deps; do
    v=$(grep -o "\"$k\"[[:space:]]*:[[:space:]]*\"\(\\\\.\|[^\"\\\\]\)*\"" "$GATE" 2>/dev/null \
        | head -1 | sed "s/^\"$k\"[[:space:]]*:[[:space:]]*\"//; s/\"$//; s/\\\\\"/\"/g" || true)
    printf '%s\n' "$v"
  done
}

{ IFS= read -r PHASE; IFS= read -r PROBLEM; IFS= read -r RED
  IFS= read -r VAULT; IFS= read -r REUSE; IFS= read -r DEPS; } <<EOF
$(gate_read_all)
EOF
# Any parser may hand back a trailing CR on Windows; one strip covers all three.
PHASE=${PHASE%$'\r'}; PROBLEM=${PROBLEM%$'\r'}; RED=${RED%$'\r'}
VAULT=${VAULT%$'\r'}; REUSE=${REUSE%$'\r'}; DEPS=${DEPS%$'\r'}
[ -z "${PHASE:-}" ] && PHASE="idle"

# --- gate 1: phase ----------------------------------------------------------
case "$PHASE" in
  create|verify) ;;
  *)
    echo "BLOCKED: gate phase is '$PHASE'. Source edits are only allowed in 'create'." >&2
    echo "  file: $FILE" >&2
    studio_log_gate gate-check BLOCK "$PHASE" "$FILE" wrong-phase
    unblock_hint
    exit 2 ;;
esac

# --- gate 2: the plan must say what it is for -------------------------------
# Report every missing key at once. Blocking twice in a row over the same stage
# teaches the workflow worse than one message naming both.
MISSING=""
[ -z "${PROBLEM:-}" ] && MISSING="problem"
[ -z "${RED:-}" ] && MISSING="${MISSING:+$MISSING and }red"
if [ -n "$MISSING" ]; then
  echo "BLOCKED: the plan on record carries no $MISSING note." >&2
  echo "  file: $FILE" >&2
  echo "  problem = what breaks, and what is out of scope." >&2
  echo "  red     = the test that fails NOW, before the code exists, or \"n/a: <why>\"." >&2
  studio_log_gate gate-check BLOCK "$PHASE" "$FILE" "missing-$MISSING"
  unblock_hint
  exit 2
fi

# --- gate 4: reaching OUTSIDE the codebase ---------------------------------
if [ "$MANIFEST" = "1" ]; then
  if [ -n "${DEPS:-}" ]; then
    studio_log_gate gate-check ALLOW "$PHASE" "$FILE" manifest
    exit 0
  fi
  echo "BLOCKED: dependency manifest edited with no deps decision on record." >&2
  echo "  file: $FILE" >&2
  echo "A dependency is the most expensive kind of reuse: transitive packages, a" >&2
  echo "CVE surface, a licence, and an upgrade obligation. Check what is already" >&2
  echo "here, then record the verdict alongside the plan:" >&2
  echo "  bash .claude/scripts/gate.sh create --problem \"…\" --red \"…\" \\" >&2
  echo "    --deps \"<what you checked first, and why it does not cover this>\"" >&2
  echo "Lockfiles are NOT gated — a cold install is never blocked." >&2
  studio_log_gate gate-check BLOCK "$PHASE" "$FILE" missing-deps
  exit 2
fi

# --- gate 3: the birth of a new shared surface -----------------------------
# A path that already exists is an edit, never a new surface. Editing an
# existing file is never blocked by this -- only creating a new one.
NEW_SURFACE=0
if [ -n "$SHARED_SURFACE" ] && [ ! -e "$FILE" ]; then
  printf '%s' "$FILE" | grep -qE "$SHARED_SURFACE" && NEW_SURFACE=1
fi

if [ "$NEW_SURFACE" = "1" ] && [ -z "${REUSE:-}" ]; then
  echo "BLOCKED: new shared surface with no reuse decision on record." >&2
  echo "  file: $FILE" >&2
  echo "Ask what already exists before adding a fifth one, then record the" >&2
  echo "verdict alongside the plan you already have:" >&2
  echo "  bash .claude/scripts/gate.sh create --problem \"…\" --red \"…\" \\" >&2
  echo "    --reuse \"<reuse X / extend X / new because X cannot Y>\"" >&2
  studio_log_gate gate-check BLOCK "$PHASE" "$FILE" missing-reuse
  exit 2
fi

studio_log_gate gate-check ALLOW "$PHASE" "$FILE" ""
exit 0
