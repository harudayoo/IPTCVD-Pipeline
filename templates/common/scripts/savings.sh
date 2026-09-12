#!/usr/bin/env bash
#
# What the two big token levers actually did, from what they recorded.
#
#   bash .claude/scripts/savings.sh              # both sections
#   bash .claude/scripts/savings.sh --since 2026-08
#   bash .claude/scripts/savings.sh --record     # share this month with the team
#   bash .claude/scripts/savings.sh --record 2026-08
#
# The raw logs are machine-local and gitignored. --record writes ONE monthly
# row to docs/reports/savings/<you>.tsv, which IS committed -- one file per
# developer, so it can never conflict. Solo, you never need it.
#
# This exists because of DESIGN-RATIONALE §14, which sets the bar for a claim
# about token spend and then names the two shapes:
#
#   defensible      "filter-output fired on 214 runs. Unfiltered averaged
#                    11,400 tokens; filtered averaged 890. Saving: 2.25M."
#   not defensible  "the multi-agent architecture saved 40%."
#
# The difference is a mechanism, a count and a measurement. Everything printed
# below is measured; the estimate/counterfactual line is drawn explicitly and
# said out loud rather than left for the reader to assume.
#
# THE ONE CONVERSION HERE IS AN ESTIMATE. These logs record BYTES, because
# bytes are what a shell can count without a tokeniser. Tokens are reported at
# ~4 bytes each, which is a rule of thumb for English prose and NOT accurate
# for test output -- stack traces, paths and punctuation tokenise worse. Treat
# the byte columns as measured and the token column as indicative, and say so
# when you quote it.
set -uo pipefail

STATE=".claude/state"
FLOG="$STATE/filter-log.tsv"
SLOG="$STATE/session-log.tsv"
SHARED="docs/reports/savings"      # committed; one file per developer
SINCE=""
RECORD=""
BYTES_PER_TOKEN=4

while [ $# -gt 0 ]; do
  case "$1" in
    --since) shift; SINCE="${1:-}" ;;
    --record) shift
      # Optional argument. `--record` alone means the current month.
      case "${1:-}" in
        ""|--*) RECORD="$(date -u '+%Y-%m')" ; [ -n "${1:-}" ] && continue ;;
        *)      RECORD="$1" ;;
      esac ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

# --- who these rows belong to ----------------------------------------------
#
# The raw logs are machine-local by design, so a shared file needs an owner in
# its NAME -- that is the whole reason this never conflicts. Two developers
# never write the same path, so there is no append race to lose.
#
# git identity rather than $USER: it is the identity already attached to every
# commit in the repository, so the name in the file matches the name in the
# blame. The 4 hex of the email disambiguate two people with the same display
# name without putting an address in a committed filename.
who_slug() {
  local n e h
  n="$(git config user.name 2>/dev/null || true)"
  e="$(git config user.email 2>/dev/null || true)"
  [ -n "$n" ] || n="$(whoami 2>/dev/null || echo unknown)"
  n="$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' \
       | sed 's/^-*//; s/-*$//')"
  [ -n "$n" ] || n="unknown"
  if [ -n "$e" ]; then
    h="$(printf '%s' "$e" | cksum 2>/dev/null | awk '{printf "%04x", $1 % 65536}')"
    [ -n "$h" ] && n="$n-$h"
  fi
  printf '%s' "$n"
}

filt() { if [ -n "$SINCE" ]; then grep "^$SINCE" "$1" 2>/dev/null; else cat "$1" 2>/dev/null; fi; }
hr() { printf '\033[1m%s\033[0m\n' "$1"; }

# ------------------------------------------------- 1. the output filter
hr "Output filtering${SINCE:+  ·  since $SINCE}"
if [ ! -s "$FLOG" ]; then
  echo "  no runs recorded yet."
  echo "  filter-output records one row per test/build/typecheck/audit command."
  echo "  An empty log after real work means the hook is not firing — check /hooks."
else
  filt "$FLOG" | awk -v bpt="$BYTES_PER_TOKEN" '
    { n++; raw += $2; flt += $3; if ($4 != 0) fails++ }
    END {
      if (n == 0) { print "  no runs in this period."; exit }
      saved = raw - flt
      printf "  %d runs recorded, %d of them red\n", n, fails
      printf "  unfiltered  %12d bytes   (mean %d)\n", raw, raw/n
      printf "  returned    %12d bytes   (mean %d)\n", flt, flt/n
      printf "  not sent    %12d bytes   (%.1f%% of output)\n", saved, (raw ? saved*100/raw : 0)
      printf "\n  ~%d tokens not sent, at ~%d bytes/token (INDICATIVE, not measured)\n", saved/bpt, bpt
      if (n < 20)
        printf "  Fewer than 20 runs — too small a sample to quote. Keep working.\n"
    }'
fi
echo

# ------------------------------------------------- 2. context hygiene
hr "Context hygiene${SINCE:+  ·  since $SINCE}"
if [ ! -s "$SLOG" ]; then
  echo "  no sessions recorded yet. session-log.sh fires on SessionStart."
else
  filt "$SLOG" | awk '
    { n++; src[$2]++; if ($2 == "compact") cphase[$3]++ }
    END {
      if (n == 0) { print "  no sessions in this period."; exit }
      printf "  %d session starts:", n
      for (k in src) printf "  %s=%d", k, src[k]
      printf "\n"
      c = src["clear"] + 0; m = src["compact"] + 0
      if (c + m == 0) {
        print "\n  No clears and no compacts. Either the work was short, or the"
        print "  hook is not firing — check /hooks."
      } else {
        printf "\n  clear:compact = %d:%d", c, m
        if (m > c)
          print "  — the window is filling before it is dropped."
        else
          print "  — the lever is being pulled."
      }
      if (m > 0) {
        print "\n  Compacts landed at these gate phases:"
        for (k in cphase) printf "    %-10s %d\n", k, cphase[k]
        print "  A compact mid-CREATE is a feature that overran its window."
        print "  A compact where a /clear belonged is the full conversation"
        print "  re-sent at cache-read price instead of dropped at zero."
      }
    }'
fi
echo
echo "Both logs are appended by hooks and are safe to delete; they are"
echo "measurements, not state. Neither is read by any gate."

# ------------------------------------------------- 3. record, for a team
# Solo, this never runs and nothing is committed. The moment a second person
# works on the repository, one command per month makes the number real for the
# project instead of for whoever happened to generate the report.
if [ -n "$RECORD" ]; then
  ME="$(who_slug)"
  F="$SHARED/$ME.tsv"
  mkdir -p "$SHARED" 2>/dev/null || true
  row=$(
    { grep "^$RECORD" "$FLOG" 2>/dev/null || true; } | awk -v m="$RECORD" '
      { n++; raw += $2; flt += $3 } END { printf "%s\t%d\t%d\t%d", m, n+0, raw+0, flt+0 }'
  )
  srow=$(
    { grep "^$RECORD" "$SLOG" 2>/dev/null || true; } | awk '
      { n++; if ($2=="clear") c++; if ($2=="compact") k++ }
      END { printf "\t%d\t%d\t%d", n+0, c+0, k+0 }'
  )
  # Replace this month's row rather than appending: re-running --record must be
  # idempotent, or a monthly report generated twice doubles the project total.
  TMP="$F.tmp.$$"
  { [ -f "$F" ] && grep -v "^$RECORD	" "$F" 2>/dev/null; printf '%s%s\n' "$row" "$srow"; } \
    | sort > "$TMP" 2>/dev/null && mv "$TMP" "$F" 2>/dev/null
  rm -f "$TMP" 2>/dev/null || true
  echo
  hr "Recorded"
  echo "  $F  ($RECORD)"
  echo "  Commit it. It is one file per developer, so it never conflicts."
fi

# ------------------------------------------------- 4. say the TRUE scope
# Stated HERE, where the numbers are produced, not only in the skill that
# quotes them: a caveat living one document away from a figure is one that gets
# dropped the first time somebody copies the figure.
#
# And COUNTED, never assumed. "These are only your numbers" is wrong the moment
# a teammate commits a file, and a stale caveat is its own kind of wrong number.
echo
nshared=0
[ -d "$SHARED" ] && nshared=$(find "$SHARED" -name '*.tsv' 2>/dev/null | wc -l | tr -d ' ')
if [ "$nshared" -le 1 ]; then
  echo "SCOPE: this machine only — both raw logs are gitignored, so nothing above"
  echo "represents a teammate's sessions. Quote the byte columns, not the token"
  echo "estimate. Sharing a repository with someone? Run:"
  echo "    bash .claude/scripts/savings.sh --record   # then commit $SHARED/"
else
  echo "SCOPE: the figures above are THIS machine. $nshared developers have"
  echo "recorded monthly totals in $SHARED/ — the project-wide"
  echo "number is their sum, not the number printed above:"
  echo
  printf '  %-28s %7s %14s %14s\n' DEVELOPER RUNS UNFILTERED RETURNED
  for f in "$SHARED"/*.tsv; do
    [ -e "$f" ] || continue
    { if [ -n "$SINCE" ]; then grep "^$SINCE" "$f" 2>/dev/null; else cat "$f" 2>/dev/null; fi; } \
      | awk -v d="$(basename "$f" .tsv)" '
          { n += $2; raw += $3; flt += $4 }
          END { if (n) printf "  %-28s %7d %14d %14d\n", d, n, raw, flt }'
  done
  { if [ -n "$SINCE" ]; then grep -h "^$SINCE" "$SHARED"/*.tsv 2>/dev/null; else cat "$SHARED"/*.tsv 2>/dev/null; fi; } \
    | awk '{ n += $2; raw += $3; flt += $4 }
           END { if (n) printf "\n  %-28s %7d %14d %14d\n", "PROJECT", n, raw, flt }'
fi
