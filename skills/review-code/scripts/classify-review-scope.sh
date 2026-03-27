#!/usr/bin/env bash
# classify-review-scope.sh - Determine exploration depth and agent selection
# based on diff size and file characteristics.
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
    echo '{"error": "Session file not found"}' >&2
    exit 1
fi

# Extract classification inputs from session JSON (single jq invocation, no eval)
read -r diff_tokens file_count has_frontend source_count test_count config_count migration_count < <(
    jq -r '
        (.file_metadata.modified_files // []) as $files |
        [
            (.diff_tokens // 0 | floor),
            (.file_metadata.file_count // 0),
            (.languages.has_frontend // false),
            ([$files[] | select(.type == "source")] | length),
            ([$files[] | select((.type == "test") or (.is_test == true))] | length),
            ([$files[] | select(.type == "config")] | length),
            ([$files[] | select(.type == "migration")] | length)
        ] | @tsv
    ' "${session_file}"
)

# All 7 core agents
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

# For medium+ diffs, or when file metadata is absent (e.g., deletions-only PRs where
# pre-review-context.sh only parses added files), always run all agents
if [[ "${diff_tokens}" -ge 2000 ]]; then
    agents=("${all_agents[@]}")
    reasoning="Medium or large diff (${diff_tokens} diff tokens, ${file_count} files): running all agents"
elif [[ "${file_count}" -eq 0 ]] && [[ "${diff_tokens}" -gt 0 ]]; then
    # No file metadata (likely a deletions-only PR) - run all core agents to avoid under-reviewing
    agents=("${all_agents[@]}")
    reasoning="No file metadata (${diff_tokens} diff tokens, possible deletions-only change): running all agents"
# For tiny/small diffs, select agents based on file composition
elif [[ "${source_count}" -eq 0 ]] && [[ "${test_count}" -eq 0 ]] && [[ "${migration_count}" -eq 0 ]] && [[ "${file_count}" -gt 0 ]]; then
    # Config-only (note: .md/docs files are classified as source, so this branch only matches
    # changes that contain config files and no source, test, or migration files)
    agents=("correctness" "compatibility")
    reasoning="Config-only change (${diff_tokens} diff tokens, ${config_count} config, ${file_count} total files): correctness + compatibility"
elif [[ "${source_count}" -eq 0 ]] && [[ "${test_count}" -gt 0 ]]; then
    # Test-only changes
    agents=("testing" "correctness" "maintainability")
    reasoning="Test-only change (${diff_tokens} diff tokens, ${test_count} test files): testing + correctness + maintainability"
elif [[ "${migration_count}" -gt 0 ]] && [[ "${source_count}" -eq 0 ]]; then
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
