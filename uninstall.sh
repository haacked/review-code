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
#   Optionally preserves reviews

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Directories - all paths are now fixed under the skill directory
CLAUDE_DIR="${HOME}/.claude"
SKILL_DIR="${CLAUDE_DIR}/skills/review-code"
REVIEWS_DIR="${SKILL_DIR}/reviews"

info() {
    echo -e "${GREEN}✓${NC} $1"
}

warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

error() {
    echo -e "${RED}✗${NC} $1"
}

remove_skill() {
    local removed=0

    # Remove skill directory (new installation location)
    if [[ -d "${CLAUDE_DIR}/skills/review-code" ]]; then
        rm -rf "${CLAUDE_DIR}/skills/review-code"
        info "Removed review-code skill"
        removed=1
    fi

    # Remove old command file (legacy installation)
    if [[ -f "${CLAUDE_DIR}/commands/review-code.md" ]]; then
        rm "${CLAUDE_DIR}/commands/review-code.md"
        info "Removed legacy review-code command"
        removed=$((removed + 1))
    fi

    # Remove old bin scripts (legacy installation)
    if [[ -d "${CLAUDE_DIR}/bin/review-code" ]]; then
        rm -rf "${CLAUDE_DIR}/bin/review-code"
        info "Removed legacy helper scripts"
        removed=$((removed + 1))
    fi

    # Remove uninstall script from main bin directory
    if [[ -f "${CLAUDE_DIR}/bin/uninstall-review-code.sh" ]]; then
        rm "${CLAUDE_DIR}/bin/uninstall-review-code.sh"
        removed=$((removed + 1))
    fi

    if [[ "${removed}" -eq 0 ]]; then
        warn "No review-code installation found"
    fi
}

remove_agents() {
    local agents=(
        "code-review-context-explorer"
        "code-reviewer-security"
        "code-reviewer-performance"
        "code-reviewer-correctness"
        "code-reviewer-maintainability"
        "code-reviewer-testing"
        "code-reviewer-compatibility"
        "code-reviewer-architecture"
        "code-reviewer-frontend"
    )

    local removed=0

    for agent in "${agents[@]}"; do
        if [[ -f "${CLAUDE_DIR}/agents/${agent}.md" ]]; then
            rm "${CLAUDE_DIR}/agents/${agent}.md"
            removed=$((removed + 1))
        fi
    done

    if [[ "${removed}" -gt 0 ]]; then
        info "Removed ${removed} agent files"
    fi
}

preserve_reviews() {
    # Check if there are reviews to preserve
    if [[ ! -d "${REVIEWS_DIR}" ]]; then
        return
    fi
    local dir_contents
    dir_contents=$(ls -A "${REVIEWS_DIR}" 2>/dev/null) || true
    if [[ -z "${dir_contents}" ]]; then
        return
    fi

    echo ""
    echo "Reviews found at: ${REVIEWS_DIR}"
    read -p "Preserve reviews before uninstalling? [Y/n] " -n 1 -r
    echo ""

    if [[ ! ${REPLY} =~ ^[Nn]$ ]]; then
        local backup_dir
        backup_dir="${HOME}/review-code-backup-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "${backup_dir}"
        cp -r "${REVIEWS_DIR}" "${backup_dir}/"
        info "Reviews backed up to: ${backup_dir}/reviews"
    else
        warn "Reviews will be removed with skill directory"
    fi
}

cleanup_old_config_files() {
    # Remove any deprecated config files that may still exist
    local old_config_files=(
        "${SKILL_DIR}/.env"
        "${CLAUDE_DIR}/review-code.env"
    )

    for config_file in "${old_config_files[@]}"; do
        if [[ -f "${config_file}" ]]; then
            rm -f "${config_file}"
            info "Removed deprecated config: ${config_file}"
        fi
    done
}

remove_old_installation() {
    local old_dir="${HOME}/.review-code"

    if [[ -d "${old_dir}" ]]; then
        echo ""
        warn "Old installation directory found: ${old_dir}"
        read -p "Remove old installation directory? [Y/n] " -n 1 -r
        echo ""

        if [[ ! ${REPLY} =~ ^[Nn]$ ]]; then
            rm -rf "${old_dir}"
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

    # Ask about preserving reviews before removing skill
    preserve_reviews

    # Remove components
    info "Removing review-code components…"
    remove_skill
    remove_agents

    # Clean up any old config files
    cleanup_old_config_files

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
