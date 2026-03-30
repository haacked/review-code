#!/usr/bin/env bash
# classify-review-scope.sh - Determine exploration depth and agent selection
# based on diff size and file characteristics.
# Requires: bash 4+ (uses declare -A associative arrays)
#
# Usage:
#   classify-review-scope.sh <session_file>
#
# Output (JSON):
#   {
#     "exploration_depth": "minimal|standard|thorough",
#     "agents": ["correctness", "security", ...],
#     "skipped_agents": ["performance", ...],
#     "reasoning": "Short explanation of classification"
#   }

set -euo pipefail

session_file="${1:?Usage: classify-review-scope.sh <session_file>}"

if [[ ! -f "${session_file}" ]]; then
    error_json='{"error": "Session file not found"}'
    echo "${error_json}"
    echo "${error_json}" >&2
    exit 1
fi

# Extract classification inputs from session JSON (single jq invocation, no eval)
read -r diff_tokens file_count has_frontend test_count config_count migration_count infra_config_count deleted_count < <(
    jq -r '
        (.file_metadata.modified_files // []) as $files |
        [
            (.diff_tokens // 0 | floor),
            ((.file_metadata.file_count // null) // ($files | length)),
            (.languages.has_frontend // false),
            ([$files[] | select((.type == "test") or (.is_test == true))] | length),
            ([$files[] | select(.type == "config")] | length),
            ([$files[] | select(.type == "migration")] | length),
            ([$files[] | select(.is_infra_config == true)] | length),
            (.file_metadata.deleted_file_count // 0)
        ] | @tsv
    ' "${session_file}"
)

# All 7 core agents (infra-config and frontend are conditional, not core)
all_agents=("security" "performance" "correctness" "maintainability" "testing" "compatibility" "architecture")

# Determine exploration depth
exploration_depth="thorough"
if [[ "${diff_tokens}" -lt 500 ]]; then
    exploration_depth="minimal"
elif [[ "${diff_tokens}" -lt 2000 ]]; then
    exploration_depth="standard"
fi

# Determine agent selection
agents=()
reasoning=""

# Infra-config-only changes always use the infra-config agent regardless of diff size.
# This branch must come before the diff_tokens >= 2000 check to avoid being shadowed.
# Guard against deleted_count > 0: pre-review-context.sh only parses added/modified files,
# so deleted source files won't appear in modified_files. If deletions are present alongside
# infra-config modifications, fall through to normal agent selection to ensure deletions get reviewed.
if [[ "${infra_config_count}" -gt 0 ]] && [[ "${infra_config_count}" -eq "${file_count}" ]] && [[ "${deleted_count}" -eq 0 ]]; then
    # Infra-config only (Helm, Terraform, ArgoCD, K8s, CI/CD)
    agents=("infra-config")
    exploration_depth="minimal"
    reasoning="Infra-config-only change (${diff_tokens} diff tokens, ${infra_config_count} infra config files): infra-config agent"
# For medium+ diffs, or when file metadata is absent (e.g., deletions-only PRs where
# pre-review-context.sh only parses added files), always run all agents
elif [[ "${diff_tokens}" -ge 2000 ]]; then
    agents=("${all_agents[@]}")
    reasoning="Medium or large diff (${diff_tokens} diff tokens, ${file_count} files): running all agents"
elif [[ "${file_count}" -eq 0 ]] && [[ "${diff_tokens}" -gt 0 ]]; then
    # No file metadata (likely a deletions-only PR) - run all core agents to avoid under-reviewing
    agents=("${all_agents[@]}")
    reasoning="No file metadata (${diff_tokens} diff tokens, possible deletions-only change): running all agents"
# For tiny/small diffs, select agents based on file composition
elif [[ "${config_count}" -gt 0 ]] && [[ "${config_count}" -eq "${file_count}" ]]; then
    # Config-only (note: .md/docs files are classified as source, so this branch only matches
    # changes where all modified files are config files)
    agents=("correctness" "compatibility")
    reasoning="Config-only change (${diff_tokens} diff tokens, ${config_count} config, ${file_count} total files): correctness + compatibility"
elif [[ "${test_count}" -gt 0 ]] && [[ "${test_count}" -eq "${file_count}" ]]; then
    # Test-only changes
    agents=("testing" "correctness" "maintainability")
    reasoning="Test-only change (${diff_tokens} diff tokens, ${test_count} test files): testing + correctness + maintainability"
elif [[ "${migration_count}" -gt 0 ]] && [[ "${migration_count}" -eq "${file_count}" ]]; then
    # Migration-only
    agents=("correctness" "compatibility" "security")
    reasoning="Migration-only change (${diff_tokens} diff tokens, ${migration_count} migration files): correctness + compatibility + security"
elif [[ "${diff_tokens}" -lt 500 ]]; then
    # Tiny source change: core agents only
    agents=("correctness" "security" "testing" "architecture")
    reasoning="Tiny source change (${diff_tokens} diff tokens, ${file_count} files): core agents"
else
    # Small source change: most agents
    agents=("correctness" "security" "testing" "architecture" "maintainability")
    # Add compatibility if there are public-facing files
    if [[ "${config_count}" -gt 0 ]] || [[ "${migration_count}" -gt 0 ]]; then
        agents+=("compatibility")
    fi
    reasoning="Small source change (${diff_tokens} diff tokens, ${file_count} files): focused agents"
fi

# Add infra-config agent when infra files are present but the infra-config-only shortcut wasn't
# taken. That covers two cases: mixed infra + non-infra modified files, and infra-only modified
# files that have accompanying deletions (deleted_count > 0 caused the shortcut to be skipped).
if [[ "${infra_config_count}" -gt 0 ]] && { [[ "${infra_config_count}" -lt "${file_count}" ]] || [[ "${deleted_count}" -gt 0 ]]; }; then
    agents+=("infra-config")
fi

# Add frontend agent if applicable and not already gated out by tiny diff
if [[ "${has_frontend}" == "true" ]]; then
    if [[ "${diff_tokens}" -ge 500 ]]; then
        agents+=("frontend")
    else
        # Track that frontend was skipped due to tiny diff
        frontend_skipped=true
    fi
fi

# Compute skipped agents (core agents not selected)
declare -A selected_set
for agent in "${agents[@]}"; do
    selected_set["${agent}"]=1
done

skipped_agents=()
for agent in "${all_agents[@]}"; do
    if [[ -z "${selected_set[${agent}]+x}" ]]; then
        skipped_agents+=("${agent}")
    fi
done
if [[ "${frontend_skipped:-false}" == "true" ]]; then
    skipped_agents+=("frontend")
fi
# Report infra-config as skipped only when infra files were present but agent wasn't selected
if [[ "${infra_config_count}" -gt 0 ]] && [[ -z "${selected_set["infra-config"]+x}" ]]; then
    skipped_agents+=("infra-config")
fi

# Build JSON output
agents_joined=$(
    IFS=$'\n'
    echo "${agents[*]}"
)
skipped_joined=$(
    IFS=$'\n'
    echo "${skipped_agents[*]}"
)

jq -nc \
    --arg depth "${exploration_depth}" \
    --arg reasoning "${reasoning}" \
    --arg agents_raw "${agents_joined}" \
    --arg skipped_raw "${skipped_joined}" \
    '{
        exploration_depth: $depth,
        agents: ($agents_raw | split("\n") | map(select(. != ""))),
        skipped_agents: ($skipped_raw | split("\n") | map(select(. != ""))),
        reasoning: $reasoning
    }'
