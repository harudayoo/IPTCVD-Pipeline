#!/usr/bin/env bash
#
# claude-studio installer
#
# Installs a plan-sized Claude Code pipeline into a project. Three tiers, all
# built on the same enforcement layer:
#
#   pro     7 agents,  sequential,        one Opus call per feature
#   max    11 agents,  conductor-routed,  3-way parallel verify
#   max20x 24 agents,  full roster,       5-way parallel verify + telemetry
#
# Design rules this script follows:
#   1. Never destroy. Existing files are backed up before being touched.
#   2. Never guess silently. Detected values are written as {{PLACEHOLDERS}}
#      with a NEEDS_REVIEW marker until you confirm them.
#   3. Unconfigured hooks are LOUD, not inert. A hook with unresolved
#      placeholders warns on stderr rather than passing quietly.
#   4. Idempotent. Re-running updates templates without clobbering your edits.
#   5. No per-tier logic lives in this script. Everything that differs between
#      plans is declared in templates/tiers/<tier>/manifest.conf.
#
set -euo pipefail

VERSION="2.0.0"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$(pwd)"
PLAN=""
DRY_RUN=0
FORCE=0
NO_DOCS=0
UNINSTALL=0
STAMP="$(date +%Y%m%d-%H%M%S)"

VALID_PLANS="pro max max20x"

c_red()  { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_yel()  { printf '\033[33m%s\033[0m\n' "$*"; }
c_dim()  { printf '\033[2m%s\033[0m\n' "$*"; }
c_bold() { printf '\033[1m%s\033[0m\n' "$*"; }
die()    { c_red "error: $*" >&2; exit 1; }

usage() {
  cat <<'HELPTEXT'
claude-studio installer

USAGE
  ./install.sh [--plan pro|max|max20x] [OPTIONS]
  ./install.sh --plan max20x --target /path/to/project

PLANS
  pro       Claude Pro. 7 agents, sequential, one Opus call per feature.
  max       Claude Max (5x). 11 agents, a conductor enforcing phase order,
            verification fanned out to three parallel read-only reviewers.
  max20x    Claude Max 20x. The full 24-agent roster, five-lens parallel
            verification, three-level debate, and a measured monthly report.

  Omit --plan and the installer asks. It never picks one for you.

OPTIONS
  --plan TIER      Which pipeline to install (see above)
  --target DIR     Project to install into (default: current directory)
  --dry-run        Show what would happen, change nothing
  --force          Overwrite existing studio files (backup still taken)
  --no-docs        Skip the docs/ scaffolding
  --uninstall      Remove studio files (backup taken first)
  --version        Print version
  -h, --help       This message

AFTER INSTALL
  1. Edit docs/setup/PROFILE.md and run every command in it.
  2. Run: ./configure.sh --target DIR   (fills placeholders from the profile)
  3. Run: ./verify.sh --target DIR      (proves the hooks actually fire)
  4. Open Claude Code and run /doctor, then /context.
HELPTEXT
}

while [ $# -gt 0 ]; do
  case "$1" in
    --plan|--tier) PLAN="${2:-}"; shift 2 ;;
    --plan=*)      PLAN="${1#*=}"; shift ;;
    --tier=*)      PLAN="${1#*=}"; shift ;;
    --target)      TARGET="$(cd "$2" 2>/dev/null && pwd)" || die "no such directory: $2"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --force)       FORCE=1; shift ;;
    --no-docs)     NO_DOCS=1; shift ;;
    --uninstall)   UNINSTALL=1; shift ;;
    --version)     echo "$VERSION"; exit 0 ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "unknown option: $1 (try --help)" ;;
  esac
done

[ -d "$SRC/templates" ]       || die "templates/ not found next to install.sh"
[ -d "$SRC/templates/tiers" ] || die "templates/tiers/ not found — this looks like a pre-2.0 checkout"
[ -d "$TARGET" ]              || die "target does not exist: $TARGET"

BACKUP="$TARGET/.claude/.backup-$STAMP"
STUDIO_STATE="$TARGET/.claude/state/studio.json"

run() { if [ "$DRY_RUN" = 1 ]; then c_dim "  would: $*"; else eval "$@"; fi; }

backup_if_exists() {
  local p="$1"
  [ -e "$p" ] || return 0
  local rel="${p#$TARGET/}"
  run "mkdir -p '$BACKUP/$(dirname "$rel")'"
  run "cp -a '$p' '$BACKUP/$rel'"
  c_dim "  backed up $rel"
}

# ------------------------------------------------------------- tier plumbing
plan_is_valid() {
  local p="$1" v
  for v in $VALID_PLANS; do [ "$p" = "$v" ] && return 0; done
  return 1
}

# Read one field from another tier's manifest without polluting this shell.
manifest_field() {  # manifest_field <tier> <VAR_NAME>
  ( . "$SRC/templates/tiers/$1/manifest.conf"; printf '%s' "${!2:-}" )
}

installed_plan() {
  [ -f "$STUDIO_STATE" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r '.tier // empty' "$STUDIO_STATE" 2>/dev/null
  else
    tr -d '\n' < "$STUDIO_STATE" \
      | grep -o '"tier"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//'
  fi
}

# Tier overrides win over the shared pool. This is how /feature can mean a
# different playbook per tier while keeping the same command name.
resolve() {  # resolve <kind> <name> -> prints the source path, or fails
  local kind="$1" name="$2" suffix="" p
  [ "$kind" = "skills" ] || suffix=".md"
  for p in "$SRC/templates/tiers/$PLAN/$kind/$name$suffix" \
           "$SRC/templates/$kind/$name$suffix"; do
    [ -e "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

# Read one line from stdin into REPLY_LINE. Returns non-zero when stdin is
# closed or at EOF, which is how a non-interactive run gets a clear error
# instead of a hang. Works for both a terminal and a piped answer.
ask() {  # ask <prompt>
  printf '%s' "$1"
  read -r REPLY_LINE || return 1
  return 0
}

choose_plan() {
  echo
  c_bold "Which Claude Code plan is this pipeline for?"
  c_dim  "The roster, the verification fan-out and the token budget all follow from this."
  echo
  local i=1 p
  for p in $VALID_PLANS; do
    printf '  \033[1m%d) %-7s\033[0m \033[2m%s\033[0m\n' "$i" \
      "$(manifest_field "$p" TIER_NAME)" "$(manifest_field "$p" TIER_TAGLINE)"
    printf '     %s\n\n' "$(manifest_field "$p" TIER_BLURB)"
    i=$((i + 1))
  done
  c_dim "You can change tier later by re-running with a different --plan."
  echo
  local tries=0
  while :; do
    if ! ask "Choose [1-3]: "; then
      echo
      die "no plan selected (stdin closed). Pass --plan pro|max|max20x."
    fi
    case "$REPLY_LINE" in
      1|pro|Pro|PRO)            PLAN="pro";    break ;;
      2|max|Max|MAX)            PLAN="max";    break ;;
      3|max20x|max20|"max 20x") PLAN="max20x"; break ;;
      *) c_yel "Enter 1, 2 or 3." ;;
    esac
    tries=$((tries + 1))
    [ "$tries" -ge 5 ] && die "no valid plan selected. Pass --plan pro|max|max20x."
  done
  echo
}

# ---------------------------------------------------------------- uninstall
if [ "$UNINSTALL" = 1 ]; then
  c_yel "Uninstalling claude-studio from $TARGET"
  PREV="$(installed_plan || true)"

  # Remove only what this tier installed. Blanket-removing .claude/skills and
  # .claude/agents would take third-party skills and agents with it — a design
  # plugin, a house agent — which is not what "uninstall claude-studio" means.
  if [ -n "$PREV" ] && plan_is_valid "$PREV" && [ -f "$SRC/templates/tiers/$PREV/manifest.conf" ]; then
    c_dim "  installed tier: $PREV — removing only what it owned"
    # shellcheck source=/dev/null
    . "$SRC/templates/tiers/$PREV/manifest.conf"
    for a in $TIER_AGENTS; do
      backup_if_exists "$TARGET/.claude/agents/$a.md"; run "rm -f '$TARGET/.claude/agents/$a.md'"
    done
    for s in $TIER_SKILLS; do
      backup_if_exists "$TARGET/.claude/skills/$s"; run "rm -rf '$TARGET/.claude/skills/$s'"
    done
    for r in $TIER_RULES; do
      backup_if_exists "$TARGET/.claude/rules/$r.md"; run "rm -f '$TARGET/.claude/rules/$r.md'"
    done
    for p in .claude/hooks .claude/scripts .claude/state .claude/workflows; do
      backup_if_exists "$TARGET/$p"; run "rm -rf '$TARGET/$p'"
    done
    # Drop the now-empty studio directories, but never a directory someone
    # else still has files in.
    for d in .claude/agents .claude/skills .claude/rules; do
      [ "$DRY_RUN" = 1 ] || rmdir "$TARGET/$d" 2>/dev/null || true
    done
    if [ -d "$TARGET/.claude/skills" ] || [ -d "$TARGET/.claude/agents" ]; then
      c_yel "  Left in place (not installed by claude-studio):"
      for d in agents skills rules; do
        [ -d "$TARGET/.claude/$d" ] || continue
        for f in "$TARGET/.claude/$d/"*; do
          [ -e "$f" ] && c_dim "    .claude/$d/$(basename "$f")"
        done
      done
    fi
  else
    c_yel "  No tier recorded in .claude/state/studio.json."
    c_dim "  Falling back to removing the whole studio directory set. Anything"
    c_dim "  third-party under .claude/agents or .claude/skills goes too — it is"
    c_dim "  all in the backup."
    for p in .claude/agents .claude/skills .claude/rules .claude/hooks \
             .claude/scripts .claude/state .claude/workflows; do
      backup_if_exists "$TARGET/$p"
      run "rm -rf '$TARGET/$p'"
    done
  fi

  c_grn "Removed. Backup at ${BACKUP#$TARGET/}"
  c_dim "docs/, CLAUDE.md and settings.json were left alone — remove by hand if you want them gone."
  c_dim "settings.json still references .claude/hooks/*.sh; drop those entries too."
  exit 0
fi

# ------------------------------------------------------------- plan selection
if [ -z "$PLAN" ]; then
  EXISTING="$(installed_plan || true)"
  if [ -n "$EXISTING" ] && plan_is_valid "$EXISTING"; then
    PLAN="$EXISTING"
    c_dim "Reusing the installed tier: $PLAN  (pass --plan to change it)"
  else
    choose_plan
  fi
fi
plan_is_valid "$PLAN" || die "unknown plan: '$PLAN' (expected one of: $VALID_PLANS)"
[ -f "$SRC/templates/tiers/$PLAN/manifest.conf" ] || die "no manifest for tier '$PLAN'"

# shellcheck source=/dev/null
. "$SRC/templates/tiers/$PLAN/manifest.conf"

# Fail before writing anything if the manifest names something that is missing.
for a in $TIER_AGENTS; do resolve agents "$a" >/dev/null || die "manifest lists agent '$a' but no template exists"; done
for s in $TIER_SKILLS; do resolve skills "$s" >/dev/null || die "manifest lists skill '$s' but no template exists"; done
for r in $TIER_RULES;  do resolve rules  "$r" >/dev/null || die "manifest lists rule '$r' but no template exists"; done

# --------------------------------------------------------------- detection
detect_stack() {
  STACK="unknown"; PKG=""; HAS_UI="unknown"
  DEV_CMD="NEEDS_REVIEW"; TEST_CMD="NEEDS_REVIEW"; SINGLE_TEST_CMD="NEEDS_REVIEW"
  FORMAT_CMD="NEEDS_REVIEW"; TYPECHECK_CMD="NEEDS_REVIEW"; BUILD_CMD="NEEDS_REVIEW"
  SOURCE_ROOTS="NEEDS_REVIEW"; FRONTEND_ROOT="NEEDS_REVIEW"; TEST_ROOT="NEEDS_REVIEW"
  TOKEN_FILE="NEEDS_REVIEW"; AUDIT_CMD="NEEDS_REVIEW"
  SHARED_SURFACES=""

  if [ -f "$TARGET/composer.json" ]; then
    STACK="PHP"; PKG="composer"
    grep -q '"laravel/framework"' "$TARGET/composer.json" 2>/dev/null && STACK="Laravel"
    TEST_CMD="php artisan test"; SINGLE_TEST_CMD="php artisan test --filter"
    DEV_CMD="php artisan serve"
    [ -f "$TARGET/vendor/bin/pint" ] && FORMAT_CMD="./vendor/bin/pint"
    [ -f "$TARGET/vendor/bin/phpstan" ] && TYPECHECK_CMD="./vendor/bin/phpstan analyse"
    SOURCE_ROOTS="app"; TEST_ROOT="tests"
    AUDIT_CMD="composer audit"
  fi

  if [ -f "$TARGET/package.json" ]; then
    [ "$STACK" = "unknown" ] && STACK="JavaScript/TypeScript" || STACK="$STACK + Node"
    if   [ -f "$TARGET/pnpm-lock.yaml" ]; then PKG="pnpm"
    elif [ -f "$TARGET/yarn.lock" ];      then PKG="yarn"
    elif [ -f "$TARGET/bun.lockb" ];      then PKG="bun"
    else PKG="npm"; fi
    # Read a script from package.json. Uses jq when present, falls back to sed.
    pkg_script() {
      if command -v jq >/dev/null 2>&1; then
        jq -r ".scripts.\"$1\" // empty" "$TARGET/package.json" 2>/dev/null
      else
        tr -d '\n' < "$TARGET/package.json" \
          | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
          | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//'
      fi
    }
    for s in dev test build lint typecheck; do
      v=$(pkg_script "$s" || true)
      [ -n "$v" ] || continue
      case "$s" in
        dev)       DEV_CMD="$PKG run dev" ;;
        build)     BUILD_CMD="$PKG run build" ;;
        lint)      [ "$FORMAT_CMD" = "NEEDS_REVIEW" ] && FORMAT_CMD="$PKG run lint" ;;
        typecheck) TYPECHECK_CMD="$PKG run typecheck" ;;
        test)
          # A watching test script would hang the filter hook.
          case "$v" in
            *watch*|vitest)
              TEST_CMD="NEEDS_REVIEW  # '$PKG run test' looks like a WATCHER" ;;
            *) TEST_CMD="$PKG run test" ;;
          esac ;;
      esac
    done
    [ -f "$TARGET/tsconfig.json" ] && [ "$TYPECHECK_CMD" = "NEEDS_REVIEW" ] \
      && TYPECHECK_CMD="npx tsc --noEmit"
    for d in src app resources/js frontend; do
      [ -d "$TARGET/$d" ] && { FRONTEND_ROOT="$d"; break; }
    done
    [ "$SOURCE_ROOTS" = "NEEDS_REVIEW" ] && [ "$FRONTEND_ROOT" != "NEEDS_REVIEW" ] \
      && SOURCE_ROOTS="$FRONTEND_ROOT"
    for d in tests test __tests__ spec; do
      [ -d "$TARGET/$d" ] && { TEST_ROOT="$d"; break; }
    done
    HAS_UI="probably yes"
    node_audit_cmd="$PKG audit"; [ "$PKG" = "yarn" ] && node_audit_cmd="yarn audit"
    if [ "$AUDIT_CMD" = "NEEDS_REVIEW" ]; then
      AUDIT_CMD="$node_audit_cmd"
    else
      AUDIT_CMD="$AUDIT_CMD && $node_audit_cmd"
    fi
  fi

  if [ -f "$TARGET/pyproject.toml" ] || [ -f "$TARGET/requirements.txt" ]; then
    [ "$STACK" = "unknown" ] && STACK="Python"
    PKG="${PKG:-pip}"; TEST_CMD="pytest"; SINGLE_TEST_CMD="pytest -k"
    [ -d "$TARGET/src" ] && SOURCE_ROOTS="src"
    TEST_ROOT="tests"
    [ "$AUDIT_CMD" = "NEEDS_REVIEW" ] && AUDIT_CMD="pip-audit"
  fi

  # Directories where a fifth near-duplicate of an existing thing tends to
  # appear. Guessed from what is actually on disk; the profile marks it for
  # confirmation like every other detected value.
  for d in components Components pages Pages services Services hooks lib; do
    for r in $(printf '%s' "$SOURCE_ROOTS" | tr ',' ' ') "$FRONTEND_ROOT"; do
      case "$r" in ""|NEEDS_REVIEW) continue ;; esac
      [ -d "$TARGET/$r/$d" ] || continue
      case ",$SHARED_SURFACES," in *",$r/$d,"*) continue ;; esac
      SHARED_SURFACES="${SHARED_SURFACES:+$SHARED_SURFACES,}$r/$d"
    done
  done

  [ -f "$TARGET/go.mod" ]    && { STACK="Go";   TEST_CMD="go test ./..."; BUILD_CMD="go build ./..."
                                   [ "$AUDIT_CMD" = "NEEDS_REVIEW" ] && AUDIT_CMD="govulncheck ./..."; }
  [ -f "$TARGET/Cargo.toml" ] && { STACK="Rust"; TEST_CMD="cargo test";   BUILD_CMD="cargo build"
                                   [ "$AUDIT_CMD" = "NEEDS_REVIEW" ] && AUDIT_CMD="cargo audit"; }

  TOKEN_FILE="NEEDS_REVIEW"
  for f in src/styles/tokens.css src/tokens.css resources/css/tokens.css \
           app/globals.css src/app/globals.css styles/tokens.css; do
    [ -f "$TARGET/$f" ] && { TOKEN_FILE="$f"; break; }
  done

  PROJECT_NAME="$(basename "$TARGET")"
  if [ -f "$TARGET/package.json" ]; then
    if command -v jq >/dev/null 2>&1; then
      n=$(jq -r '.name // empty' "$TARGET/package.json" 2>/dev/null || true)
    else
      n=$(tr -d '\n' < "$TARGET/package.json" \
          | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' \
          | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')
    fi
    if [ -n "${n:-}" ]; then PROJECT_NAME="$n"; fi
  fi
}

# ------------------------------------------------------------------- start
echo
c_grn "claude-studio v$VERSION  ·  $TIER_NAME plan"
c_dim "$TIER_TAGLINE"
c_dim "source: $SRC"
c_dim "target: $TARGET"
[ "$DRY_RUN" = 1 ] && c_yel "DRY RUN — nothing will be written"
echo

command -v jq  >/dev/null 2>&1 || c_yel "warning: jq not found. Hooks use it when present and fall back to a shell parser; install jq for correct JSON parsing."
command -v git >/dev/null 2>&1 || c_yel "warning: git not found. The doc-check hook will no-op."
[ -d "$TARGET/.git" ] || c_yel "warning: target is not a git repository. Studio expects version control."
if [ "$PLAN" = "max20x" ]; then
  command -v python3 >/dev/null 2>&1 || c_yel "warning: python3 not found. /studio-report will not run without it."
fi

detect_stack
c_grn "Detected: $STACK  (package manager: ${PKG:-n/a})"
echo

# ------------------------------------------------------------- tier switching
PREV_PLAN="$(installed_plan || true)"
if [ -n "$PREV_PLAN" ] && [ "$PREV_PLAN" != "$PLAN" ] && plan_is_valid "$PREV_PLAN"; then
  c_yel "Switching tier: $PREV_PLAN -> $PLAN"
  c_dim "  Agents, skills and rules the old tier owned and the new one does not"
  c_dim "  will be backed up and removed."
  if [ "$FORCE" = 0 ] && [ "$DRY_RUN" = 0 ]; then
    ask "Continue? [y/N] " \
      || die "tier change needs confirmation and stdin is closed. Re-run with --force, or --dry-run to preview."
    case "$REPLY_LINE" in y|Y) ;; *) die "aborted" ;; esac
  fi
  PREV_AGENTS="$(manifest_field "$PREV_PLAN" TIER_AGENTS)"
  PREV_SKILLS="$(manifest_field "$PREV_PLAN" TIER_SKILLS)"
  PREV_RULES="$(manifest_field "$PREV_PLAN" TIER_RULES)"
  for a in $PREV_AGENTS; do
    case " $TIER_AGENTS " in *" $a "*) continue ;; esac
    backup_if_exists "$TARGET/.claude/agents/$a.md"; run "rm -f '$TARGET/.claude/agents/$a.md'"
  done
  for s in $PREV_SKILLS; do
    case " $TIER_SKILLS " in *" $s "*) continue ;; esac
    backup_if_exists "$TARGET/.claude/skills/$s"; run "rm -rf '$TARGET/.claude/skills/$s'"
  done
  for r in $PREV_RULES; do
    case " $TIER_RULES " in *" $r "*) continue ;; esac
    backup_if_exists "$TARGET/.claude/rules/$r.md"; run "rm -f '$TARGET/.claude/rules/$r.md'"
  done
  # A tier change rewrites the phase list in CLAUDE.md and the env block in
  # settings.json. Leaving the old ones in place is the worst of both.
  FORCE=1
  c_yel "  --force implied by the tier change: studio-owned files will be re-rendered."
  echo
elif [ -d "$TARGET/.claude/agents" ] && [ "$FORCE" = 0 ] && [ "$DRY_RUN" = 0 ]; then
  c_yel "An existing .claude/agents/ was found."
  c_dim "Re-running will back it up and replace studio-owned files."
  ask "Continue? [y/N] " \
    || die "stdin is closed and this would overwrite studio files. Re-run with --force, or --dry-run to preview."
  case "$REPLY_LINE" in y|Y) ;; *) die "aborted" ;; esac
  echo
fi

# --------------------------------------------------------------- directories
c_grn "1. Creating directories"
for d in .claude/agents .claude/skills .claude/rules .claude/hooks .claude/scripts \
         .claude/state .claude/agent-memory ${TIER_EXTRA_CLAUDE_DIRS:-}; do
  run "mkdir -p '$TARGET/$d'"
done
if [ "$NO_DOCS" = 0 ]; then
  for d in docs/setup docs/adr docs/specs docs/handoff docs/reports ${TIER_EXTRA_DOC_DIRS:-}; do
    run "mkdir -p '$TARGET/$d'"
  done
fi

# ------------------------------------------------------------------- copy
c_grn "2. Installing the $TIER_NAME roster"

n_agents=0
for a in $TIER_AGENTS; do
  s="$(resolve agents "$a")"
  d="$TARGET/.claude/agents/$a.md"
  backup_if_exists "$d"; run "cp '$s' '$d'"
  n_agents=$((n_agents + 1))
done
c_dim "  $n_agents agents"

n_skills=0
for s in $TIER_SKILLS; do
  p="$(resolve skills "$s")"
  d="$TARGET/.claude/skills/$s"
  backup_if_exists "$d"
  run "rm -rf '$d'"
  run "mkdir -p '$d'"
  run "cp -R '$p/.' '$d/'"
  n_skills=$((n_skills + 1))
done
c_dim "  $n_skills skills"

n_rules=0
for r in $TIER_RULES; do
  s="$(resolve rules "$r")"
  d="$TARGET/.claude/rules/$r.md"
  backup_if_exists "$d"; run "cp '$s' '$d'"
  n_rules=$((n_rules + 1))
done
c_dim "  $n_rules rules"

run "cp '$SRC/templates/common/hooks/'*.sh '$TARGET/.claude/hooks/'"
run "chmod +x '$TARGET/.claude/hooks/'*.sh"
n_hooks=$(find "$SRC/templates/common/hooks" -name '_*' -prune -o -name '*.sh' -print | wc -l | tr -d ' ')
c_dim "  $n_hooks hooks"

# The gate's own tooling. gate.sh records the plan the hooks read;
# hook-integrity.sh is what makes disarming them visible rather than silent.
run "cp '$SRC/templates/common/scripts/'*.sh '$TARGET/.claude/scripts/'"
run "chmod +x '$TARGET/.claude/scripts/'*.sh"
c_dim "  $(find "$SRC/templates/common/scripts" -name '*.sh' | wc -l | tr -d ' ') scripts"

if [ ! -f "$TARGET/.claude/state/gate.json" ] || [ "$FORCE" = 1 ]; then
  backup_if_exists "$TARGET/.claude/state/gate.json"
  run "cp '$SRC/templates/tiers/$PLAN/gate.json' '$TARGET/.claude/state/gate.json'"
fi

if [ "$NO_DOCS" = 0 ]; then
  [ -f "$TARGET/docs/adr/TEMPLATE.md" ] \
    || run "cp '$SRC/templates/common/docs/adr/TEMPLATE.md' '$TARGET/docs/adr/TEMPLATE.md'"
fi

# ------------------------------------------------------------------ render
# Escape a value for safe use as a sed *replacement* string: backslash first
# (so later steps don't double-escape what they introduce), then & (whole-
# match in sed replacement syntax), then | (our delimiter). Without this, a
# value containing either — e.g. a combined "composer audit && npm audit" —
# corrupts every other placeholder in the same sed invocation.
esc_repl() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/&/\\\&/g' -e 's/|/\\|/g'; }

render() {  # render <template> <destination>
  local tpl="$1" dst="$2"
  if [ "$DRY_RUN" = 1 ]; then c_dim "  would render $(basename "$tpl") -> ${dst#$TARGET/}"; return; fi
  sed \
    -e "s|{{PROJECT_NAME}}|$(esc_repl "$PROJECT_NAME")|g" \
    -e "s|{{STACK_LINE}}|$(esc_repl "$STACK")|g" \
    -e "s|{{PACKAGE_MANAGER}}|$(esc_repl "${PKG:-n/a}")|g" \
    -e "s|{{DEV_COMMAND}}|$(esc_repl "$DEV_CMD")|g" \
    -e "s|{{TEST_COMMAND}}|$(esc_repl "$TEST_CMD")|g" \
    -e "s|{{SINGLE_TEST_COMMAND}}|$(esc_repl "$SINGLE_TEST_CMD")|g" \
    -e "s|{{FORMAT_COMMAND}}|$(esc_repl "$FORMAT_CMD")|g" \
    -e "s|{{TYPECHECK_COMMAND}}|$(esc_repl "$TYPECHECK_CMD")|g" \
    -e "s|{{BUILD_COMMAND}}|$(esc_repl "$BUILD_CMD")|g" \
    -e "s|{{DEPENDENCY_AUDIT_COMMAND}}|$(esc_repl "$AUDIT_CMD")|g" \
    -e "s|{{SHARED_SURFACES}}|$(esc_repl "$SHARED_SURFACES")|g" \
    -e "s|{{SOURCE_ROOTS}}|$(esc_repl "$SOURCE_ROOTS")|g" \
    -e "s|{{FRONTEND_ROOT}}|$(esc_repl "$FRONTEND_ROOT")|g" \
    -e "s|{{TEST_ROOT}}|$(esc_repl "$TEST_ROOT")|g" \
    -e "s|{{TOKEN_FILE}}|$(esc_repl "$TOKEN_FILE")|g" \
    -e "s|{{HAS_UI}}|$(esc_repl "$HAS_UI")|g" \
    "$tpl" > "$dst"
}

c_grn "3. Rendering profile"
# PROFILE.md is user data — every value in it was confirmed by running a
# command. --force must NOT restore it to NEEDS_REVIEW: configure.sh would
# then refuse to run, every hook would stay on placeholders, and the upgrade
# path documented in the README would silently un-configure the pipeline.
if [ "$NO_DOCS" = 0 ]; then
  if [ ! -f "$TARGET/docs/setup/PROFILE.md" ]; then
    render "$SRC/templates/common/docs/setup/PROFILE.md.tmpl" "$TARGET/docs/setup/PROFILE.md"
  else
    c_dim "  docs/setup/PROFILE.md exists — left alone (it holds confirmed values)"
    if [ "$FORCE" = 1 ] && [ "$DRY_RUN" = 0 ]; then
      render "$SRC/templates/common/docs/setup/PROFILE.md.tmpl" "$TARGET/docs/setup/PROFILE.studio.md"
      # Surface fields this version expects that the existing profile lacks.
      new_fields=""
      while IFS= read -r label; do
        grep -qF "| $label |" "$TARGET/docs/setup/PROFILE.md" || new_fields="$new_fields\n    - $label"
      done < <(sed -n 's/^| \([^|]*[^ |]\) *|.*|.*|$/\1/p' "$TARGET/docs/setup/PROFILE.studio.md")
      if [ -n "$new_fields" ]; then
        c_yel "  This version's profile has fields yours does not:"
        printf "%b\n" "$new_fields"
        c_dim "    Add them to docs/setup/PROFILE.md, confirm each, then re-run configure.sh."
        c_dim "    A rendered copy is at docs/setup/PROFILE.studio.md."
      else
        rm -f "$TARGET/docs/setup/PROFILE.studio.md"
      fi
    fi
    c_dim "  To start the profile over, delete it and re-run."
  fi
fi

c_grn "4. CLAUDE.md"
CLAUDE_TMPL="$SRC/templates/tiers/$PLAN/CLAUDE.md.tmpl"
if [ -f "$TARGET/CLAUDE.md" ]; then
  c_yel "  CLAUDE.md already exists — NOT overwritten."
  c_dim "  A $TIER_NAME version was written to CLAUDE.studio.md. Merge by hand."
  render "$CLAUDE_TMPL" "$TARGET/CLAUDE.studio.md"
else
  render "$CLAUDE_TMPL" "$TARGET/CLAUDE.md"
fi

c_grn "5. settings.json"
S="$TARGET/.claude/settings.json"
S_TMPL="$SRC/templates/tiers/$PLAN/settings.json.tmpl"
if [ ! -f "$S" ]; then
  run "cp '$S_TMPL' '$S'"
elif command -v jq >/dev/null 2>&1; then
  backup_if_exists "$S"
  if [ "$DRY_RUN" = 0 ]; then
    # Never redirect jq's stderr to /dev/null here. A silent merge failure that
    # falls back to settings.studio.json looks like a design decision rather
    # than a bug, which is exactly how the previous one survived so long.
    if jq -s -f "$SRC/templates/common/merge-settings.jq" \
         "$S" "$S_TMPL" > "$S.new" 2>"$S.err"; then
      mv "$S.new" "$S"; rm -f "$S.err"
      c_dim "  merged (studio hooks win; foreign hooks and permissions are kept)"
    else
      c_yel "  merge failed:"
      sed 's/^/    /' "$S.err" >&2
      rm -f "$S.new" "$S.err"
      cp "$S_TMPL" "$TARGET/.claude/settings.studio.json"
      c_yel "  wrote .claude/settings.studio.json instead. Merge by hand."
    fi
  fi
else
  run "cp '$S_TMPL' '$TARGET/.claude/settings.studio.json'"
  c_yel "  jq missing — wrote .claude/settings.studio.json. Merge by hand."
fi

c_grn "6. Recording the installed tier"
if [ "$DRY_RUN" = 0 ]; then
  cat > "$STUDIO_STATE" <<JSON
{
  "tier": "$PLAN",
  "tier_name": "$TIER_NAME",
  "version": "$VERSION",
  "phases": "$TIER_PHASES",
  "installed_at": "$(date -Iseconds 2>/dev/null || date)"
}
JSON
  c_dim "  .claude/state/studio.json"
else
  c_dim "  would write .claude/state/studio.json (tier: $PLAN)"
fi

c_grn "7. .gitignore"
if [ "$DRY_RUN" = 0 ]; then
  for line in "CLAUDE.local.md" ".claude/settings.local.json" ".claude/.backup-*" ".claude/agent-memory-local/"; do
    grep -qxF "$line" "$TARGET/.gitignore" 2>/dev/null || echo "$line" >> "$TARGET/.gitignore"
  done
fi

# ------------------------------------------------------------------ report
echo
c_grn "Installed: $TIER_NAME  ($n_agents agents · $n_skills skills · $n_rules rules · $n_hooks hooks)"
[ -d "$BACKUP" ] && c_dim "Backup: ${BACKUP#$TARGET/}"
echo
c_bold "Phases"
c_dim "  $(printf '%s' "$TIER_PHASES" | tr -s ' ' '\n' | paste -sd'>' - | sed 's/>/ -> /g')"
echo
c_bold "Agents on Opus — this is where the cost is"
c_dim "  ${TIER_OPUS_AGENTS:-none}"
echo
c_yel "UNRESOLVED PLACEHOLDERS — the pipeline is inert until these are filled:"
if [ "$DRY_RUN" = 0 ]; then
  grep -rl '{{[A-Z_]*}}' "$TARGET/.claude" 2>/dev/null | sed "s|$TARGET/|  |" || echo "  none"
fi
echo
cat <<__NEXTSTEPS__
NEXT STEPS

  1. Open docs/setup/PROFILE.md. Fill every NEEDS_REVIEW field.
     Run each command yourself. A field is not confirmed until its
     command has executed. Watch for a watching test script -- that
     will hang the output filter.

  2. Fill the placeholders:
        ./configure.sh --target "$TARGET"

  3. Prove the hooks fire:
        ./verify.sh --target "$TARGET"

  4. In Claude Code:
        /doctor      # duplicate agents, oversized memory
        /context     # pre-prompt total should be under ~15%
        /hooks       # confirm every studio hook is registered

  5. Seed agent memory (read-only passes -- see README).

  6. Start your first change:
        $TIER_ENTRY_COMMAND

__NEXTSTEPS__
if [ "$PLAN" = "max20x" ]; then
  c_dim "Max 20x notes:"
  c_dim "  · Telemetry is wired but OFF. Set CLAUDE_CODE_ENABLE_TELEMETRY to \"1\" in"
  c_dim "    .claude/settings.json once an OTLP collector is listening on :4317."
  c_dim "  · Agent teams are wired but OFF. They cost roughly 7x a single session."
  c_dim "  · Take a baseline into docs/reports/baseline.md BEFORE your first feature."
  c_dim "    Without it, every saving you claim later is invented."
  echo
fi
