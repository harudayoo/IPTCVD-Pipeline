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
# newline="" is load-bearing. Python's default text mode is UNIVERSAL NEWLINES,
# which silently rewrites a lone carriage return to a newline on read. So the
# CR case below was writing a NEWLINE into the profile row, testing something
# else entirely, and
# reporting that configure.sh accepts a value it in fact rejects. Same shape as
# the MSYS path rewriting documented above: the harness lying, not the product.
value = io.open(valuefile, encoding="utf-8", newline="").read()
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
# A carriage return mid-value survives everything between the profile and the
# hook: field() trims spaces and tabs only, and the row parser splits on `|`.
# It lands in hook source, where `prettier -w<CR>` is a command that does not
# exist and the hook dies on every edit. This guard's first implementation was
# broken in the other direction -- it rejected every value there is, while
# reporting a precise reason -- and it had no test either way until now.
check "a value with an embedded CR"       'Format command (fixes)'      "$(printf 'prettier -w\r--check')" reject

head_ "Values that must be ACCEPTED"
check "a plain format command"            'Format command (fixes)'      'npx prettier -w'              accept
check "a vendored binary path"            'Format command (fixes)'      './vendor/bin/pint'            accept
check "typecheck with flags"              'Type-check command'          'npx tsc --noEmit'             accept
check "audit chained with &&"             'Dependency audit command'    'composer audit && npm audit'  accept
check "several source roots"              'Source roots'                'src,lib'                      accept
check "nested shared surfaces"            'Shared surfaces'             'src/components,src/services'  accept
check "an ordinary test root"             'Test root'                   'tests'                        accept
# ONE missing root beside a real one is a WARNING -- it may simply not have
# been created yet. EVERY root missing is refused: the gate would guard
# nothing while verify.sh passed, which is what a .NET repo configured with
# "src,app,lib" (it had WebSite/, SQLScripts/, Reports/) actually shipped.
check "one missing root beside a real one"     'Source roots'  'src,not-yet-created'      accept
check "no declared root exists at all"         'Source roots'  'does-not-exist-anywhere'  reject
check "the src,app,lib guess on a repo with none of them" 'Source roots' 'app,lib'        reject

head_ "Root safety: normalise, escape, still guard"
# Tested against the actual compiled hook, not just configure.sh's exit code --
# the audited bugs both had configure.sh exiting 0 the whole time while the
# resulting regex silently matched nothing, or matched too much.
check_root_guards() {  # check_root_guards <label> <declared-root> <path-that-must-block>
  local label="$1" declared="$2" probe="$3"
  N=$((N + 1))
  local d="$W/case$N"
  cp -a "$FIX" "$d" || { bad "$label" "could not copy the fixture"; return; }
  # configure.sh refuses roots that exist nowhere, so the declared one must.
  mkdir -p "$d/$(printf '%s' "$declared" | tr '\\' /)"
  if ! setfield "$d/docs/setup/PROFILE.md" 'Source roots' "$declared"; then
    bad "$label" "could not set the field"; rm -rf "$d"; return
  fi
  if ! bash "$SRC/configure.sh" --target "$d" >"$d/out.log" 2>&1; then
    bad "$label" "configure.sh rejected it: $(grep -m1 -i error "$d/out.log" || echo '(no error line)')"
    rm -rf "$d"; return
  fi
  local rc
  rc=$(cd "$d" && printf '{"phase":"idle"}' > .claude/state/gate.json \
       && printf '{"tool_input":{"file_path":"%s"}}' "$probe" | bash .claude/hooks/gate-check.sh >/dev/null 2>&1; echo $?)
  [ "$rc" = 2 ] && ok "$label" \
    || bad "$label" "the declared root did not actually guard '$probe' (gate-check exit $rc)"
  rm -rf "$d"
}
# check_root_guards_never <label> <declared-root> <path-that-must-STAY-open> --
# the mirror image: an escape that undershoots (still leaves a metacharacter
# live) makes the root guard MORE than its own name, which is the fail-open
# direction for everything beside it that happens to share a character.
check_root_never_guards() {
  local label="$1" declared="$2" probe="$3"
  N=$((N + 1))
  local d="$W/case$N"
  cp -a "$FIX" "$d" || { bad "$label" "could not copy the fixture"; return; }
  mkdir -p "$d/$(printf '%s' "$declared" | tr '\\' /)"
  setfield "$d/docs/setup/PROFILE.md" 'Source roots' "$declared" >/dev/null 2>&1
  bash "$SRC/configure.sh" --target "$d" >"$d/out.log" 2>&1
  local rc
  rc=$(cd "$d" && printf '{"phase":"idle"}' > .claude/state/gate.json \
       && printf '{"tool_input":{"file_path":"%s"}}' "$probe" | bash .claude/hooks/gate-check.sh >/dev/null 2>&1; echo $?)
  [ "$rc" = 0 ] && ok "$label" \
    || bad "$label" "the escaped root wrongly guarded '$probe' too (gate-check exit $rc)"
  rm -rf "$d"
}
check_root_guards      "a backslash root is normalised and still guards"  'Web\API'  'Web/API/probe.ts'
check_root_guards      "a dotted root guards its own directory"          'Web.Api'  'Web.Api/probe.ts'
check_root_never_guards "the dot in a dotted root is literal, not a wildcard, so it never guards a look-alike" \
                                                                          'Web.Api'  'WebXApi/probe.ts'

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
