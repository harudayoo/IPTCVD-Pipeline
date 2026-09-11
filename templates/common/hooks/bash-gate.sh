#!/usr/bin/env bash
# PreToolUse(Bash): applies the SAME plan gate to source files written through
# the shell that gate-check.sh applies to the Edit/Write tools.
#
# Why this exists: gate-check.sh is registered on `Edit|Write`, so before this
# hook the entire pipeline was one `sed -i` away from irrelevant. Every one of
# these walked straight past a closed gate, and none of them is exotic:
#
#   sed -i 's/x/y/' src/services/dues.ts
#   cat > src/services/brand-new.ts <<'EOF'      # not even the reuse gate
#   cp /tmp/patched.tsx src/pages/x.tsx
#   python - <<PY ... open('src/x.py','w') ... PY
#   npm i left-pad                               # an ungated dependency
#
# A gate that guards one door and not the other produces exactly the same green
# output as a gate that works. That is the failure mode this whole repo exists
# to remove, so leaving the shell door open was not a gap in coverage -- it was
# a correctness bug in the only claim the pipeline makes.
#
# It does NOT re-implement the gate. It extracts the WRITE TARGETS from the
# command and hands each one to gate-check.sh, so there is one set of rules and
# one block message, and adding a key there covers both doors at once.
#
# Deliberately conservative -- it recognises the forms below and FAILS OPEN on
# anything it cannot parse, because a wrong block costs a retry on every
# unrelated command:
#
#   >  >>  >|  &>  redirects     sed -i          tee / sponge
#   cp mv install rsync ln       rm truncate     dd of=
#   perl -i  ruby -i             awk print > f   ed/ex/vi -c wq
#   git checkout/restore/apply/am/revert/mv/rm/clean,  patch
#   npm|pnpm|yarn add,  composer require   (the manifest they rewrite)
#   interpreter writes naming a guarded path
#
# Not covered, and honest about it: a write performed by a script invoked by
# path, or inside an editor session. Those remain the Edit/Write tools' job.
set -uo pipefail
SELF="${BASH_SOURCE[0]}"
HOOKDIR="$(cd "$(dirname "$SELF")" && pwd)"
# shellcheck source=/dev/null
. "$HOOKDIR/_guard.sh"

# Hooks run with cwd at the repo root; gate-check.sh resolves .claude/state
# relative to it, so anchor here rather than trusting the inherited cwd.
cd "$HOOKDIR/../.." 2>/dev/null || exit 0

INPUT=$(cat)

# An unconfigured hook must be loud, but it must not block every shell command
# in the project -- that would make a half-finished install unrepairable. The
# fail-closed decision belongs to gate-check.sh, which this delegates to; if it
# is unconfigured it blocks there, with its own message.
studio_guard "$SELF" >/dev/null 2>&1 || exit 0

PROTECTED="{{SOURCE_ROOTS_REGEX}}"
# Bare roots for the text searches below: "^(src|app)/" -> "(src|app)"
ROOT_ALT=$(printf '%s' "$PROTECTED" | sed 's/^\^//; s/\/$//')
[ -n "$ROOT_ALT" ] || exit 0

CMD="$(json_field "$INPUT" 'tool_input.command')"

# Fail CLOSED when the payload could not be parsed but plainly names a guarded
# root. Every parser failing is not a reason to wave a write through; it is
# exactly when a guard should refuse and say so.
if [ -z "${CMD:-}" ]; then
  if printf '%s' "$INPUT" | grep -qE "${ROOT_ALT}/"; then
    echo 'BLOCKED: could not parse the command from the hook payload, and it names' >&2
    echo '  a guarded source root. Refusing to guess. Re-run the write through the' >&2
    echo '  Edit/Write tool, which is gated separately.' >&2
    exit 2
  fi
  exit 0
fi

# There is deliberately NO exemption list here.
#
# The obvious one -- keep the pipeline's own tooling runnable while the gate is
# closed -- is a trap. Matched by substring against a string the caller fully
# controls, `case "$CMD" in *".claude/scripts/"*) exit 0 ;;` is disabled by
# appending a trailing comment:
#
#   sed -i 's/x/y/' src/app.ts   # .claude/scripts/
#
# One token, and the entire shell gate is off. It is also unnecessary: the
# pipeline's scripts are invoked as `bash .claude/scripts/...`, and `bash` is
# not a program this extracts targets from, so they yield no targets and pass
# anyway. The safest allowlist is the one you can delete.

TARGETS=""
SEGCWD=""
add_target() {
  local t="$1"
  # Strip quotes the shell would have removed, and a trailing ';' or ')'.
  t="${t%\"}"; t="${t#\"}"; t="${t%\'}"; t="${t#\'}"
  t="${t%;}"; t="${t%)}"
  case "$t" in
    ""|/dev/*|-|*'$'*|*'`'*|*'*'*|*'?'*) return ;;   # empty, device, stdin, unexpanded, glob
  esac
  TARGETS="$TARGETS
$t"

  # A RELATIVE target is relative to the SEGMENT's working directory, not only
  # to the repo root -- `cd src/services && echo x > dues.ts` names a guarded
  # file that looks unguarded on its own.
  #
  # Emit BOTH spellings rather than replacing the raw one. A `cd` argument this
  # parser cannot clean would otherwise poison the only target and be dropped at
  # delegation, turning a previously-blocked write into an allowed one. Any
  # single target blocking is enough, so adding a candidate can only tighten the
  # gate, never loosen it.
  case "$t" in
    /*|[A-Za-z]:/*) ;;
    *) [ -n "$SEGCWD" ] && TARGETS="$TARGETS
$SEGCWD/$t" ;;
  esac
}

# --- per-command targets ----------------------------------------------------
# Split the command line into segments so the first word of each is the program.
# `eval`-free and quote-naive on purpose: this is a guard, not a shell.
#
# Redirect extraction lives INSIDE this loop so SEGCWD applies to it. Run once
# over the whole command instead, and `cd src/services && echo x > dues.ts`
# reads as a redirect to an unguarded `dues.ts`. Tracking `cd` across a pipe
# segment is technically over-broad -- `cd x | y` does not persist -- and that
# is the fail-closed direction.
#
# `>|` is a clobber redirect, not a pipe, but it CONTAINS a pipe character, so
# splitting on [;|] would tear `echo x >| f` apart and lose the redirect
# entirely. Normalise it to a plain `>` BEFORE any split.
while IFS= read -r seg; do
  seg=$(printf '%s' "$seg" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$seg" ] || continue

  # The leading guard rejects `2>&1`, `1>&2` and a bare `&>`: a duplicated
  # descriptor is not a file.
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    add_target "$(printf '%s' "$hit" | sed 's/^.*>[|]*[[:space:]]*//')"
  done < <(printf '%s\n' "$seg" | grep -oE '(^|[^0-9<>&])&?>>?[|]?[[:space:]]*[^ 	;|&<>()]+' || true)

  # Strip a leading `sudo`/env-assignment so the program name is first.
  seg=$(printf '%s' "$seg" | sed 's/^sudo[[:space:]]\{1,\}//; s/^[A-Za-z_][A-Za-z0-9_]*=[^ ]*[[:space:]]\{1,\}//')
  # shellcheck disable=SC2086
  set -- $seg
  prog="${1:-}"; [ -n "$prog" ] || continue
  prog="${prog##*/}"
  shift || true

  case "$prog" in
    cd|pushd)
      # An absolute cd replaces; a relative one composes. `cd -` and bare `cd`
      # go somewhere unknowable, so the prefix is dropped rather than guessed --
      # that returns to repo-relative matching, and never invents a path.
      d="${1:-}"
      # `set -- $seg` does not remove quotes, so `cd "/tmp/x"` arrives with them
      # attached; left in, they ride into every later target and are dropped at
      # delegation, silently turning cd tracking off for the quoted form.
      d="${d%\"}"; d="${d#\"}"; d="${d%\'}"; d="${d#\'}"
      case "$d" in
        ""|-) SEGCWD="" ;;
        /*|[A-Za-z]:/*) SEGCWD="$d" ;;
        *) SEGCWD="${SEGCWD:+$SEGCWD/}$d" ;;
      esac
      continue
      ;;
    sed)
      printf '%s\n' "$seg" | grep -qE '(^|[[:space:]])-[a-zA-Z]*i' || continue
      # Operands are everything that is not a flag and not the script itself.
      # The script is the first non-flag arg UNLESS -e/-f supplied it.
      script_taken=0
      printf '%s\n' "$seg" | grep -qE '(^|[[:space:]])-[a-zA-Z]*[ef]' && script_taken=1
      for a in "$@"; do
        case "$a" in -*) continue ;; esac
        if [ "$script_taken" = "0" ]; then script_taken=1; continue; fi
        add_target "$a"
      done
      ;;
    tee|sponge)
      # `sponge` (moreutils) soaks stdin and writes the file in place -- the
      # whole point of `cat f | filter | sponge f` is that it is a write.
      for a in "$@"; do
        case "$a" in -*) continue ;; esac
        add_target "$a"
      done
      ;;
    awk|gawk|mawk|nawk)
      # awk writes with `print > "file"` entirely inside its program text, so no
      # operand of the command is the target. Only when a redirect is actually
      # present, so a plain `awk '{print $1}' f` is untouched.
      printf '%s\n' "$seg" | grep -q '>' || continue
      # An awk program normally sits inside a quoted shell word, so its own
      # string quotes often arrive escaped. Fold those before matching, or the
      # pattern cannot see the opening quote and the filename is never found.
      awkseg=$(printf '%s' "$seg" | sed 's/\\"/"/g')
      while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        add_target "$(printf '%s' "$hit" | sed 's/^>>\{0,1\}[[:space:]]*//; s/^"//; s/"$//')"
      done < <(printf '%s\n' "$awkseg" | grep -oE '>>?[[:space:]]*"[^"]+"' || true)
      ;;
    ed|ex|vi|vim|nano)
      # A line editor driven with -c 'wq' is a scripted in-place write, and an
      # interactive editor has no business running from a hook-gated shell at
      # all. Either way the operands are files it can save over.
      for a in "$@"; do
        case "$a" in -*) continue ;; esac
        add_target "$a"
      done
      ;;
    cp|mv|install|rsync|ln)
      # `-t DIR` / `--target-directory=DIR` names the destination explicitly, so
      # the last operand is a SOURCE, not the target -- `mv -t src/services x.ts`
      # walks past a last-operand-only parser.
      tdir=""; prev=""; last=""
      for a in "$@"; do
        case "$prev" in -t|--target-directory) tdir="$a"; prev="$a"; continue ;; esac
        case "$a" in --target-directory=*) tdir="${a#*=}"; prev="$a"; continue ;; esac
        prev="$a"
        case "$a" in -*) continue ;; esac
        last="$a"
      done
      if [ -n "$tdir" ]; then
        for a in "$@"; do
          case "$a" in -*) continue ;; esac
          [ "$a" = "$tdir" ] && continue
          add_target "$tdir/${a##*/}"
        done
      else
        add_target "$last"
      fi
      ;;
    perl|ruby)
      # -i is in-place editing: the same shape as `sed -i`, and just as much a
      # write.
      printf '%s\n' "$seg" | grep -qE '(^|[[:space:]])-[a-zA-Z]*i' || continue
      skip_next=0
      for a in "$@"; do
        if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
        case "$a" in -*e*) skip_next=1; continue ;; esac
        case "$a" in -*) continue ;; esac
        add_target "$a"
      done
      ;;
    rm|truncate|shred)
      for a in "$@"; do
        case "$a" in -*) continue ;; esac
        add_target "$a"
      done
      ;;
    dd)
      for a in "$@"; do
        case "$a" in of=*) add_target "${a#of=}" ;; esac
      done
      ;;
    git)
      # `mv`, `rm` and `clean` matter as much as `checkout`: stopping a guarded
      # file from being reverted while allowing it to be moved or deleted is not
      # a guard.
      case "${1:-}" in
        checkout|restore|apply|am|revert|mv|rm|clean)
          for a in "$@"; do
            case "$a" in -*|checkout|restore|apply|am|revert|mv|rm|clean) continue ;; esac
            add_target "$a"
          done
          ;;
      esac
      ;;
    patch)
      for a in "$@"; do
        case "$a" in -*) continue ;; esac
        add_target "$a"
      done
      ;;
    npm|pnpm|yarn|composer|cargo|go|pip|pip3|bundle)
      # A package manager rewrites the manifest without ever naming it, so every
      # extractor above sees nothing -- the same one-door problem this hook was
      # written to fix, one layer further out. `npm i react-select` edits the
      # manifest as surely as `sed -i` does.
      #
      # Only the ADD forms, and only with an operand: a bare `npm install`,
      # `npm ci`, `composer install` or `go mod download` restores from the
      # lockfile and changes no manifest, so gating them would block a cold
      # checkout for no gain. `audit fix` is deliberately exempt -- blocking the
      # remediation path for a known CVE is worse than the note it would collect.
      sub="${1:-}"
      MANIFEST_FOR=""
      case "$prog:$sub" in
        npm:install|npm:i|npm:add|pnpm:install|pnpm:i|pnpm:add|yarn:add) MANIFEST_FOR="package.json" ;;
        composer:require) MANIFEST_FOR="composer.json" ;;
        cargo:add)        MANIFEST_FOR="Cargo.toml" ;;
        go:get)           MANIFEST_FOR="go.mod" ;;
        pip:install|pip3:install) MANIFEST_FOR="requirements.txt" ;;
        bundle:add)       MANIFEST_FOR="Gemfile" ;;
      esac
      if [ -n "$MANIFEST_FOR" ]; then
        shift || true
        for a in "$@"; do
          case "$a" in -*) continue ;; esac
          # A real package operand (not a flag) is what makes this an add.
          add_target "$MANIFEST_FOR"
          break
        done
      fi
      ;;
  esac
done < <(printf '%s\n' "$CMD" | sed 's/>|/> /g; s/&&/\n/g; s/||/\n/g; s/[;|]/\n/g')

# --- writes performed INSIDE an interpreter ---------------------------------
# `python - <<PY ... open(p,'w') ... PY` is not a redirect, not sed and not tee,
# so every extractor above sees nothing. It is also the shape an agent reaches
# for most often, so omitting it would leave the guard decorative against the
# most common way a file actually changes.
#
# Deliberately narrow: an interpreter, a write verb, AND a guarded path in the
# same command. A script that only READS a guarded path has no write verb and
# passes. The residual false positive -- reading a guarded file and writing the
# result somewhere harmless -- blocks rather than allows, which is the right
# direction for a guard, and the message names the target that triggered it.
#
# The mode alternation requires a COMMA before the quoted mode. Without it,
# open\([^)]*'[wax] matches open('app/... -- the PATH starts with 'a -- so every
# READ of a file under a root beginning with a, w or x would block. Quotes are
# folded to ' before matching so the pattern never has to contain a double
# quote; embedding one is what breaks this block first.
case "$CMD" in
  *python*|*node*|*perl*|*php*|*ruby*|*deno*|*bun*)
    # The verb list must include LIBRARY writes: shutil.copy, os.replace,
    # fs.renameSync move a file into a guarded root without ever opening it.
    if printf '%s' "$CMD" | tr '\042' '\047' \
        | grep -qE "\.write|writeFile|file_put_contents|shutil\.|os\.(replace|rename|remove|unlink)|copyFileSync|renameSync|appendFileSync|\.rename\(|\.unlink\(|rmtree|open\([^)]*,[^)]*'[wax][+bt]*'"; then
      while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        add_target "$(printf '%s' "$hit" | sed 's/^[^A-Za-z0-9_]//')"
      done < <(printf '%s' "$CMD" | grep -oE "(^|[^A-Za-z0-9_./-])(${ROOT_ALT}/[A-Za-z0-9_./-]+|(package|composer)\.json|Cargo\.toml|go\.mod|pyproject\.toml)" || true)
    fi
    ;;
esac

# --- residual: an unresolvable write aimed at a guarded root ----------------
# Two forms defeat every extractor above by construction, because the target
# only exists after expansion:
#
#   echo src/x.ts | xargs -I{} cp /tmp/x.ts {}    # target is `{}`
#   T=src/x.ts; echo x > $T                       # target is `$T`
#
# add_target deliberately drops `{}`-style placeholders and anything containing
# `$`, so both produce NO target and exit 0. Resolving them means expanding the
# command, which a guard must not do. Naming them is enough: when the line both
# mentions a guarded root AND writes through one of these indirections, refuse
# and say which.
#
# `xargs` alone is not a write -- `grep -rl foo src | xargs wc -l` is an everyday
# read, and blocking it would cost a retry on unrelated work. So require a write
# PROGRAM to be carried by the xargs too. A `> $VAR` redirect needs no such
# qualifier: it is a write by construction.
if [ -z "${TARGETS// /}" ]; then
  if printf '%s' "$CMD" | grep -qE "(^|[^A-Za-z0-9_./-])${ROOT_ALT}/" \
     && { printf '%s' "$CMD" | grep -qE '>[|]?[[:space:]]*[$]' \
          || { printf '%s' "$CMD" | grep -qE '(^|[[:space:]])(xargs|parallel)([[:space:]]|$)' \
               && printf '%s' "$CMD" | grep -qE '(^|[[:space:]])(cp|mv|rm|dd|tee|sponge|install|ln|truncate|shred|sed)([[:space:]]|$)'; }; }; then
    echo 'BLOCKED: this command writes through an indirection that cannot be resolved,' >&2
    echo '  and it names a guarded source root. Refusing to guess at the target.' >&2
    echo '  Name the file directly, or make the change through the Edit/Write tool.' >&2
    studio_log_gate bash-gate BLOCK - "$CMD" unresolvable-indirection
    exit 2
  fi
fi

[ -n "${TARGETS// /}" ] || exit 0

# --- delegate to the one gate ----------------------------------------------
# gate-check.sh already decides which roots are guarded, what a new surface is,
# and what the block message says. Re-deciding any of that here is how the two
# doors drift apart.
SEEN=""
while IFS= read -r t; do
  [ -n "$t" ] || continue
  case "$SEEN" in *"|$t|"*) continue ;; esac
  SEEN="$SEEN|$t|"
  # A path containing a quote or a backslash is pathological and would have to
  # be JSON-escaped to travel. Escaping it through sed is what breaks first --
  # backslashes about backslashes, one lost in transit, an empty target, and a
  # gate that silently ALLOWS. Skipping it is the honest move.
  case "$t" in *'"'*) continue ;; esac
  case "$t" in *'\'*) continue ;; esac
  if ! out=$(printf '{"tool_input":{"file_path":"%s"}}' "$t" \
              | bash "$HOOKDIR/gate-check.sh" 2>&1 >/dev/null); then
    echo "BLOCKED: this shell command writes to a gated source file." >&2
    echo "  target: $t" >&2
    printf '%s\n' "$out" | sed '1d' >&2
    exit 2
  fi
done <<EOF
$TARGETS
EOF

exit 0
