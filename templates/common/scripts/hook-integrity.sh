#!/usr/bin/env bash
# Verifies that the enforcement layer is still the enforcement layer.
#
#   bash .claude/scripts/hook-integrity.sh           # check (CI, and on demand)
#   bash .claude/scripts/hook-integrity.sh --update  # re-record after a real edit
#
# Why this exists: gate-check.sh allows every write under .claude/ without
# asking the gate anything. That is deliberate and necessary -- a session must
# be able to repair a broken install, and blocking it would make a
# half-configured pipeline unrecoverable. But it also means the single cheapest
# way past every gate in this repo is:
#
#     echo 'exit 0' >> .claude/hooks/gate-check.sh
#
# or deleting four lines from .claude/settings.json. Nothing in the working
# tree would look wrong afterwards, every hook would keep "running", and every
# check would keep reporting green. The gate cannot be the thing that guards
# the gate.
#
# So the guard moves one level out, to a place a session cannot quietly reach:
# a committed manifest of what the hooks ARE, checked in CI on every push. A
# session may still edit a hook -- that is a legitimate thing to do -- but the
# edit now has to survive review as a visible diff to a checksum file, instead
# of disappearing into a script nobody reads twice.
#
# This is defence in depth, not a cage. Anyone with commit access can run
# --update. The point is that disarming the pipeline stops being invisible.
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1

MANIFEST=".claude/state/hooks.sha256"
MODE="check"
[ "${1:-}" = "--update" ] && MODE="update"

hash_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else
    # No hasher at all: say so rather than silently certifying nothing.
    echo "NO_SHA256_AVAILABLE"
  fi
}

# The files whose content IS the enforcement layer. settings.json is included
# because unregistering a hook disables it exactly as thoroughly as emptying it.
TRACKED=""
for f in .claude/hooks/*.sh .claude/settings.json; do
  [ -f "$f" ] || continue
  TRACKED="$TRACKED $f"
done

if [ -z "${TRACKED// /}" ]; then
  echo "hook-integrity: no hooks found under .claude/hooks — is this an install?" >&2
  exit 1
fi

if [ "$MODE" = "update" ]; then
  mkdir -p "$(dirname "$MANIFEST")"
  : > "$MANIFEST"
  for f in $TRACKED; do
    printf '%s  %s\n' "$(hash_of "$f")" "$f" >> "$MANIFEST"
  done
  echo "hook-integrity: recorded $(wc -l < "$MANIFEST" | tr -d ' ') files in $MANIFEST"
  echo "Commit it in the SAME commit as the hook change, so the diff shows both."
  exit 0
fi

if [ ! -f "$MANIFEST" ]; then
  echo "hook-integrity: no $MANIFEST." >&2
  echo "  Nothing can tell whether the hooks are the ones that were reviewed." >&2
  echo "  Record them:  bash .claude/scripts/hook-integrity.sh --update" >&2
  exit 1
fi

RC=0

# Changed or missing
while read -r want file; do
  [ -n "${file:-}" ] || continue
  if [ ! -f "$file" ]; then
    echo "REMOVED  $file — a hook in the manifest is gone from the tree." >&2
    RC=1
    continue
  fi
  got="$(hash_of "$file")"
  if [ "$got" = "NO_SHA256_AVAILABLE" ]; then
    echo "hook-integrity: no sha256sum or shasum on PATH; cannot verify." >&2
    exit 1
  fi
  if [ "$got" != "$want" ]; then
    echo "CHANGED  $file" >&2
    RC=1
  fi
done < "$MANIFEST"

# Added but unrecorded. An extra hook is as much a change to the enforcement
# layer as an edited one -- and is how a third-party hook would end up running
# with nobody having reviewed it.
for f in $TRACKED; do
  grep -qF "  $f" "$MANIFEST" || { echo "UNRECORDED  $f" >&2; RC=1; }
done

if [ "$RC" != 0 ]; then
  echo >&2
  echo "The enforcement layer differs from what was last reviewed." >&2
  echo "If the change is intended, re-record it and commit BOTH together:" >&2
  echo "  bash .claude/scripts/hook-integrity.sh --update" >&2
  exit 1
fi

echo "hook-integrity: $(wc -l < "$MANIFEST" | tr -d ' ') files match the recorded manifest"
