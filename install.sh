#!/usr/bin/env bash
# install.sh — agentdoc skill installer
#
# Usage:
#   ./install.sh --mode global
#   ./install.sh --mode local --root /absolute/path/to/repo [--ci-install]
#   ./install.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_FILE="$SCRIPT_DIR/skill.md"
CI_SCRIPT_SRC="$SCRIPT_DIR/agentdoc-check.sh"
README="$SCRIPT_DIR/README.md"
CI_EXAMPLES_DIR="$SCRIPT_DIR/ci-examples"

# ---------------------------------------------------------------------------
# Terminal colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()   { echo -e "${CYAN}[agentdoc]${RESET} $*"; }
ok()    { echo -e "${GREEN}[agentdoc] ✓${RESET} $*"; }
warn()  { echo -e "${YELLOW}[agentdoc] ⚠${RESET} $*"; }
info()  { echo -e "  $*"; }

die() {
    echo -e "\n${RED}Error:${RESET} $*\n" >&2
    usage >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Usage / help
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
${BOLD}agentdoc installer${RESET}

Installs the agentdoc Claude Code skill and optionally the CI utility script.

${BOLD}USAGE${RESET}
  $(basename "$0") --mode global
  $(basename "$0") --mode local --root <path> [--ci-install]
  $(basename "$0") --help

${BOLD}MODES${RESET}
  global        Install skill globally (~/.claude/skills/).
                Available in all repos without further setup.

  local         Install skill into a specific repo.
                Requires --root.

${BOLD}OPTIONS${RESET}
  --root <path>   Absolute path to the target repo root.
                  Required when --mode local.
                  Must exist and must be a git repository.

  --ci-install    (local only) Also install scripts/agentdoc-check.sh into
                  the repo and show where to find GitHub/GitLab CI examples.
                  Adds docs/.agentdoc/status.json to .gitignore if .gitignore exists.

  --help, -h      Print this help and exit.

${BOLD}EXAMPLES${RESET}
  # Global install — skill available everywhere
  $(basename "$0") --mode global

  # Local install — skill only in this repo
  $(basename "$0") --mode local --root /home/user/source/myrepo

  # Local install with CI utility
  $(basename "$0") --mode local --root /home/user/source/myrepo --ci-install

${BOLD}WHAT GETS INSTALLED${RESET}
  global:
    ~/.claude/skills/agentdoc.md

  local:
    <root>/.claude/skills/agentdoc.md

  local --ci-install (additional):
    <root>/scripts/agentdoc-check.sh  (chmod +x applied)
    <root>/.gitignore                 (docs/.agentdoc/status.json appended, if file exists)

${BOLD}AFTER INSTALLATION${RESET}
  Open a Claude Code session in your repo and run:
    /agentdoc init     — create CLAUDE.md and overlay stub
    /agentdoc draft    — fill the overlay from source code
    /agentdoc status   — check documentation health

  Full documentation: $README
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
MODE=""
ROOT=""
CI_INSTALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            [[ $# -lt 2 ]] && die "--mode requires a value (local or global)."
            MODE="$2"
            shift 2
            ;;
        --root)
            [[ $# -lt 2 ]] && die "--root requires a path argument."
            ROOT="$2"
            shift 2
            ;;
        --ci-install)
            CI_INSTALL=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: '$1'. Run with --help for usage."
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

[[ -z "$MODE" ]] && die "--mode is required. Use 'local' or 'global'."

case "$MODE" in
    local|global) ;;
    *) die "Invalid mode '$MODE'. Must be 'local' or 'global'." ;;
esac

if [[ "$MODE" == "local" ]]; then
    [[ -z "$ROOT" ]] && die "--root is required when --mode is local."

    # ROOT must be an absolute path
    [[ "$ROOT" != /* ]] && die "--root must be an absolute path (got: '$ROOT')."

    # ROOT must exist
    [[ ! -d "$ROOT" ]] && die "Directory does not exist: '$ROOT'."

    # ROOT must be a git repository
    if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        die "'$ROOT' is not a git repository."
    fi
fi

if $CI_INSTALL && [[ "$MODE" == "global" ]]; then
    die "--ci-install is only valid with --mode local."
fi

# Verify that source files exist (sanity check for the installer itself)
[[ ! -f "$SKILL_FILE" ]] && die "skill.md not found at '$SKILL_FILE'. Is install.sh in the agentdoc/ directory?"
if $CI_INSTALL; then
    [[ ! -f "$CI_SCRIPT_SRC" ]] && die "agentdoc-check.sh not found at '$CI_SCRIPT_SRC'."
fi

# ---------------------------------------------------------------------------
# Compute destinations
# ---------------------------------------------------------------------------

if [[ "$MODE" == "global" ]]; then
    SKILL_DEST="$HOME/.claude/skills/agentdoc.md"
else
    SKILL_DEST="$ROOT/.claude/skills/agentdoc.md"
fi

CI_SCRIPT_DEST=""
GITIGNORE_PATH=""
GITIGNORE_ENTRY="docs/.agentdoc/status.json"

if [[ "$MODE" == "local" ]]; then
    if $CI_INSTALL; then
        CI_SCRIPT_DEST="$ROOT/scripts/agentdoc-check.sh"
        GITIGNORE_PATH="$ROOT/.gitignore"
    fi
fi

# ---------------------------------------------------------------------------
# Build summary
# ---------------------------------------------------------------------------

echo ""
echo -e "${BOLD}agentdoc — Installation Summary${RESET}"
echo "────────────────────────────────────────────────────"
echo ""
echo -e "${BOLD}Files to create or modify:${RESET}"
echo ""

# Skill file
if [[ -f "$SKILL_DEST" ]]; then
    echo -e "  ${YELLOW}overwrite${RESET}  $SKILL_DEST"
else
    echo -e "  ${GREEN}create${RESET}     $SKILL_DEST"
fi

# CI script
if [[ -n "$CI_SCRIPT_DEST" ]]; then
    if [[ -f "$CI_SCRIPT_DEST" ]]; then
        echo -e "  ${YELLOW}overwrite${RESET}  $CI_SCRIPT_DEST"
    else
        echo -e "  ${GREEN}create${RESET}     $CI_SCRIPT_DEST"
    fi
fi

# .gitignore
if [[ -n "$GITIGNORE_PATH" && -f "$GITIGNORE_PATH" ]]; then
    if grep -qF "$GITIGNORE_ENTRY" "$GITIGNORE_PATH" 2>/dev/null; then
        echo -e "  ${DIM}skip${RESET}       $GITIGNORE_PATH  (${GITIGNORE_ENTRY} already present)"
    else
        echo -e "  ${GREEN}append${RESET}     $GITIGNORE_PATH  (add ${GITIGNORE_ENTRY})"
    fi
fi

echo ""

# CI examples hint
if $CI_INSTALL; then
    echo -e "${BOLD}CI examples available:${RESET}"
    echo ""
    echo -e "  GitHub Actions:  ${DIM}$CI_EXAMPLES_DIR/.github/workflows/agentdoc.yml${RESET}"
    echo -e "  GitLab CI:       ${DIM}$CI_EXAMPLES_DIR/.gitlab/agentdoc.yml${RESET}"
    echo ""
    echo -e "  Copy the relevant file into your repo's CI configuration."
    echo -e "  See Section 11 of ${DIM}$SCRIPT_DIR/agentdoc-design-guide.md${RESET} for full details."
    echo ""
fi

echo "────────────────────────────────────────────────────"
echo ""

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------

read -r -p "Proceed with installation? [y/N] " CONFIRM
echo ""

case "$CONFIRM" in
    [yY][eE][sS]|[yY]) ;;
    *)
        echo -e "${YELLOW}Installation cancelled.${RESET}"
        exit 0
        ;;
esac

# ---------------------------------------------------------------------------
# Execute installation
# ---------------------------------------------------------------------------

# Install skill
mkdir -p "$(dirname "$SKILL_DEST")"
cp "$SKILL_FILE" "$SKILL_DEST"
ok "Skill installed: $SKILL_DEST"

# Install CI script
if [[ -n "$CI_SCRIPT_DEST" ]]; then
    mkdir -p "$(dirname "$CI_SCRIPT_DEST")"
    cp "$CI_SCRIPT_SRC" "$CI_SCRIPT_DEST"
    chmod +x "$CI_SCRIPT_DEST"
    ok "CI utility installed: $CI_SCRIPT_DEST"
fi

# Update .gitignore
if [[ -n "$GITIGNORE_PATH" && -f "$GITIGNORE_PATH" ]]; then
    if grep -qF "$GITIGNORE_ENTRY" "$GITIGNORE_PATH" 2>/dev/null; then
        warn ".gitignore already contains '$GITIGNORE_ENTRY' — skipped."
    else
        printf '\n# agentdoc CI artifact (regenerated on every run)\n%s\n' "$GITIGNORE_ENTRY" \
            >> "$GITIGNORE_PATH"
        ok ".gitignore updated: added $GITIGNORE_ENTRY"
    fi
fi

# ---------------------------------------------------------------------------
# Quick Start summary
# ---------------------------------------------------------------------------

echo ""
echo "────────────────────────────────────────────────────"
echo -e "${BOLD}Installation complete. Quick Start:${RESET}"
echo "────────────────────────────────────────────────────"
echo ""

if [[ "$MODE" == "local" ]]; then
    echo -e "  ${BOLD}1.${RESET} Open a Claude Code session in your repo:"
    echo -e "     ${CYAN}cd $ROOT && claude${RESET}"
else
    echo -e "  ${BOLD}1.${RESET} Open a Claude Code session in any repo:"
    echo -e "     ${CYAN}claude${RESET}"
fi

echo ""
echo -e "  ${BOLD}2.${RESET} Create CLAUDE.md and overlay stub (first time):"
echo -e "     ${CYAN}/agentdoc init${RESET}"
echo ""
echo -e "  ${BOLD}3.${RESET} Fill the overlay by reading your source code:"
echo -e "     ${CYAN}/agentdoc draft${RESET}"
echo ""
echo -e "  ${BOLD}4.${RESET} Add tribal knowledge to the overlay:"
echo -e "     Edit ${CYAN}docs/agent-overlay.md${RESET} — add a '## What NOT to Do' section,"
echo -e "     update ${CYAN}human_input${RESET} in the frontmatter (e.g. 30)."
echo ""

if $CI_INSTALL; then
    echo -e "  ${BOLD}5.${RESET} Check documentation health from the shell:"
    echo -e "     ${CYAN}$CI_SCRIPT_DEST status${RESET}"
    echo ""
    echo -e "  ${BOLD}6.${RESET} Set up CI integration:"
    echo -e "     Copy the relevant example to your CI config:"
    echo -e "     ${DIM}$CI_EXAMPLES_DIR/.github/workflows/agentdoc.yml${RESET}  (GitHub)"
    echo -e "     ${DIM}$CI_EXAMPLES_DIR/.gitlab/agentdoc.yml${RESET}           (GitLab)"
    echo ""
fi

echo -e "  ${BOLD}After code changes:${RESET}"
echo -e "     ${CYAN}/agentdoc maintain${RESET}  — detect and repair drift"
echo -e "     ${CYAN}/agentdoc status${RESET}    — print health dashboard"
echo ""
echo -e "  Full documentation: ${DIM}$README${RESET}"
echo "────────────────────────────────────────────────────"
echo ""
