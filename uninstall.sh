#!/bin/bash
# uninstall.sh - Uninstall review-code from Claude Code
#
# Usage:
#   ./uninstall.sh
#   or
#   ~/.claude/bin/uninstall-review-code.sh (if installed)
#
# Description:
#   Removes review-code files from ~/.claude/ directory
#   Optionally removes context files and configuration

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Directories
CLAUDE_DIR="$HOME/.claude"
CONFIG_FILE="$CLAUDE_DIR/review-code.env"

info() {
    echo -e "${GREEN}✓${NC} $1"
}

warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

error() {
    echo -e "${RED}✗${NC} $1"
}

# Safely load configuration from file without executing arbitrary code
load_config_safely() {
    local config_file="$1"

    [ ! -f "$config_file" ] && return 0

    # Validate file permissions for security
    local file_owner
    local file_perms

    if [[ "$OSTYPE" == "darwin"* ]]; then
        file_owner=$(stat -f '%u' "$config_file" 2>/dev/null)
        file_perms=$(stat -f '%Lp' "$config_file" 2>/dev/null)
    else
        file_owner=$(stat -c '%u' "$config_file" 2>/dev/null)
        file_perms=$(stat -c '%a' "$config_file" 2>/dev/null)
    fi

    if [ "$file_owner" != "$(id -u)" ]; then
        error "Config file not owned by current user: $config_file"
        return 1
    fi

    local world_perms=$((file_perms % 10))
    if [ $((world_perms & 2)) -ne 0 ]; then
        error "Config file is world-writable: $config_file"
        error "Fix with: chmod o-w $config_file"
        return 1
    fi

    # Parse configuration safely
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        [[ ! "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] && continue

        value="${value#\"}"
        value="${value%\"}"
        value="${value#\'}"
        value="${value%\'}"

        case "$key" in
            REVIEW_ROOT_PATH) export REVIEW_ROOT_PATH="$value" ;;
            CONTEXT_PATH) export CONTEXT_PATH="$value" ;;
            DIFF_CONTEXT_LINES) export DIFF_CONTEXT_LINES="$value" ;;
        esac
    done < "$config_file"

    return 0
}

remove_commands() {
    local removed=0

    if [ -f "$CLAUDE_DIR/commands/review-code.md" ]; then
        rm "$CLAUDE_DIR/commands/review-code.md"
        removed=$((removed + 1))
    fi

    if [ $removed -gt 0 ]; then
        info "Removed review-code command"
    fi
}

remove_agents() {
    local agents=(
        "code-review-context-explorer"
        "code-reviewer-security"
        "code-reviewer-performance"
        "code-reviewer-maintainability"
        "code-reviewer-testing"
        "code-reviewer-compatibility"
        "code-reviewer-architecture"
    )

    local removed=0

    for agent in "${agents[@]}"; do
        if [ -f "$CLAUDE_DIR/agents/${agent}.md" ]; then
            rm "$CLAUDE_DIR/agents/${agent}.md"
            removed=$((removed + 1))
        fi
    done

    if [ $removed -gt 0 ]; then
        info "Removed $removed agent files"
    fi
}

remove_scripts() {
    local removed=0

    # Remove review-code subdirectory (contains all helper scripts)
    if [ -d "$CLAUDE_DIR/bin/review-code" ]; then
        rm -rf "$CLAUDE_DIR/bin/review-code"
        info "Removed review-code helper scripts"
        removed=1
    fi

    # Remove uninstall script from main bin directory
    if [ -f "$CLAUDE_DIR/bin/uninstall-review-code.sh" ]; then
        rm "$CLAUDE_DIR/bin/uninstall-review-code.sh"
        removed=$((removed + 1))
    fi

    if [ $removed -gt 0 ]; then
        info "Removed helper scripts"
    fi
}

remove_context_files() {
    if [ ! -f "$CONFIG_FILE" ]; then
        return
    fi

    # Load config to find context path
    load_config_safely "$CONFIG_FILE"
    local context_path="${CONTEXT_PATH:-}"

    if [ -z "$context_path" ] || [ ! -d "$context_path" ]; then
        return
    fi

    echo ""
    echo "Context files location: $context_path"
    read -p "Remove context files? (reviews will be preserved) [y/N] " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$context_path"
        info "Removed context files"
    else
        info "Kept context files at $context_path"
    fi
}

remove_config() {
    if [ -f "$CONFIG_FILE" ]; then
        read -p "Remove configuration file? [y/N] " -n 1 -r
        echo ""

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm "$CONFIG_FILE"
            info "Removed configuration file"
        else
            info "Kept configuration file"
        fi
    fi
}

remove_old_installation() {
    local old_dir="$HOME/.review-code"

    if [ -d "$old_dir" ]; then
        echo ""
        warn "Old installation directory found: $old_dir"
        read -p "Remove old installation directory? [Y/n] " -n 1 -r
        echo ""

        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            rm -rf "$old_dir"
            info "Removed old installation directory"
        fi
    fi
}

main() {
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Review-Code Uninstaller"
    echo "═══════════════════════════════════════════════════════"
    echo ""

    # Remove components
    info "Removing review-code components…"
    remove_commands
    remove_agents
    remove_scripts

    # Ask about context files
    remove_context_files

    # Ask about config
    remove_config

    # Check for old installation
    remove_old_installation

    # Summary
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo ""
    info "Uninstallation complete!"
    echo ""
    echo "Review-code has been removed from ~/.claude/"
    echo ""
    echo "To reinstall:"
    echo "  curl -fsSL https://raw.githubusercontent.com/haacked/review-code/main/install.sh | bash"
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo ""
}

main "$@"
