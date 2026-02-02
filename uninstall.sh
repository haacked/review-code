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
CLAUDE_DIR="${HOME}/.claude"
SKILL_DIR="${CLAUDE_DIR}/skills/review-code"
CONFIG_FILE="${SKILL_DIR}/.env"
OLD_CONFIG_FILE="${CLAUDE_DIR}/review-code.env"

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

    [[ ! -f "${config_file}" ]] && return 0

    # Validate file permissions for security
    local file_owner
    local file_perms

    if [[ "${OSTYPE}" == "darwin"* ]]; then
        file_owner=$(stat -f '%u' "${config_file}" 2> /dev/null)
        file_perms=$(stat -f '%Lp' "${config_file}" 2> /dev/null)
    else
        file_owner=$(stat -c '%u' "${config_file}" 2> /dev/null)
        file_perms=$(stat -c '%a' "${config_file}" 2> /dev/null)
    fi

    # shellcheck disable=SC2312  # id command failure is critical and will be caught
    if [[ "${file_owner}" != "$(id -u)" ]]; then
        error "Config file not owned by current user: ${config_file}"
        return 1
    fi

    local world_perms=$((file_perms % 10))
    if [[ $((world_perms & 2)) -ne 0 ]]; then
        error "Config file is world-writable: ${config_file}"
        error "Fix with: chmod o-w ${config_file}"
        return 1
    fi

    # Parse configuration safely
    while IFS='=' read -r key value; do
        [[ "${key}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${key}" ]] && continue
        [[ ! "${key}" =~ ^[A-Z_][A-Z0-9_]*$ ]] && continue

        value="${value#\"}"
        value="${value%\"}"
        value="${value#\'}"
        value="${value%\'}"

        case "${key}" in
            REVIEW_ROOT_PATH) export REVIEW_ROOT_PATH="${value}" ;;
            CONTEXT_PATH) export CONTEXT_PATH="${value}" ;;
            DIFF_CONTEXT_LINES) export DIFF_CONTEXT_LINES="${value}" ;;
            *) ;; # Ignore unknown keys for forward compatibility
        esac
    done < "${config_file}"

    return 0
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

remove_context_files() {
    # Check new location first, fall back to old location
    local active_config=""
    if [[ -f "${CONFIG_FILE}" ]]; then
        active_config="${CONFIG_FILE}"
    elif [[ -f "${OLD_CONFIG_FILE}" ]]; then
        active_config="${OLD_CONFIG_FILE}"
    else
        return
    fi

    # Load config to find context path
    load_config_safely "${active_config}"
    local context_path="${CONTEXT_PATH:-}"

    if [[ -z "${context_path}" ]] || [[ ! -d "${context_path}" ]]; then
        return
    fi

    echo ""
    echo "Context files location: ${context_path}"
    read -p "Remove context files? (reviews will be preserved) [y/N] " -n 1 -r
    echo ""

    if [[ ${REPLY} =~ ^[Yy]$ ]]; then
        rm -rf "${context_path}"
        info "Removed context files"
    else
        info "Kept context files at ${context_path}"
    fi
}

remove_config() {
    local removed=0

    # Remove new config location
    if [[ -f "${CONFIG_FILE}" ]]; then
        read -p "Remove configuration file (${CONFIG_FILE})? [y/N] " -n 1 -r
        echo ""

        if [[ ${REPLY} =~ ^[Yy]$ ]]; then
            rm "${CONFIG_FILE}"
            info "Removed configuration file"
            removed=1
        else
            info "Kept configuration file"
        fi
    fi

    # Also remove old config location if it exists
    if [[ -f "${OLD_CONFIG_FILE}" ]]; then
        if [[ ${removed} -eq 1 ]]; then
            # Already removed new config, just remove old one silently
            rm "${OLD_CONFIG_FILE}"
            info "Removed old configuration file"
        else
            read -p "Remove old configuration file (${OLD_CONFIG_FILE})? [y/N] " -n 1 -r
            echo ""

            if [[ ${REPLY} =~ ^[Yy]$ ]]; then
                rm "${OLD_CONFIG_FILE}"
                info "Removed old configuration file"
            else
                info "Kept old configuration file"
            fi
        fi
    fi
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

    # Remove components
    info "Removing review-code components…"
    remove_skill
    remove_agents

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
