#!/usr/bin/env bash
#
# claude-studio integration test
#
# qa.sh checks the templates. verify.sh checks one install. This exercises the
# full lifecycle — install, configure, verify, upgrade, switch tier, uninstall
# — across six stacks and the edge cases that have actually broken before.
#
# Sections G2 and G3 are regressions for two shipped bugs, both of which made
# the pipeline silently stop enforcing its central promise. Do not delete them.
#
# Requires: bash, git, jq, python3. Writes only under a temp directory.
#
set -uo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/claude-studio-it.XXXXXX")"
trap 'rm -rf "$W"' EXIT
P=0; F=0
ok()  { printf '  \033[32mok  \033[0m %s\n' "$1"; P=$((P+1)); }
no()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; F=$((F+1)); }
hd()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
strip(){ sed 's/\x1b\[[0-9;]*m//g'; }

mk() { # mk <dir> <stack>
  rm -rf "$1"; mkdir -p "$1"; ( cd "$1" || exit
  git init -q . && git config user.email t@t && git config user.name t
  case "$2" in
    node)   mkdir -p src/styles tests; touch tsconfig.json src/styles/tokens.css
            echo 'export const a=1' > src/a.ts
            echo '{"name":"n","scripts":{"dev":"vite","test":"vitest run","build":"vite build","lint":"eslint --fix .","typecheck":"tsc --noEmit"}}' > package.json ;;
    laravel) mkdir -p app tests vendor/bin resources/css; touch resources/css/tokens.css
            echo '{"require":{"laravel/framework":"^11"}}' > composer.json
            echo 'x' > app/S.php; touch vendor/bin/pint vendor/bin/phpstan ;;
    python) mkdir -p src tests; echo 'x=1' > src/a.py; echo '[project]' > pyproject.toml ;;
    go)     mkdir -p src; echo 'package main' > src/m.go; printf 'module d\n\ngo 1.22\n' > go.mod ;;
    rust)   mkdir -p src; echo 'fn main(){}' > src/main.rs; printf '[package]\nname="d"\n' > Cargo.toml ;;
    empty)  : ;;
  esac
  git add -A >/dev/null 2>&1; git commit -qm i >/dev/null 2>&1 || true )
}

fill() { # fill <dir> — confirm the profile with plausible values
  python3 - "$1" <<'PY'
import re,sys,pathlib
p=pathlib.Path(sys.argv[1])/'docs/setup/PROFILE.md'
if not p.exists(): sys.exit(0)
t=p.read_text()
generic={'Dev command':'`true`','Test command (non-watching)':'`true`','Single-test command':'`true`',
 'Format command (fixes)':'`true`','Type-check command':'`true`','Build command':'`true`',
 'Dependency audit command':'`true`','Source roots':'src','Front-end root':'src','Test root':'tests',
 'Design token file':'src/styles/tokens.css','Has UI':'yes','Project name':'demo','Stack':'test',
 'Package manager':'npm'}
out=[]
for line in t.splitlines():
    m=re.match(r'^\|\s*([^|]+?)\s*\|',line)
    if m and m.group(1) in generic:
        parts=line.split('|'); parts[2]=' %s '%generic[m.group(1)]; line='|'.join(parts)
    out.append(line)
p.write_text('\n'.join(out)+'\n')
PY
}

# ---------------------------------------------------------------- stacks
hd "A. Install + configure + verify across stacks (max20x)"
for stack in node laravel python go rust empty; do
  d="$W/$stack"; mk "$d" "$stack"
  if $S/install.sh --plan max20x --target "$d" >/dev/null 2>&1; then
    fill "$d"
    $S/configure.sh --target "$d" >/dev/null 2>&1
    if $S/verify.sh --target "$d" >"$W/v_$stack.log" 2>&1; then
      ok "$stack: install → configure → verify ($(grep -oE '[0-9]+ passed' "$W/v_$stack.log" | head -1))"
    else
      no "$stack: verify failed"; grep -E 'FAIL' "$W/v_$stack.log" | strip | head -3 | sed 's/^/       /'
    fi
  else
    no "$stack: install failed"
  fi
done

# ------------------------------------------------------------- idempotency
hd "B. Idempotency"
d="$W/node"
# f(f(x)) == f(x). The very first install COPIES settings.json from the
# template; every later one merges it through jq, which reformats once. So
# normalise with one --force, then compare the next two runs.
$S/install.sh --plan max20x --target "$d" --force >/dev/null 2>&1
$S/configure.sh --target "$d" >/dev/null 2>&1
find "$d/.claude" -type f -exec md5sum {} \; 2>/dev/null | sort -k2 > "$W/before.md5"
$S/install.sh --plan max20x --target "$d" --force >/dev/null 2>&1
$S/configure.sh --target "$d" >/dev/null 2>&1
find "$d/.claude" -type f -exec md5sum {} \; 2>/dev/null | sort -k2 > "$W/after.md5"
# studio.json carries a timestamp; exclude it
# studio.json carries a timestamp and .backup-* is expected on a re-install
grep -vE "studio\.json|\.backup-" "$W/before.md5" > "$W/b2"
grep -vE "studio\.json|\.backup-" "$W/after.md5" > "$W/a2"
diff -q "$W/b2" "$W/a2" >/dev/null && ok "re-install + re-configure is byte-identical" \
  || { no "re-install drifts"; diff "$W/b2" "$W/a2" | head -5 | sed 's/^/       /'; }

# ---------------------------------------------------------------- dry run
hd "C. Dry run writes nothing"
d="$W/dry"; mk "$d" node
before=$(find "$d" -type f | wc -l)
$S/install.sh --plan max --target "$d" --dry-run >/dev/null 2>&1
after=$(find "$d" -type f | wc -l)
[ "$before" = "$after" ] && ok "dry-run on a clean project changed no files ($before)" || no "dry-run wrote files ($before -> $after)"

# --------------------------------------------------------- paths w/ spaces
hd "D. Path with spaces and punctuation"
d="$W/we ird (dir)"; mk "$d" node
if $S/install.sh --plan max20x --target "$d" >/dev/null 2>&1; then
  fill "$d"; $S/configure.sh --target "$d" >/dev/null 2>&1
  n=$(ls "$d/.claude/agents" 2>/dev/null | wc -l)
  [ "$n" = 24 ] && ok "installed 24 agents into a path with spaces" || no "path with spaces: got $n agents"
  $S/verify.sh --target "$d" >/dev/null 2>&1 && ok "verify passes in a path with spaces" || no "verify fails in a path with spaces"
else
  no "install failed on a path with spaces"
fi

# ------------------------------------------------------------- degradation
hd "E. Missing dependencies degrade, not crash"
d="$W/nojq"; mk "$d" node
FAKE=$(mktemp -d); for t in bash env sh git sed awk grep cat cp mkdir rm chmod date basename dirname find head tail tr sort uniq printf ls wc python3 diff mv touch rmdir; do
  p=$(command -v $t 2>/dev/null) && ln -sf "$p" "$FAKE/$t"
done
if PATH="$FAKE" $S/install.sh --plan max --target "$d" >"$W/nojq.log" 2>&1; then
  grep -q 'jq not found' "$W/nojq.log" && ok "no jq: warns explicitly" || no "no jq: installed without warning"
  [ -f "$d/.claude/settings.json" ] && ok "no jq: settings.json still written" || no "no jq: no settings.json"
else
  no "no jq: install crashed"; tail -3 "$W/nojq.log" | sed 's/^/       /'
fi
d="$W/nogit"; rm -rf "$d"; mkdir -p "$d/src"; echo '{"name":"x"}' > "$d/package.json"
$S/install.sh --plan pro --target "$d" >"$W/nogit.log" 2>&1 \
  && { grep -q 'not a git repository' "$W/nogit.log" && ok "no git repo: warns and continues" || no "no git repo: no warning"; } \
  || no "no git repo: install crashed"

# ------------------------------------------------------- existing files
hd "F. Existing project files are respected"
d="$W/existing"; mk "$d" node
printf '# My own constitution\nDo not clobber me.\n' > "$d/CLAUDE.md"
mkdir -p "$d/.claude"
printf '{"env":{"MINE":"1"},"permissions":{"deny":["Read(./vault)"]}}' > "$d/.claude/settings.json"
$S/install.sh --plan max20x --target "$d" --force >/dev/null 2>&1
grep -q 'Do not clobber me' "$d/CLAUDE.md" && ok "existing CLAUDE.md preserved" || no "CLAUDE.md was clobbered"
[ -f "$d/CLAUDE.studio.md" ] && ok "tier constitution written to CLAUDE.studio.md" || no "no CLAUDE.studio.md"
[ "$(jq -r '.env.MINE' "$d/.claude/settings.json")" = "1" ] && ok "existing settings env preserved" || no "settings env lost"
jq -e '.permissions.deny | any(.=="Read(./vault)")' "$d/.claude/settings.json" >/dev/null && ok "existing deny rule preserved" || no "deny rule lost"
jq -e '.hooks.PreToolUse | length >= 2' "$d/.claude/settings.json" >/dev/null && ok "studio hooks added" || no "studio hooks missing"

# -------------------------------------------------------------- gate behaviour
hd "G. Gate hook enforces the phase contract"
d="$W/node"; cd "$d" || exit 1
G=.claude/state/gate.json; SAVED=$(cat $G)
rc() { printf '%s' "$2" | bash .claude/hooks/gate-check.sh >/dev/null 2>&1; echo $?; }
printf '{"phase":"plan"}' > $G
[ "$(rc x '{"tool_input":{"file_path":"src/pay.ts"}}')" = 2 ] && ok "blocks src/ during plan" || no "did NOT block src/ during plan"
[ "$(rc x '{"tool_input":{"file_path":"docs/specs/a/idea.md"}}')" = 0 ] && ok "allows docs/ during plan" || no "blocked docs/"
[ "$(rc x '{"tool_input":{"file_path":"tests/a.test.ts"}}')" = 0 ] && ok "allows tests/ during plan" || no "blocked tests/"
[ "$(rc x '{"tool_input":{"file_path":"sandbox/proto.tsx"}}')" = 0 ] && ok "allows sandbox/ outside source roots (DESIGN-STACK 4)" || no "blocked sandbox/"
rcb() { printf '%s' "$2" | bash .claude/hooks/bash-gate.sh >/dev/null 2>&1; echo $?; }
[ "$(rcb x '{"tool_input":{"command":"sed -i s/a/b/ src/pay.ts"}}')" = 2 ] \
  && ok "blocks a shell write to src/ during plan" || no "shell write to src/ walked through"
[ "$(rcb x '{"tool_input":{"command":"cat src/pay.ts"}}')" = 0 ] \
  && ok "allows an ordinary read during plan" || no "blocked an ordinary read"
# The gate wants the IDEA and TEST answers, not just a phase name: a boolean
# gate certifies that a plan exists and never what it said.
printf '{"phase":"create","problem":"integration fixture: pay.ts stands in for real source","red":"n/a: synthetic fixture with no behaviour to pin"}' > $G
[ "$(rc x '{"tool_input":{"file_path":"src/pay.ts"}}')" = 0 ] && ok "allows src/ during create" || no "blocked src/ during create"
printf '%s' "$SAVED" > $G
cd "$S" >/dev/null || exit 1

hd "G2. An UNCONFIGURED gate fails closed (regression)"
# Regression: the source-root regex test used to run before the placeholder
# guard. An unsubstituted {{SOURCE_ROOTS_REGEX}} matches nothing, so every
# source write was silently ALLOWED — the inverse of this hook's contract.
d="$W/unconf"; mk "$d" node
$S/install.sh --plan pro --target "$d" >/dev/null 2>&1   # deliberately NOT configured
cd "$d" || exit 1
[ "$(rc x '{"tool_input":{"file_path":"src/pay.ts"}}')" = 2 ] \
  && ok "unconfigured gate BLOCKS source" || no "unconfigured gate allowed a source write"
[ "$(rc x '{"tool_input":{"file_path":"docs/setup/PROFILE.md"}}')" = 0 ] \
  && ok "unconfigured gate still allows docs (repair path open)" || no "unconfigured gate blocked its own repair path"
cd "$S" >/dev/null || exit 1

hd "G3. --force preserves a confirmed profile (regression)"
# Regression: --force re-rendered PROFILE.md back to NEEDS_REVIEW, so the
# documented upgrade path silently un-configured every hook.
d="$W/upgrade"; mk "$d" node
$S/install.sh --plan max --target "$d" >/dev/null 2>&1
fill "$d"; $S/configure.sh --target "$d" >/dev/null 2>&1
$S/install.sh --plan max --target "$d" --force >/dev/null 2>&1
grep -q NEEDS_REVIEW "$d/docs/setup/PROFILE.md" \
  && no "--force reset the confirmed profile to NEEDS_REVIEW" \
  || ok "--force preserved the confirmed profile"
$S/configure.sh --target "$d" >/dev/null 2>&1 \
  && ok "configure.sh still runs after --force" || no "configure.sh refuses after --force"
grep -q '{{' "$d/.claude/hooks/gate-check.sh" \
  && no "gate hook left with placeholders after the documented upgrade path" \
  || ok "gate hook stays configured through the upgrade path"

# ---------------------------------------------------------- tier lifecycle
hd "H. Tier switch both directions, then uninstall"
d="$W/tier"; mk "$d" node
$S/install.sh --plan pro --target "$d" >/dev/null 2>&1
a1=$(ls "$d/.claude/agents" | wc -l)
$S/install.sh --plan max20x --target "$d" --force >/dev/null 2>&1
a2=$(ls "$d/.claude/agents" | wc -l)
$S/install.sh --plan pro --target "$d" --force >/dev/null 2>&1
a3=$(ls "$d/.claude/agents" | wc -l)
[ "$a1" = 7 ] && [ "$a2" = 24 ] && [ "$a3" = 7 ] && ok "pro(7) → max20x(24) → pro(7), no leftovers" || no "tier switch drift: $a1 → $a2 → $a3"
$S/verify.sh --target "$d" >/dev/null 2>&1; [ $? -le 1 ] && ok "verify runs after round-trip" || no "verify errored after round-trip"
mkdir -p "$d/.claude/skills/thirdparty"; echo x > "$d/.claude/skills/thirdparty/SKILL.md"
echo x > "$d/.claude/agents/house.md"
$S/install.sh --target "$d" --uninstall >/dev/null 2>&1
[ -f "$d/.claude/skills/thirdparty/SKILL.md" ] && ok "uninstall preserved a third-party skill" || no "uninstall deleted a third-party skill"
[ -f "$d/.claude/agents/house.md" ] && ok "uninstall preserved a house agent" || no "uninstall deleted a house agent"
[ -d "$d/.claude/hooks" ] && no "uninstall left hooks behind" || ok "uninstall removed studio hooks"

# ------------------------------------------------------------- no-UI path
hd "I. No-UI project prunes correctly"
d="$W/noui"; mk "$d" go
$S/install.sh --plan max20x --target "$d" >/dev/null 2>&1
python3 - "$d" <<'PY'
import re,sys,pathlib
p=pathlib.Path(sys.argv[1])/'docs/setup/PROFILE.md'
fix={'Has UI':'no','Source roots':'src','Front-end root':'n/a','Test root':'src','Design token file':'n/a',
 'Dev command':'`true`','Test command (non-watching)':'`true`','Single-test command':'`true`',
 'Format command (fixes)':'`true`','Type-check command':'`true`','Build command':'`true`',
 'Dependency audit command':'`true`'}
out=[]
for line in p.read_text().splitlines():
    m=re.match(r'^\|\s*([^|]+?)\s*\|',line)
    if m and m.group(1) in fix:
        parts=line.split('|'); parts[2]=' %s '%fix[m.group(1)]; line='|'.join(parts)
    out.append(line)
p.write_text('\n'.join(out)+'\n')
PY
$S/configure.sh --target "$d" >/dev/null 2>&1
[ -f "$d/.claude/agents/seo-auditor.md" ] && no "no-UI: seo-auditor survived" || ok "no-UI: UI agents pruned"
[ -f "$d/.claude/rules/frontend.md" ] && no "no-UI: frontend.md survived" || ok "no-UI: frontend rule pruned"
grep -q 'studio:frontend-direction' "$d/CLAUDE.md" && no "no-UI: direction block survived" || ok "no-UI: direction block stripped"
ls "$d"/*.studio.bak >/dev/null 2>&1 && no "no-UI: left a .studio.bak file" || ok "no-UI: no stray backup files"
$S/verify.sh --target "$d" >/dev/null 2>&1 && ok "no-UI: verify passes (pruned items are SKIPs)" || no "no-UI: verify failed"

# ---------------------------------------------------------------- reports
hd "J. Report scripts run standalone"
d="$W/node"
for s in structure docs_audit; do
  python3 "$S/templates/skills/studio-report/scripts/$s.py" "$d" "$W/rep" >/dev/null 2>&1 \
    && ok "$s.py runs and writes JSON" || no "$s.py failed"
done
python3 "$S/templates/skills/studio-report/scripts/tokens.py" 2099-01 "$W/rep" >/dev/null 2>&1 \
  && ok "tokens.py handles a period with no data" || no "tokens.py failed on empty period"
for j in "$W/rep"/*.json; do jq empty "$j" 2>/dev/null || no "invalid JSON: $j"; done
ok "all report JSON is valid"

printf '\n\033[1m%d ok, %d failed\033[0m\n' "$P" "$F"
[ "$F" -gt 0 ] && exit 1; exit 0
