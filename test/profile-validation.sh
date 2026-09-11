#!/usr/bin/env bash
#
# Does configure.sh refuse profile values that would corrupt or subvert a hook?
#
# Profile values are substituted into hook SOURCE, and they land in two shapes
# that fail differently:
#
#   EXECUTED   post-edit.sh runs `<format command> "$FILE"` unquoted on every
#              edit -- it has to be unquoted, or a two-word command like
#              `npx prettier -w` could not work. So a `;` or a `$(...)` there is
#              a second command running on every single edit.
#   MATCHED    filter-output.sh puts commands inside `case` PATTERNS, where a
#              `)` ends the pattern early and leaves the hook a syntax error. It
#              then dies on every Bash call, and the harness reports a hook
#              failure rather than anything about the real problem.
#
# PROFILE.md is the project owner's own file, so this is not a defence against
# someone who already has commit access. It is a defence against a paste, a
# stray character, and a hook that silently becomes broken -- which, in a
# pipeline whose whole claim is that its gates are deterministic, is the
# expensive failure.
#
#   bash test/profile-validation.sh
#
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
ok()  { printf '  \033[32mok  \033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n       %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

command -v git >/dev/null 2>&1 || { echo "skip: git not available"; exit 0; }
PY=$(command -v python3 2>/dev/null || command -v python 2>/dev/null) \
  || { echo "skip: python not available"; exit 0; }

W="$(mktemp -d)"
trap 'cd /; rm -rf "$W"' EXIT INT TERM HUP

# The helper is written to a FILE rather than piped on stdin: it carries a regex
# and an explicit newline, and a heredoc full of backslash escapes is fragile to
# move around.
cat > "$W/setfield.py" <<'PYEOF'
import io, re, sys
profile, label, valuefile = sys.argv[1], sys.argv[2], sys.argv[3]
value = io.open(valuefile, encoding="utf-8").read()
text = io.open(profile, encoding="utf-8").read()
pattern = r"(\|\s*" + re.escape(label) + r"\s*\|)[^|]*(\|)"
new, n = re.subn(pattern, lambda m: m.group(1) + " " + value + " " + m.group(2),
                 text, count=1)
if n != 1:
    sys.stderr.write("setfield: no row for " + repr(label) + "\n")
    sys.exit(3)
io.open(profile, "w", encoding="utf-8", newline="\n").write(new)
PYEOF

# The VALUE travels through a FILE, not through argv or the environment.
#
# On Git Bash / MSYS, an argument OR an env var that looks like an absolute Unix
# path is rewritten before the child process sees it: `/src` arrived as
# `C:/Program Files/Git/src`, so the "absolute source root" case was quietly
# testing a relative path and reported that configure.sh had accepted a value it
# actually rejects. The product was correct the whole time; the harness was
# lying, which is the one failure mode this repo cares about most.
#
# MSYS_NO_PATHCONV=1 fixes the value and breaks the profile PATH, which does
# need converting for a native python.exe. A file carries the value verbatim and
# leaves path conversion alone where it belongs.
setfield() {  # setfield <profile> <label> <value>
  local vf="$W/.value"
  printf '%s' "$3" > "$vf"
  "$PY" "$W/setfield.py" "$1" "$2" "$vf"
}

# One fixture project, installed once and copied per case. Installing per case
# is what made an earlier version of this suite take minutes.
FIX="$W/fixture"
mkdir -p "$FIX/src" "$FIX/tests"
git init -q "$FIX"
printf '{"name":"v","scripts":{"test":"vitest run"}}\n' > "$FIX/package.json"
printf 'export const x = 1;\n' > "$FIX/src/a.ts"
( cd "$FIX" && git add -A >/dev/null 2>&1 \
  && git -c user.email=a@b -c user.name=c commit -qm init >/dev/null 2>&1 )
if ! bash "$SRC/install.sh" --plan pro --target "$FIX" >"$W/install.log" 2>&1; then
  echo "could not install the fixture:"; tail -5 "$W/install.log"; exit 1
fi

# A baseline profile with every field answered, so each case poisons exactly one.
P="$FIX/docs/setup/PROFILE.md"
sed -i 's/NEEDS_REVIEW/true/g' "$P"
setfield "$P" 'Source roots'    'src'            || exit 1
setfield "$P" 'Test root'       'tests'          || exit 1
setfield "$P" 'Shared surfaces' 'src/components' || exit 1
setfield "$P" 'Has UI'          'yes'            || exit 1

# The unpoisoned baseline must configure CLEANLY, or every "reject" below passes
# for the wrong reason -- which is exactly how this suite once reported 8 green
# rejections while a single over-broad guard was refusing every value there is.
head_ "Sanity"
cp -a "$FIX" "$W/sanity"
if bash "$SRC/configure.sh" --target "$W/sanity" >"$W/sanity.log" 2>&1; then
  ok "the unpoisoned baseline configures cleanly"
else
  bad "the unpoisoned baseline configures cleanly" \
      "every reject case below would pass for the wrong reason: $(grep -m1 -i error "$W/sanity.log")"
  rm -rf "$W/sanity"
  printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
  exit 1
fi
rm -rf "$W/sanity"

N=0
check() {  # check <label> <field> <value> <reject|accept>
  local label="$1" field="$2" val="$3" expect="$4"
  N=$((N + 1))
  local d="$W/case$N"
  cp -a "$FIX" "$d" || { bad "$label" "could not copy the fixture"; return; }
  if ! setfield "$d/docs/setup/PROFILE.md" "$field" "$val"; then
    bad "$label" "could not set the field"; rm -rf "$d"; return
  fi
  if bash "$SRC/configure.sh" --target "$d" >"$d/out.log" 2>&1; then
    [ "$expect" = accept ] && ok "$label" \
      || bad "$label" "configure.sh ACCEPTED a value that corrupts a hook"
  else
    [ "$expect" = reject ] && ok "$label" \
      || bad "$label" "configure.sh rejected a legitimate value: $(grep -m1 -i error "$d/out.log" || echo '(no error line)')"
  fi
  rm -rf "$d"
}

head_ "Values that must be REFUSED"
check "format command chains with ;"      'Format command (fixes)'      'prettier -w; curl http://x'   reject
check "format command substitutes"        'Format command (fixes)'      'prettier -w $(id)'            reject
check "format command redirects"          'Format command (fixes)'      'prettier -w > /tmp/x'         reject
check "format command backgrounds"        'Format command (fixes)'      'prettier -w & id'             reject
check "typecheck command chains"          'Type-check command'          'tsc --noEmit; id'             reject
check "test command has a paren"          'Test command (non-watching)' 'vitest run (x)'               reject
check "source roots traverse up"          'Source roots'                '../etc'                       reject
check "source roots are a glob"           'Source roots'                'sr*'                          reject
check "source roots are absolute"         'Source roots'                '/src'                         reject
check "test root traverses up"            'Test root'                   '../..'                        reject
# A pipe cannot survive a markdown table cell: the row splits and the value is
# truncated at the pipe. Silent truncation configures the hook with something
# the profile does not say, so the row shape is refused outright.
check "a value containing a pipe"         'Test command (non-watching)' 'vitest run | tee out.txt'     reject

head_ "Values that must be ACCEPTED"
check "a plain format command"            'Format command (fixes)'      'npx prettier -w'              accept
check "a vendored binary path"            'Format command (fixes)'      './vendor/bin/pint'            accept
check "typecheck with flags"              'Type-check command'          'npx tsc --noEmit'             accept
check "audit chained with &&"             'Dependency audit command'    'composer audit && npm audit'  accept
check "several source roots"              'Source roots'                'src,lib'                      accept
check "nested shared surfaces"            'Shared surfaces'             'src/components,src/services'  accept
check "an ordinary test root"             'Test root'                   'tests'                        accept

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
