#!/bin/bash
# uninstall.sh - Uninstall review-code from Claude Code and Codex
#
# Usage:
#   ./uninstall.sh
#   or
#   ~/.agents/bin/uninstall-review-code.sh (if installed)
#
# Description:
#   Removes the canonical skill and its managed harness integrations.
#   Optionally preserves reviews

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Directories - all paths are now fixed under the skill directory
CLAUDE_DIR="${HOME}/.claude"
AGENTS_DIR="${HOME}/.agents"
SKILL_DIR="${AGENTS_DIR}/skills/review-code"
CLAUDE_SKILL_LINK="${CLAUDE_DIR}/skills/review-code"
CODEX_HOME_DIR="${CODEX_HOME:-${HOME}/.codex}"
REVIEWS_DIR="${SKILL_DIR}/.reviews"
# Installs that predate the dot-dir migration keep reviews in a visible dir,
# and both can hold content at once: a stale session running the old SKILL.md
# recreates reviews/ after bin/setup migrated to .reviews/. Back up every
# directory that has content. Legacy first so .reviews wins
# collisions, matching the "keep the new copy" rule in migrate_state_dirs.
REVIEW_DIRS=()
SKILL_ROOTS=()
for skill_candidate in "${CLAUDE_SKILL_LINK}" "${SKILL_DIR}"; do
    if [[ -d "${skill_candidate}" && ! -L "${skill_candidate}" ]]; then
        SKILL_ROOTS+=("${skill_candidate}")
        current_reviews_dir="${skill_candidate}/.reviews"
        if [[ "${skill_candidate}" == "${SKILL_DIR}" ]]; then
            current_reviews_dir="${REVIEWS_DIR}"
        fi
        for review_candidate in "${skill_candidate}/reviews" "${current_reviews_dir}"; do
            if [[ -n "$(ls -A "${review_candidate}" 2> /dev/null || true)" ]]; then
                REVIEW_DIRS+=("${review_candidate}")
            fi
        done
    fi
done

# PostHog Desktop agent directories remove_agents cleaned, reported in the
# closing message.
POSTHOG_AGENT_DIRS=()

info() {
    echo -e "${GREEN}✓${NC} $1"
}

warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

error() {
    echo -e "${RED}✗${NC} $1"
}

remove_session_clear_hook() {
    # Run BEFORE remove_skill so the manage-session-hook.sh script still exists.
    local root manager
    for root in ${SKILL_ROOTS[@]+"${SKILL_ROOTS[@]}"}; do
        manager="${root}/scripts/manage-session-hook.sh"
        [[ -x "${manager}" ]] || continue
        if "${manager}" uninstall; then
            info "Removed SessionStart hook from ~/.claude/settings.json"
        else
            warn "Failed to remove SessionStart hook from ~/.claude/settings.json"
        fi
    done
}

remove_skill() {
    local removed=0

    if [[ -L "${CLAUDE_SKILL_LINK}" ]]; then
        if [[ "$(readlink "${CLAUDE_SKILL_LINK}")" == "${SKILL_DIR}" ]]; then
            rm "${CLAUDE_SKILL_LINK}"
            removed=$((removed + 1))
        else
            warn "Leaving unmanaged skill link: ${CLAUDE_SKILL_LINK}"
        fi
    fi

    local root
    for root in ${SKILL_ROOTS[@]+"${SKILL_ROOTS[@]}"}; do
        if remove_installed_files "${root}"; then
            info "Removed installed review-code files: ${root}"
            removed=$((removed + 1))
        else
            warn "No ownership manifest at ${root}; leaving its contents intact"
        fi
        disable_skill_entrypoint "${root}"
    done

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
    local script
    for script in "${AGENTS_DIR}/bin/uninstall-review-code.sh" "${CLAUDE_DIR}/bin/uninstall-review-code.sh"; do
        if [[ -f "${script}" && ! -L "${script}" ]]; then
            rm "${script}"
            removed=$((removed + 1))
        fi
    done

    if [[ "${removed}" -eq 0 ]]; then
        warn "No review-code installation found"
    fi
}

disable_skill_entrypoint() {
    local root="$1"
    local entrypoint="${root}/SKILL.md"
    [[ -e "${entrypoint}" || -L "${entrypoint}" ]] || return 0

    local retained="${root}/SKILL.md.uninstalled"
    local suffix=1
    while [[ -e "${retained}" || -L "${retained}" ]]; do
        retained="${root}/SKILL.md.uninstalled.${suffix}"
        suffix=$((suffix + 1))
    done
    mv "${entrypoint}" "${retained}"
    info "Retained skill entrypoint: ${retained}"
}

remove_installed_files() {
    local root="$1"
    local manifest="${root}/.install-manifest"
    [[ -f "${manifest}" && ! -L "${manifest}" ]] || return 1

    local physical_root
    physical_root="$(cd "${root}" && pwd -P)"
    local expected_fingerprint relative target physical_dir actual_fingerprint
    while IFS=$'\t' read -r expected_fingerprint relative; do
        [[ "${expected_fingerprint}" =~ ^[0-9]+\ [0-9]+$ ]] || continue
        [[ -n "${relative}" && "${relative}" != /* && "${relative}" != *//* ]] || continue
        [[ ! "${relative}" =~ (^|/)\.\.(/|$) && ! "${relative}" =~ (^|/)\.(/|$) ]] || continue
        case "${relative}" in
            SKILL.md | .learnings/README.md | scripts/* | handlers/* | briefing/* | context/*) ;;
            *) continue ;;
        esac

        target="${root}/${relative}"
        [[ -f "${target}" && ! -L "${target}" ]] || continue
        physical_dir="$(cd -P "$(dirname "${target}")" && pwd)"
        case "${physical_dir}" in
            "${physical_root}" | "${physical_root}/"*) ;;
            *) continue ;;
        esac
        actual_fingerprint="$(cksum "${target}" | awk '{print $1 " " $2}')"
        if [[ "${actual_fingerprint}" == "${expected_fingerprint}" ]]; then
            rm "${target}"
        fi
    done < "${manifest}"

    rm "${manifest}"
    rmdir "${root}/scripts/helpers" "${root}/scripts/session-hooks" "${root}/scripts" \
        "${root}/handlers" "${root}/briefing" 2> /dev/null || true
    rmdir "${root}" 2> /dev/null || true
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
        "code-reviewer-infra-config"
        "code-reviewer-comment"
        "code-reviewer-voice"
        "comprehension-gate"
        "finding-validator"
    )

    # Agents are installed to ~/.claude plus any PostHog Desktop config homes
    # (the app points CLAUDE_CONFIG_DIR at its own data directory). The glob
    # also matches dev builds (posthog-code-dev); keep it in sync with its
    # copy in bin/setup's install_agents().
    local agent_dirs=("${CLAUDE_DIR}/agents")
    local config_home
    for config_home in \
        "${HOME}/Library/Application Support/@posthog/"posthog-code*/claude \
        "${HOME}/.config/@posthog/"posthog-code*/claude; do
        if [[ -d "${config_home}" ]]; then
            agent_dirs+=("${config_home}/agents")
            POSTHOG_AGENT_DIRS+=("${config_home}/agents")
        fi
    done

    local removed=0
    local dir
    for dir in "${agent_dirs[@]}"; do
        for agent in "${agents[@]}"; do
            if [[ -f "${dir}/${agent}.md" ]]; then
                rm "${dir}/${agent}.md"
                removed=$((removed + 1))
            fi
        done
    done

    if [[ "${removed}" -gt 0 ]]; then
        info "Removed ${removed} agent files"
    fi
}

remove_codex_agents() {
    local staging="${CODEX_HOME_DIR}/.review-code-agents"
    local agents_dir="${CODEX_HOME_DIR}/agents"
    # Keep ownership checks in sync with bin/install-codex.sh.
    local managed_header="# Managed by bin/install-codex.sh from the review-code repo."
    local agent
    for agent in "${agents_dir}/"*.toml; do
        if [[ -L "${agent}" ]]; then
            case "$(readlink "${agent}")" in
                "${staging}/"*) rm "${agent}" ;;
                *) ;;
            esac
        elif [[ -f "${agent}" && "$(head -n 1 "${agent}")" == "${managed_header}" ]]; then
            rm "${agent}"
        fi
    done
    if [[ -d "${staging}" && ! -L "${staging}" ]]; then
        for agent in "${staging}/"*.toml; do
            if [[ -f "${agent}" && ! -L "${agent}" && "$(head -n 1 "${agent}")" == "${managed_header}" ]]; then
                rm "${agent}"
            fi
        done
        rmdir "${staging}" 2> /dev/null || true
    fi
}

preserve_reviews() {
    if [[ ${#REVIEW_DIRS[@]} -eq 0 ]]; then
        return
    fi

    echo ""
    local dir
    for dir in "${REVIEW_DIRS[@]}"; do
        echo "Reviews found at: ${dir}"
    done
    read -p "Back up reviews before uninstalling? [Y/n] " -n 1 -r
    echo ""

    if [[ ! ${REPLY} =~ ^[Nn]$ ]]; then
        local backup_dir
        backup_dir="${HOME}/review-code-backup-$(date +%Y%m%d-%H%M%S)"
        # Copy contents into a visible reviews/ dir so the backup isn't a
        # hidden .reviews directory.
        mkdir -p "${backup_dir}/reviews"
        for dir in "${REVIEW_DIRS[@]}"; do
            cp -R "${dir}/." "${backup_dir}/reviews/"
        done
        info "Reviews backed up to: ${backup_dir}/reviews"
    else
        info "Reviews remain in the skill directory"
    fi
}

cleanup_old_config_files() {
    # Remove any deprecated config files that may still exist
    local old_config_files=(
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
    remove_session_clear_hook
    remove_skill
    remove_agents
    remove_codex_agents

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
    echo "Managed review-code files have been removed from ~/.agents/, ~/.claude/, and ${CODEX_HOME_DIR}/"
    local posthog_agent_dir
    for posthog_agent_dir in ${POSTHOG_AGENT_DIRS[@]+"${POSTHOG_AGENT_DIRS[@]}"}; do
        echo "Agents removed from PostHog Desktop: ${posthog_agent_dir}/"
    done
    echo ""
    echo "To reinstall:"
    echo "  curl -fsSL https://raw.githubusercontent.com/haacked/review-code/main/install.sh | bash"
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo ""
}

main "$@"
