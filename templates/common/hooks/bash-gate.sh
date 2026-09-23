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
#   >  >>  >|  &>  redirects     sed -i / --in-place   tee / sponge
#   cp mv install rsync ln       rm truncate           dd of=
#   perl -i  ruby -i             awk print > f         ed/ex/vi -c wq
#   git checkout/restore/apply/am/revert/mv/rm/clean,  patch
#   npm|pnpm|yarn add/update/uninstall, npm pkg set/delete, composer
#     require/update/remove      (the manifest they rewrite)
#   curl -o / wget -O            a download landing on a guarded path
#   find -exec/-execdir/-ok      carrying a write program
#   chmod/chown/attrib/icacls    a permission change on a protected file is a
#                                step toward editing it without detection
#   interpreter writes naming a guarded path, including powershell/pwsh
#   env/command/exec/time/nohup/nice/timeout/stdbuf/sudo/VAR=val prefixes,
#     peeled so the REAL program underneath is what gets matched
#   a subshell or brace group wrapping any of the above
#   INTERPRETER -c "<script>", recursed back through this same parser
#   bulk rewrites blocked on PHASE ALONE, since they name no file to check:
#     git stash pop/apply, reset --hard/--merge/--keep, checkout <ref> --,
#     switch --discard-changes, merge/pull/rebase/cherry-pick/am;
#     tar -x, unzip, 7z x/e, Expand-Archive
#
# Not covered, and honest about it: a write performed by a script invoked by
# path, or by a wrapper this parser has not been taught. bash-audit.sh is the
# backstop for exactly that gap -- it does not parse the command at all, it
# diffs which guarded files are dirty before and after the call and refuses
# whatever is new, so a shape this file misses is still caught, just one step
# later and without the pre-emptive block.
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
# Bare roots for the text searches below: "^(src|app)(/|$)" -> "(src|app)".
# Parameter expansion, not sed: the suffix contains delimiter-hostile
# characters -- "(", "|", "$", ")" -- and quoting the pattern inside
# ${var%'pattern'} matches them literally without escaping any of them for a
# regex engine at all.
ROOT_ALT="${PROTECTED#^}"; ROOT_ALT="${ROOT_ALT%'(/|$)'}"
[ -n "$ROOT_ALT" ] || exit 0

CMD="$(json_field "$INPUT" 'tool_input.command')"

# Fail CLOSED when the payload could not be parsed but plainly names a guarded
# root. Every parser failing is not a reason to wave a write through; it is
# exactly when a guard should refuse and say so. Case-INSENSITIVE, matching
# gate-check.sh's own guarded-root match (`SRC/x.ts` is `src/x.ts` on Windows
# and macOS) -- this residual check is the one place in this file that never
# reaches gate-check.sh at all, so it has to carry that case-folding itself.
if [ -z "${CMD:-}" ]; then
  if printf '%s' "$INPUT" | grep -qiE "${ROOT_ALT}(/|\$)"; then
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
  # Windows-style backslash paths are a TARGET, not pathological -- convert
  # rather than drop. A path this dropped used to be delegated nowhere, which
  # is a silent ALLOW; converting it is the fail-closed direction, and
  # gate-check.sh's own normaliser does the identical conversion on the other
  # side, so a target that arrives with forward slashes here matches exactly
  # what it would have matched with backslashes.
  t="${t//\\//}"
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

# gate_phase_now -- the CURRENT gate phase, read fresh, for the bulk-rewrite
# checks below. Same dual-parser discipline as every other phase read in this
# repo: jq if it works, a grep fallback if not, "idle" if neither finds one.
gate_phase_now() {
  local gate=".claude/state/gate.json" phase=""
  [ -f "$gate" ] || { printf 'idle'; return; }
  if command -v jq >/dev/null 2>&1; then
    phase=$(jq -r '.phase // ""' "$gate" 2>/dev/null) || phase=""
  fi
  [ -n "$phase" ] || phase=$(grep -o '"phase"[[:space:]]*:[[:space:]]*"[^"]*"' "$gate" 2>/dev/null \
    | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')
  [ -n "$phase" ] && printf '%s' "$phase" || printf 'idle'
}

# block_bulk_rewrite <label> -- for commands that rewrite tracked files
# WITHOUT naming any of them on the command line: `git pull`, `tar -x`, a
# stash pop. add_target has nothing to delegate for these, so the check is on
# PHASE alone, exactly like gate-check.sh's own gate 1 -- a fast-forward pull
# mid-verify is exactly as undetectable, file by file, as a direct edit would
# be, and letting it through because "nothing named" would make VERIFY's
# read-only guarantee (slice 7) decorative against the one class of command
# built to evade a per-file check.
block_bulk_rewrite() {
  local phase; phase="$(gate_phase_now)"
  [ "$phase" = "create" ] && return 0
  echo "BLOCKED: '$1' rewrites tracked files without naming any of them on the" >&2
  echo "  command line, so this gate has nothing to check file by file. Phase is" >&2
  echo "  '$phase', not 'create'." >&2
  studio_log_gate bash-gate BLOCK "$phase" - "bulk-rewrite:$1"
  exit 2
}

# --- per-command targets ----------------------------------------------------
# Split the command line into segments so the first word of each is the program.
# `eval`-free and quote-naive on purpose: this is a guard, not a shell.
#
# Wrapped in a function so INTERPRETER -c "<script>" can feed the script text
# back through the identical loop rather than a second parser that would have
# to agree with the first forever. TARGETS/SEGCWD are process-global on
# purpose: a target found three levels into nested `bash -c` still has to
# register.
#
# process_segments <command-text> <depth>
process_segments() {
  local CMD="$1" DEPTH="$2"
  [ "$DEPTH" -le 3 ] || return 0

  # Redirect extraction lives INSIDE the segment loop so SEGCWD applies to it.
  # Run once over the whole command instead, and `cd src/services && echo x >
  # dues.ts` reads as a redirect to an unguarded `dues.ts`. Tracking `cd`
  # across a pipe segment is technically over-broad -- `cd x | y` does not
  # persist -- and that is the fail-closed direction.
  #
  # `>|` is a clobber redirect, not a pipe, but it CONTAINS a pipe character,
  # so splitting on [;|] would tear `echo x >| f` apart and lose the redirect
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

    # Strip a subshell/brace-group wrapper -- `(cmd)` or `{ cmd; }` -- before
    # anything else. The write happens inside regardless of the wrapping, and
    # leaving it on would make the program name "(sed" instead of "sed".
    seg="${seg#\(}"; seg="${seg#\{}"
    seg="${seg%\)}"; seg="${seg%\}}"; seg="${seg%;}"

    # INTERPRETER -c "<script>" is matched on the RAW segment text, before any
    # tokenising, because a quoted script argument is exactly what naive
    # word-splitting below would tear apart into separate words. Simple
    # prefixes ahead of the interpreter (sudo, env, an assignment) are peeled
    # first with the same string patterns used in the general peel below, so
    # `env bash -c "..."` is recognised too.
    peeled="$seg"
    while :; do
      case "$peeled" in
        sudo\ *) peeled="${peeled#sudo }" ;;
        env\ *|command\ *|exec\ *) peeled="${peeled#* }" ;;
        [A-Za-z_]*=*\ *)
          case "${peeled%% *}" in *=*) peeled="${peeled#* }" ;; *) break ;; esac ;;
        *) break ;;
      esac
    done
    case "$peeled" in
      bash\ -c\ \"*\"|sh\ -c\ \"*\"|zsh\ -c\ \"*\"|dash\ -c\ \"*\")
        inner="${peeled#*-c \"}"; inner="${inner%\"*}"
        [ -n "$inner" ] && process_segments "$inner" "$((DEPTH + 1))"
        continue ;;
      bash\ -c\ \'*\'|sh\ -c\ \'*\'|zsh\ -c\ \'*\'|dash\ -c\ \'*\')
        inner="${peeled#*-c \'}"; inner="${inner%\'*}"
        [ -n "$inner" ] && process_segments "$inner" "$((DEPTH + 1))"
        continue ;;
    esac

    # Peel wrapper prefixes repeatedly: env, command, exec, time, nohup, nice,
    # timeout and stdbuf all run the REST of the line as a child process and
    # are not themselves the write -- and they compose, e.g. `env timeout 5
    # sed -i ...`. A bare VAR=value prefix peels the same way. Tokenised via
    # `set --` rather than string patterns, because `nice -n 5 prog` and
    # `timeout --kill-after=10 30 prog` both need to consume a VARIABLE
    # number of following words, which a case pattern cannot express cleanly.
    # shellcheck disable=SC2086
    set -- $seg
    while [ $# -gt 0 ]; do
      case "$1" in
        sudo|env|command|exec|time|nohup) shift ;;
        nice)
          shift
          case "${1:-}" in -n) shift; shift || true ;; esac
          ;;
        timeout)
          shift
          while [ $# -gt 0 ]; do
            case "$1" in
              -*) shift ;;
              [0-9]*) shift; break ;;
              *) break ;;
            esac
          done
          ;;
        stdbuf)
          shift
          while [ $# -gt 0 ]; do
            case "$1" in -*) shift ;; *) break ;; esac
          done
          ;;
        [A-Za-z_]*=*) shift ;;
        *) break ;;
      esac
    done
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
        # --in-place and --in-place=SUFFIX are the long form of -i and just as
        # much a write.
        printf '%s\n' "$seg" | grep -qE '(^|[[:space:]])-[a-zA-Z]*i|--in-place(=|[[:space:]]|$)' || continue
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
      chmod|chown)
        # A permission or ownership change is a step toward tampering with a
        # protected file undetected -- chmod 644 a hook so its content can be
        # sed'd without -x ever flagging it missing, or chown it away from the
        # account CI runs integrity checks as. MODE/OWNER is the first non-flag
        # operand and is never a path; everything after it is.
        taken=0
        for a in "$@"; do
          case "$a" in -*) continue ;; esac
          if [ "$taken" = "0" ]; then taken=1; continue; fi
          add_target "$a"
        done
        ;;
      attrib|icacls)
        # Windows analogues of chmod/chown. attrib's +R/-R/+A/-A/+S/-S/+H/-H are
        # attribute flags, never paths; icacls's own flags and ACE strings
        # (/grant, /reset, Users:F) all start with a leading `/` when they are
        # flags, so a bare non-flag operand is the path being touched. Only the
        # FIRST such operand for icacls -- an ACE string like `Users:F` is not a
        # path and would otherwise be added as a spurious, harmless-but-noisy
        # target.
        taken=0
        for a in "$@"; do
          case "$a" in +[RASHIO]|-[RASHIO]|/*) continue ;; esac
          if [ "$prog" = "icacls" ]; then
            [ "$taken" = "0" ] && add_target "$a"
            taken=1
          else
            add_target "$a"
          fi
        done
        ;;
      curl)
        # -o/--output names the file the response body lands in.
        prev=""
        for a in "$@"; do
          case "$prev" in -o|--output) add_target "$a" ;; esac
          prev="$a"
        done
        ;;
      wget)
        prev=""
        for a in "$@"; do
          case "$prev" in -O|--output-document) add_target "$a" ;; esac
          prev="$a"
        done
        ;;
      dd)
        for a in "$@"; do
          case "$a" in of=*) add_target "${a#of=}" ;; esac
        done
        ;;
      find)
        # `find <paths> -exec <write-prog> ... {} +` (or -execdir/-ok) writes
        # to every path find would recurse into. Only when the exec'd program
        # is itself a write -- `find src -exec cat {} +` is a read -- and then
        # every path OPERAND before the first expression primary (-exec,
        # -name, -type, ...) is a target root, which is conservative but sound
        # since find recurses through all of them.
        printf '%s\n' "$seg" | grep -qE -- '-(exec|execdir|ok)[[:space:]]' || continue
        printf '%s\n' "$seg" \
          | grep -qE -- '-(exec|execdir|ok)[[:space:]]+[^ ]*/?(sed|perl|ruby|cp|mv|rm|tee|sponge|install|ln|truncate|shred|dd)([[:space:]]|$)' \
          || continue
        for a in "$@"; do
          case "$a" in -*) break ;; esac
          add_target "$a"
        done
        ;;
      tar)
        case "${1:-}" in *x*|--extract*) block_bulk_rewrite "tar -x" ;; esac
        ;;
      unzip)
        block_bulk_rewrite "unzip"
        ;;
      7z|7za|7zr)
        case "${1:-}" in x|e) block_bulk_rewrite "$prog $1" ;; esac
        ;;
      Expand-Archive)
        block_bulk_rewrite "Expand-Archive"
        ;;
      powershell|pwsh)
        # -Command/-c followed by a quoted script is the same shape as
        # `bash -c`, and PowerShell's own write verbs are matched by the
        # interpreter-write-target block below via $CMD, not here -- this
        # entry exists so `prog` being powershell/pwsh does not fall through
        # to "no case matched" and stop the segment from being inspected at
        # all further down.
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
        # Bulk rewrites: these change tracked files WITHOUT naming any of them
        # on the command line, so add_target has nothing to delegate -- gated
        # on phase alone via block_bulk_rewrite.
        case "${1:-}" in
          stash)
            case "${2:-}" in pop|apply) block_bulk_rewrite "git stash ${2}" ;; esac ;;
          reset)
            case "$seg" in *--hard*|*--merge*|*--keep*) block_bulk_rewrite "git reset" ;; esac ;;
          merge|pull|rebase|cherry-pick|am) block_bulk_rewrite "git ${1:-}" ;;
          checkout)
            # `git checkout <ref> -- <path>` restores <path> FROM ANOTHER REF --
            # qualitatively different from `git checkout -- <path>` (restore
            # from the INDEX, already covered above by naming <path> itself)
            # because <ref> can be any commit, and the specific path named is
            # not the only thing that changes when <ref> differs from HEAD.
            case "$seg" in *' -- '*) block_bulk_rewrite "git checkout <ref> --" ;; esac ;;
          switch)
            case "$seg" in *--discard-changes*) block_bulk_rewrite "git switch --discard-changes" ;; esac ;;
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
        # Only the ADD/REMOVE/UPDATE forms, and only with an operand: a bare
        # `npm install`, `npm ci`, `composer install` or `go mod download`
        # restores from the lockfile and changes no manifest, so gating them
        # would block a cold checkout for no gain. `audit fix` is deliberately
        # exempt -- blocking the remediation path for a known CVE is worse
        # than the note it would collect.
        sub="${1:-}"
        MANIFEST_FOR=""
        PKG_UNCONDITIONAL=0
        case "$prog:$sub" in
          npm:install|npm:i|npm:add|npm:uninstall|npm:un|npm:rm|npm:remove|npm:update|npm:up)
            MANIFEST_FOR="package.json" ;;
          pnpm:install|pnpm:i|pnpm:add|pnpm:up|pnpm:update) MANIFEST_FOR="package.json" ;;
          yarn:add|yarn:upgrade|yarn:up)                    MANIFEST_FOR="package.json" ;;
          composer:require|composer:update|composer:remove) MANIFEST_FOR="composer.json" ;;
          cargo:add)        MANIFEST_FOR="Cargo.toml" ;;
          go:get)           MANIFEST_FOR="go.mod" ;;
          pip:install|pip3:install|pip:uninstall|pip3:uninstall) MANIFEST_FOR="requirements.txt" ;;
          bundle:add)       MANIFEST_FOR="Gemfile" ;;
        esac
        # `npm pkg set|delete` rewrites package.json directly and
        # unconditionally -- there is no "only with an operand" caveat the way
        # install/update have one, since even `npm pkg delete engines.node`
        # needs no further argument to be a write.
        if [ "$prog" = "npm" ] && [ "$sub" = "pkg" ]; then
          case "${2:-}" in set|delete) MANIFEST_FOR="package.json"; PKG_UNCONDITIONAL=1 ;; esac
        fi
        if [ -n "$MANIFEST_FOR" ]; then
          if [ "$PKG_UNCONDITIONAL" = "1" ]; then
            add_target "$MANIFEST_FOR"
          else
            shift || true
            for a in "$@"; do
              case "$a" in -*) continue ;; esac
              # A real package operand (not a flag) is what makes this an add.
              add_target "$MANIFEST_FOR"
              break
            done
          fi
        fi
        ;;
    esac
  done < <(printf '%s\n' "$CMD" | sed 's/>|/> /g; s/&&/\n/g; s/||/\n/g; s/[;|]/\n/g')
}

process_segments "$CMD" 1

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
#
# powershell/pwsh join the interpreter list here (not "cmd": a bare substring
# match on three letters that common in unrelated text -- "command", a path
# segment, a variable name -- would false-positive far more than it would
# ever catch; cmd.exe write verbs are covered only when driven via
# powershell/pwsh, which is by far the more common agent-reachable shape).
case "$CMD" in
  *python*|*node*|*perl*|*php*|*ruby*|*deno*|*bun*|*powershell*|*pwsh*)
    # The verb list must include LIBRARY writes: shutil.copy, os.replace,
    # fs.renameSync move a file into a guarded root without ever opening it.
    # PowerShell's own cmdlets (Set-Content, Copy-Item, ...) are the same
    # shape one layer further out: a write verb naming a guarded path.
    if printf '%s' "$CMD" | tr '\042' '\047' \
        | grep -qE "\.write|writeFile|file_put_contents|shutil\.|os\.(replace|rename|remove|unlink)|copyFileSync|renameSync|appendFileSync|\.rename\(|\.unlink\(|rmtree|open\([^)]*,[^)]*'[wax][+bt]*'|Set-Content|Add-Content|Out-File|Copy-Item|Move-Item|Remove-Item|New-Item"; then
      while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        add_target "$(printf '%s' "$hit" | sed 's/^[^A-Za-z0-9_]//')"
      done < <(printf '%s' "$CMD" | grep -oiE "(^|[^A-Za-z0-9_./-])(${ROOT_ALT}/[A-Za-z0-9_./-]+|(package|composer)\.json|Cargo\.toml|go\.mod|pyproject\.toml)" || true)
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
  if printf '%s' "$CMD" | grep -qiE "(^|[^A-Za-z0-9_./-])${ROOT_ALT}(/|\$)" \
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
# doors drift apart. It also decides WHICH gate.json governs $t -- by walking
# up from $t's own path for the nearest .claude/state/gate.json (studio_find_
# root in _guard.sh), not by this hook's `cd` above. So a target that lands
# inside a worktree is judged by that worktree's gate even though bash-gate
# itself never left the main checkout: the root comes from the TARGET, never
# from where this hook happens to be running.
SEEN=""
while IFS= read -r t; do
  [ -n "$t" ] || continue
  case "$SEEN" in *"|$t|"*) continue ;; esac
  SEEN="$SEEN|$t|"
  # A path containing a quote is pathological and would have to be
  # JSON-escaped to travel. Escaping it through sed is what breaks first --
  # a lost character, an empty target, and a gate that silently ALLOWS.
  # Skipping it is the honest move. Backslashes no longer need the same
  # treatment: add_target converts them to forward slashes before a target
  # ever reaches TARGETS.
  case "$t" in *'"'*) continue ;; esac
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
