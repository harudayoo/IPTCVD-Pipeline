#!/usr/bin/env bash
#
# Does the size ratchet actually ratchet?
#
# A ratchet has exactly three behaviours, and getting any one of them wrong
# makes it either useless or unadoptable:
#
#   a baselined file may SHRINK          -- otherwise nobody can improve anything
#   a baselined file may NOT grow        -- otherwise it is not a ratchet
#   an unlisted file may not CROSS       -- otherwise the bar only applies to
#                                           files that already broke it
#
# The fourth behaviour is the one that decides whether it survives contact with
# a real repository: a tree that is already over the bar has to be recordable,
# or the first CI run fails on a backlog nobody agreed to fix and the check gets
# deleted instead of fixed.
#
#   bash test/ratchet.sh
#
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
ok()  { printf '  \033[32mok  \033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n       %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

W="$(mktemp -d)"
trap 'cd /; rm -rf "$W"' EXIT INT TERM HUP

mkdir -p "$W/.claude/scripts" "$W/.claude/state" "$W/src"
sed 's|{{SOURCE_ROOTS}}|src|g' "$SRC/templates/common/scripts/ratchet.sh" \
  > "$W/.claude/scripts/ratchet.sh"
cd "$W" || exit 1

# lines <file> <n>   -- write a file of exactly n lines
lines() { :> "$1"; local i=0; while [ "$i" -lt "$2" ]; do echo "// $i" >> "$1"; i=$((i+1)); done; }

run() { bash .claude/scripts/ratchet.sh "$@" 2>&1; }
# No "$@": every call is a bare check. Taking arguments it never receives is
# what SC2120 flags, and the warning is right -- an unused parameter in a test
# helper is a call site somebody meant to write and did not.
rc()  { bash .claude/scripts/ratchet.sh >/dev/null 2>&1; echo $?; }

head_ "1. An unarmed ratchet is not a pass"
lines src/small.ts 10
[ "$(rc)" = 1 ] && ok "no baseline fails rather than exiting 0" \
                || bad "no baseline fails" "it exited 0, which looks exactly like a pass"

head_ "2. A tree already over the bar can be recorded"
lines src/legacy.ts 900
run --update >/dev/null
grep -q 'src/legacy.ts' .claude/state/size-baseline.tsv \
  && ok "an oversized file is baselined with its size" \
  || bad "an oversized file is baselined" "it is missing from the baseline"
[ "$(rc)" = 0 ] && ok "a freshly recorded tree passes" \
               || bad "a freshly recorded tree passes" "$(run | head -2)"

head_ "3. The three ratchet behaviours"
lines src/legacy.ts 880
[ "$(rc)" = 0 ] && ok "a baselined file may SHRINK (900 -> 880)" \
               || bad "a baselined file may shrink" "$(run | head -2)"

lines src/legacy.ts 950
[ "$(rc)" = 1 ] && ok "a baselined file may NOT grow (900 -> 950)" \
               || bad "a baselined file may not grow" "it was allowed to grow"
# `run | grep -q` reports the RATCHET's exit status under `pipefail`, and the
# ratchet exits 1 exactly when the message being asserted is produced -- so the
# assertion failed while the message was perfectly correct. Capture, then match.
OUT="$(run)"
case "$OUT" in
  *"grew from"*) ok "the message names the growth" ;;
  *) bad "the message names the growth" "$(printf '%s' "$OUT" | head -2)" ;;
esac
lines src/legacy.ts 900

lines src/newbig.ts 1200
[ "$(rc)" = 1 ] && ok "an unlisted file may not CROSS the bar" \
               || bad "an unlisted file may not cross" "it was allowed across"
OUT="$(run)"
case "$OUT" in
  *"not baselined"*) ok "the message says it is unbaselined" ;;
  *) bad "the message says it is unbaselined" "$(printf '%s' "$OUT" | head -2)" ;;
esac
rm -f src/newbig.ts

lines src/under.ts 799
[ "$(rc)" = 0 ] && ok "a file just under the bar is ignored" \
               || bad "a file just under the bar is ignored" "$(run | head -2)"

head_ "4. The bar lives in the baseline, not in the script"
grep -q '^# bar: 800' .claude/state/size-baseline.tsv \
  && ok "the bar is recorded in the baseline header" \
  || bad "the bar is recorded in the baseline" "$(head -1 .claude/state/size-baseline.tsv)"
# Changing it is a committed diff somebody can object to, not an edit to a tool.
sed -i 's/^# bar: 800/# bar: 1000/' .claude/state/size-baseline.tsv
lines src/legacy.ts 950
[ "$(rc)" = 0 ] && ok "raising the bar in the baseline takes effect" \
               || bad "raising the bar takes effect" "$(run | head -2)"
sed -i 's/^# bar: 1000/# bar: 800/' .claude/state/size-baseline.tsv
lines src/legacy.ts 900

head_ "5. Vendored trees are not the project's code"
mkdir -p src/node_modules/pkg
lines src/node_modules/pkg/huge.js 5000
[ "$(rc)" = 0 ] && ok "node_modules is excluded" \
               || bad "node_modules is excluded" "$(run | head -2)"

head_ "6. An unconfigured ratchet refuses rather than scanning nothing"
sed 's|^SOURCE_ROOTS=.*|SOURCE_ROOTS="{{SOURCE_ROOTS}}"|' .claude/scripts/ratchet.sh \
  > .claude/scripts/unconf.sh
bash .claude/scripts/unconf.sh >/dev/null 2>&1
[ "$?" = 1 ] && ok "an unsubstituted placeholder fails loudly" \
             || bad "an unsubstituted placeholder fails loudly" "it exited 0 having scanned nothing"

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
