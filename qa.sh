#!/usr/bin/env bash
#
# claude-studio repository self-test
#
# verify.sh checks an INSTALL. This checks the TEMPLATES — the things an
# install is built from. Run it before every release and in CI.
#
# It is deliberately strict about the failures that are invisible at install
# time and expensive later:
#   - an agent whose `name:` does not match its filename never gets delegated to
#   - a duplicate agent name silently shadows one of them
#   - a placeholder nothing substitutes leaves a hook inert forever
#   - a manifest count that drifts from the README makes the docs a liability
#
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SRC" || exit 1

# --mutate: can these suites FAIL? Reintroduces each defect this repository has
# actually shipped and requires the named suite to go red. See test/mutation.sh.
if [ "${1:-}" = "--mutate" ]; then
  shift
  exec bash test/mutation.sh "$@"
fi

# QA_SKIP_SUITES=1 checks template SHAPE only, skipping section 13's behaviour
# suites. They are the slowest part by an order of magnitude, and they are also
# what test/mutation.sh drives directly -- so running them once per mutated
# tree, from inside qa.sh, multiplies the cost of a mutation run by four for no
# extra signal. Never set it in CI: the shape checks alone do not test what any
# hook DOES, which is the whole point of section 13.
QA_SKIP_SUITES="${QA_SKIP_SUITES:-0}"

PASS=0; FAIL=0; WARN=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$1"; WARN=$((WARN+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

VALID_PLANS="pro max max20x"
VALID_MODELS="haiku sonnet opus"

# Read a scalar from a markdown file's YAML frontmatter.
fm() {  # fm <file> <key>
  sed -n '/^---$/,/^---$/p' "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -1
}

printf '\033[1mclaude-studio repository self-test\033[0m\n'
printf '\033[2m%s\033[0m\n' "$SRC"

# ---------------------------------------------------------------- 1. syntax
head_ "1. Syntax"
for f in install.sh configure.sh verify.sh qa.sh test/*.sh templates/common/hooks/*.sh templates/common/scripts/*.sh; do
  bash -n "$f" 2>/dev/null && pass "bash: $(basename "$f")" || fail "bash: $f"
done
if command -v python3 >/dev/null 2>&1; then
  for f in templates/skills/*/scripts/*.py; do
    python3 -m py_compile "$f" 2>/dev/null && pass "python: $(basename "$f")" || fail "python: $f"
  done
fi
if command -v jq >/dev/null 2>&1; then
  echo '[{},{}]' | jq -f templates/common/merge-settings.jq >/dev/null 2>&1 \
    && pass "jq: merge-settings.jq" || fail "jq: merge-settings.jq does not parse"
  while IFS= read -r f; do
    jq empty "$f" 2>/dev/null && pass "json: ${f#templates/}" || fail "json: $f is not valid JSON"
  done < <(find templates \( -name '*.json' -o -name '*.json.tmpl' \) -print)
fi

# ------------------------------------------------------------- 2. agent pool
head_ "2. Agent definitions"
declare -A SEEN_NAME
for f in templates/agents/*.md; do
  b="$(basename "$f" .md)"
  n="$(fm "$f" name)"
  [ "$n" = "$b" ] || fail "$b: frontmatter name is '$n' — delegation resolves by name, so it must match the filename"
  # A duplicate name shadows one definition with no error anywhere.
  if [ -n "${SEEN_NAME[$n]:-}" ]; then
    fail "duplicate agent name '$n' in $b.md and ${SEEN_NAME[$n]}"
  else
    SEEN_NAME[$n]="$b.md"
  fi
  d="$(fm "$f" description)"
  [ -n "$d" ] || fail "$b: no description — it will never auto-trigger"
  [ ${#d} -ge 40 ] || warn "$b: description is only ${#d} chars; delegation accuracy depends on it"
  m="$(fm "$f" model)"
  case " $VALID_MODELS " in
    *" $m "*) ;;
    *) fail "$b: model '$m' is not one of: $VALID_MODELS" ;;
  esac
  [ -n "$(fm "$f" tools)" ] || fail "$b: no tools declared"
done
[ "$FAIL" = 0 ] && pass "$(ls templates/agents/*.md | wc -l) agents: names, descriptions, models and tools all well-formed"

head_ "3. Read-only agents cannot write"
# An agent the pipeline calls "read-only" that can still write is a silent
# violation of the verify-phase contract.
for b in code-reviewer reviewer security-auditor perf-a11y-auditor seo-auditor; do
  f="templates/agents/$b.md"; [ -f "$f" ] || continue
  t="$(fm "$f" tools)"; dt="$(fm "$f" disallowedTools)"
  if printf '%s' "$t" | grep -qE '\b(Write|Edit)\b'; then
    fail "$b is a verify-phase auditor but lists Write/Edit in tools"
  elif printf '%s' "$dt" | grep -qE '\b(Write|Edit)\b'; then
    pass "$b: read-only (Write/Edit disallowed)"
  else
    pass "$b: read-only (Write/Edit not granted)"
  fi
done

# --------------------------------------------------------------- 4. skills
head_ "4. Skill definitions"
for f in templates/skills/*/SKILL.md templates/tiers/*/skills/*/SKILL.md; do
  [ -e "$f" ] || continue
  rel="${f#templates/}"
  [ -n "$(fm "$f" description)" ] && pass "skill: $rel" || fail "skill: $rel has no description"
done

head_ "5. Side-effecting skills are not model-invocable"
# A skill that writes files or runs a suite must not be something Claude can
# decide to run on its own.
for s in feature handoff report studio-report debate ci-scaffold security-audit \
         phase-idea phase-plan phase-test phase-create phase-verify phase-document; do
  f="templates/skills/$s/SKILL.md"; [ -f "$f" ] || continue
  if grep -q '^disable-model-invocation:[[:space:]]*true' "$f"; then
    pass "/$s: disable-model-invocation set"
  else
    fail "/$s has side effects but Claude can invoke it unprompted"
  fi
done

# ---------------------------------------------------------------- 6. rules
head_ "6. Path-scoped rules"
for f in templates/rules/*.md; do
  b="$(basename "$f" .md)"
  if sed -n '/^---$/,/^---$/p' "$f" | grep -q '^paths:'; then
    pass "rule: $b.md is path-scoped"
  else
    fail "rule: $b.md has no paths: frontmatter — it would load in every session"
  fi
done

# ------------------------------------------------------------ 7. manifests
head_ "7. Tier manifests"
for t in $VALID_PLANS; do
  M="templates/tiers/$t/manifest.conf"
  [ -f "$M" ] || { fail "tier $t: no manifest"; continue; }
  # shellcheck source=/dev/null
  ( . "$M"
    ok=1
    for req in TIER_ID TIER_NAME TIER_AGENTS TIER_SKILLS TIER_RULES TIER_PHASES; do
      [ -n "${!req:-}" ] || { echo "MISSING:$req"; ok=0; }
    done
    [ "$TIER_ID" = "$t" ] || echo "IDMISMATCH:$TIER_ID"
    # Every named resource must resolve, tier override first.
    for a in $TIER_AGENTS; do
      [ -f "templates/tiers/$t/agents/$a.md" ] || [ -f "templates/agents/$a.md" ] || echo "NOAGENT:$a"
    done
    for s in $TIER_SKILLS; do
      [ -d "templates/tiers/$t/skills/$s" ] || [ -d "templates/skills/$s" ] || echo "NOSKILL:$s"
    done
    for r in $TIER_RULES; do
      [ -f "templates/tiers/$t/rules/$r.md" ] || [ -f "templates/rules/$r.md" ] || echo "NORULE:$r"
    done
    # Duplicates in a manifest install the same file twice and inflate counts.
    for kind in AGENTS SKILLS RULES; do
      v="TIER_$kind"
      dup="$(printf '%s\n' ${!v} | sort | uniq -d | tr '\n' ' ')"
      [ -n "$dup" ] && echo "DUP:$kind:$dup"
    done
    # The installer advertises TIER_OPUS_AGENTS as "where the cost is". If it
    # disagrees with the frontmatter, that claim is wrong.
    for a in ${TIER_OPUS_AGENTS:-}; do
      case " $TIER_AGENTS " in *" $a "*) ;; *) echo "OPUSNOTINTIER:$a"; continue ;; esac
      m=$(sed -n '/^---$/,/^---$/p' "templates/agents/$a.md" 2>/dev/null | sed -n 's/^model:[[:space:]]*//p' | head -1)
      [ "$m" = "opus" ] || echo "OPUSCLAIM:$a=$m"
    done
    for a in $TIER_AGENTS; do
      m=$(sed -n '/^---$/,/^---$/p' "templates/agents/$a.md" 2>/dev/null | sed -n 's/^model:[[:space:]]*//p' | head -1)
      [ "$m" = "opus" ] || continue
      case " ${TIER_OPUS_AGENTS:-} " in *" $a "*) ;; *) echo "OPUSUNLISTED:$a" ;; esac
    done
    # UI-prune lists must name things this tier actually installs.
    for a in ${TIER_UI_AGENTS:-}; do
      case " $TIER_AGENTS " in *" $a "*) ;; *) echo "UIAGENT:$a" ;; esac
    done
    for s in ${TIER_UI_SKILLS:-}; do
      case " $TIER_SKILLS " in *" $s "*) ;; *) echo "UISKILL:$s" ;; esac
    done
    for r in ${TIER_UI_RULES:-}; do
      case " $TIER_RULES " in *" $r "*) ;; *) echo "UIRULE:$r" ;; esac
    done
    [ "$ok" = 1 ] || true
  ) > /tmp/qa_manifest_$$ 2>&1
  if [ -s /tmp/qa_manifest_$$ ]; then
    while read -r line; do fail "tier $t: $line"; done < /tmp/qa_manifest_$$
  else
    pass "tier $t: manifest complete and internally consistent"
  fi
  rm -f /tmp/qa_manifest_$$
  for req in CLAUDE.md.tmpl settings.json.tmpl gate.json; do
    [ -f "templates/tiers/$t/$req" ] && pass "tier $t: $req present" \
      || fail "tier $t: $req missing"
  done
done

# ------------------------------------------------------- 8. placeholders
head_ "8. Placeholder coverage"
# A placeholder nothing substitutes leaves the file containing it inert
# forever, and configure.sh reports "all resolved" because it only greps for
# the ones it knows.
SUBST="$(grep -oE '"[A-Z_]+=\$' configure.sh | tr -d '"=$' ; \
         grep -oE 's\|\{\{[A-Z_]+\}\}' install.sh | sed 's/s|{{//; s/}}//')"
USED="$(grep -rhoE '\{\{[A-Z_]+\}\}' templates/ | tr -d '{}' | sort -u)"
missing=""
for p in $USED; do
  printf '%s\n' "$SUBST" | grep -qx "$p" || missing="$missing $p"
done
if [ -n "$missing" ]; then
  fail "placeholders used in templates but never substituted:$missing"
else
  pass "every {{PLACEHOLDER}} in templates/ is substituted by install.sh or configure.sh"
fi

# --------------------------------------------------- 9. docs vs reality
head_ "9. Documentation consistency"
for t in $VALID_PLANS; do
  # shellcheck source=/dev/null
  . "templates/tiers/$t/manifest.conf"
  na=$(printf '%s\n' $TIER_AGENTS | wc -w); ns=$(printf '%s\n' $TIER_SKILLS | wc -w)
  nr=$(printf '%s\n' $TIER_RULES | wc -w)
  label="$TIER_NAME"
  row="$(grep -E "^\| \*\*$label\*\* \|" README.md | head -1)"
  if [ -z "$row" ]; then
    warn "README has no summary row for $label"
  else
    ra=$(printf '%s' "$row" | awk -F'|' '{gsub(/ /,"",$3); print $3}')
    rs=$(printf '%s' "$row" | awk -F'|' '{gsub(/ /,"",$4); print $4}')
    rr=$(printf '%s' "$row" | awk -F'|' '{gsub(/ /,"",$5); print $5}')
    if [ "$ra" = "$na" ] && [ "$rs" = "$ns" ] && [ "$rr" = "$nr" ]; then
      pass "README $label row matches manifest ($na/$ns/$nr)"
    else
      fail "README $label says $ra/$rs/$rr but manifest has $na/$ns/$nr agents/skills/rules"
    fi
  fi
done
for d in README.md docs/DESIGN-RATIONALE.md docs/SETUP-SPEC.md docs/DESIGN-STACK.md LICENSE; do
  [ -f "$d" ] && pass "present: $d" || fail "missing: $d"
done

# ---------------------------------------------- 10. no broken repo links
head_ "10. Internal links"
bad=0
while IFS= read -r link; do
  [ -e "$link" ] || { fail "broken relative link in docs: $link"; bad=1; }
done < <(grep -rhoE '\]\((docs/[A-Za-z0-9._/-]+|templates/[A-Za-z0-9._/-]+)\)' README.md docs/*.md \
         | sed 's/^](//; s/)$//' | sort -u)
[ "$bad" = 0 ] && pass "all relative doc links resolve"

# Files that ship INTO a project must not link to repo-only paths.
shipbad=0
while IFS= read -r f; do
  grep -qE '\]\(\.\./|\]\(docs/' "$f" && { fail "$f ships into a project but links to a repo-relative path"; shipbad=1; }
done < <(find templates -name '*.md' -o -name '*.tmpl')
[ "$shipbad" = 0 ] && pass "shipped templates contain no repo-relative links"

# ------------------------------------------- 11. guards that cannot be talked out of
head_ "11. Guard hygiene"

# An exemption matched by SUBSTRING against a string the caller fully controls
# is not an exemption. `case "$CMD" in *".claude/hooks/"*) exit 0 ;;` is disabled
# by appending a trailing comment -- one token, and the whole shell gate is off.
# The safest allowlist is the one you can delete.
# Comment lines are stripped first: both of these checks describe a pattern
# that the hooks now carry a comment ABOUT, and a check that fires on its own
# documentation is a check people learn to ignore.
uncommented() { sed 's/[[:space:]]*#.*$//' "$1"; }

subbad=0
for f in templates/common/hooks/*.sh; do
  uncommented "$f" | grep -qE 'case "\$CMD" in.*\*"\.claude' && {
    fail "$(basename "$f"): exempts commands by substring match on caller-controlled text"
    subbad=1
  }
done
[ "$subbad" = 0 ] && pass "no hook exempts commands by substring"

# An allow rule has to name a LOCATION, not a substring. `*test*` ungates every
# source file whose name merely contains those letters -- LatestReport.ts,
# InspectorController.ts -- and both walked past a closed gate.
if uncommented templates/common/hooks/gate-check.sh | grep -qE '\*test\*|\*spec\*|\*Test\*'; then
  fail "gate-check.sh allows paths by unanchored substring (*test*/*spec*)"
else
  pass "gate-check allow rules are anchored to locations, not substrings"
fi

# A guard that authorises the string it was handed, rather than the file that
# string resolves to, is not a guard. Six of seven path spellings once walked
# through, including the absolute one the harness always sends.
if grep -q 'studio_normalise_path' templates/common/hooks/gate-check.sh 2>/dev/null; then
  pass "gate-check canonicalises the path before authorising"
else
  fail "gate-check canonicalises before authorising (absolute paths bypass a ^-anchored regex)"
fi

# A pipeline reports its LAST command's status, so `cmd | grep | head` turns a
# red suite green -- and every VERIFY gate downstream reads that 0 as evidence.
if uncommented templates/common/hooks/filter-output.sh | grep -q 'PIPESTATUS'; then
  pass "filter-output preserves the original exit status"
else
  fail "filter-output preserves exit status (without it a failing suite reports success)"
fi

# Both doors, or neither. gate-check.sh only ever sees Edit and Write.
if [ -f templates/common/hooks/bash-gate.sh ]; then
  pass "a Bash write-gate exists"
else
  fail "a Bash write-gate exists (else the gate is one sed -i from irrelevant)"
fi
for t in templates/tiers/*/settings.json.tmpl; do
  grep -q 'bash-gate.sh' "$t" \
    && pass "$(basename "$(dirname "$t")"): bash-gate registered" \
    || fail "$(basename "$(dirname "$t")"): bash-gate is NOT registered on Bash"
done

# ------------------------------------------------ 12. nothing binary ships
head_ "12. Nothing compiled or generated is tracked"
# install.sh copies templates/skills/<name>/ wholesale, so a committed
# __pycache__ lands in every user's repository: bytecode nobody reviewed,
# shipped by a tool whose entire pitch is that gates close on evidence.
binbad=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  fail "tracked build artifact: $f"
  binbad=1
done < <(git ls-files 2>/dev/null | grep -E '(__pycache__/|\.pyc$|\.pyo$|\.DS_Store$)' || true)
[ "$binbad" = 0 ] && pass "no compiled or OS artifacts tracked under templates/"

# ---------------------------------------------------- 13. hook behaviour
head_ "13. Behaviour suites"
# qa.sh checks the templates' SHAPE. This is the only thing that checks what
# they DO -- against the bypasses, not the happy path.
if [ "$QA_SKIP_SUITES" = 1 ]; then
  warn "behaviour suites SKIPPED (QA_SKIP_SUITES=1) — shape checks only"
elif [ -f test/hooks.sh ]; then
  if bash test/hooks.sh >/dev/null 2>&1; then
    pass "every bypass shape reaches the same verdict as the plain one"
  else
    fail "test/hooks.sh fails -- run it directly to see which shape walks through"
  fi
else
  fail "test/hooks.sh exists"
fi

# The profile is the file every hook is configured FROM, and its values are
# substituted into hook source. A value that corrupts a hook has to be refused
# at configure time, not discovered when the hook dies on the next Bash call.
if [ "$QA_SKIP_SUITES" = 1 ]; then
  :
elif [ -f test/profile-validation.sh ]; then
  if bash test/profile-validation.sh >/dev/null 2>&1; then
    pass "configure.sh refuses profile values that would corrupt a hook"
  else
    fail "test/profile-validation.sh fails -- run it directly"
  fi
else
  fail "test/profile-validation.sh exists"
fi

# A standard with no measurement is a preference. The ratchet is what turns the
# rules' file-size bar into a number, and it has to ratchet in both directions
# or it is either useless or unadoptable.
if [ "$QA_SKIP_SUITES" = 1 ]; then
  :
elif [ -f test/ratchet.sh ]; then
  if bash test/ratchet.sh >/dev/null 2>&1; then
    pass "the size ratchet shrinks, refuses growth, and refuses new crossings"
  else
    fail "test/ratchet.sh fails -- run it directly"
  fi
else
  fail "test/ratchet.sh exists"
fi

# The coverage gate parses five ecosystems' summary output, and a parser that
# reads the WRONG number is worse than one that fails: a floor is written down
# once and trusted for years. Four of the five were wrong until this suite
# existed -- two of them silently, reporting a per-unit figure as the project
# total.
if [ "$QA_SKIP_SUITES" = 1 ]; then
  :
elif [ -f test/coverage.sh ]; then
  if bash test/coverage.sh >/dev/null 2>&1; then
    pass "every coverage parser reads the total, and output without one is refused"
  else
    fail "test/coverage.sh fails -- run it directly"
  fi
else
  fail "test/coverage.sh exists"
fi

printf '\n\033[1m%d passed, %d failed, %d warnings\033[0m\n' "$PASS" "$FAIL" "$WARN"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
