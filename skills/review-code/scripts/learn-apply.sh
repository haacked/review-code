#!/usr/bin/env bash
# learn-apply.sh - Synthesize learnings into context file updates
#
# Usage:
#   learn-apply.sh [--threshold N]
#
# Description:
#   Analyzes accumulated learnings from learnings/index.jsonl and proposes
#   context file updates for recurring patterns. Groups learnings by type
#   and target context file, and suggests updates for patterns with 3+
#   occurrences (configurable via --threshold).
#
# Options:
#   --threshold N   Minimum occurrences to propose update (default: 3)
#
# Output:
#   JSON with proposed context updates:
#   {
#     "proposals": [
#       {
#         "target_file": "context/languages/python.md",
#         "section": "## Django Patterns",
#         "content": "Flag ForeignKey access in loops...",
#         "learnings_count": 4,
#         "learnings": [...]
#       }
#     ],
#     "summary": {
#       "total_learnings": 15,
#       "grouped_patterns": 5,
#       "actionable_proposals": 2
#     }
#   }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEARNINGS_DIR="${SCRIPT_DIR}/../learnings"
CONTEXT_DIR="${SCRIPT_DIR}/../../../context"

# Source helpers
source "${SCRIPT_DIR}/helpers/error-helpers.sh"

main() {
    local threshold=3

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --threshold)
                threshold="$2"
                shift 2
                ;;
            *)
                error "Unknown argument: $1"
                exit 1
                ;;
        esac
    done

    # Check for learnings file
    local learnings_file="${LEARNINGS_DIR}/index.jsonl"
    if [[ ! -f "${learnings_file}" ]]; then
        echo '{"proposals":[],"summary":{"total_learnings":0,"grouped_patterns":0,"actionable_proposals":0}}'
        exit 0
    fi

    # Read all learnings
    local learnings="[]"
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        learnings=$(echo "${learnings}" | jq --argjson l "${line}" '. + [$l]')
    done < "${learnings_file}"

    local total_learnings
    total_learnings=$(echo "${learnings}" | jq 'length')

    if [[ "${total_learnings}" -eq 0 ]]; then
        echo '{"proposals":[],"summary":{"total_learnings":0,"grouped_patterns":0,"actionable_proposals":0}}'
        exit 0
    fi

    # Group learnings by type and context
    # Key = type + language + framework (if any)
    # Note: sort_by is required before group_by because jq's group_by only groups
    # consecutive elements with the same key
    local grouped
    grouped=$(echo "${learnings}" | jq '
        sort_by(.type, (.context.language // "unknown"), (.context.framework // "none"))
        | group_by(.type + "_" + (.context.language // "unknown") + "_" + (.context.framework // "none"))
        | map({
            key: .[0].type + "_" + (.[0].context.language // "unknown") + "_" + (.[0].context.framework // "none"),
            type: .[0].type,
            language: (.[0].context.language // "unknown"),
            framework: (.[0].context.framework // null),
            count: length,
            learnings: .
        })
        | sort_by(-.count)
    ')

    local grouped_patterns
    grouped_patterns=$(echo "${grouped}" | jq 'length')

    # Filter to patterns meeting threshold
    local proposals="[]"
    while IFS= read -r group_json; do
        local count type language framework
        count=$(echo "${group_json}" | jq -r '.count')
        type=$(echo "${group_json}" | jq -r '.type')
        language=$(echo "${group_json}" | jq -r '.language')
        framework=$(echo "${group_json}" | jq -r '.framework')

        # Skip if below threshold
        [[ ${count} -lt ${threshold} ]] && continue

        # Determine target context file
        local target_file section_name
        if [[ "${framework}" != "null" ]] && [[ -n "${framework}" ]]; then
            target_file="context/frameworks/${framework}.md"
            section_name="## ${framework^} Patterns"
        elif [[ "${language}" != "unknown" ]]; then
            target_file="context/languages/${language}.md"
            section_name="## ${language^} Patterns"
        else
            target_file="context/general.md"
            section_name="## General Patterns"
        fi

        # Generate proposed content based on type
        local proposed_content=""
        case "${type}" in
            "false_positive")
                # Collect unique feedback patterns
                local feedback_summary
                feedback_summary=$(echo "${group_json}" | jq -r '[.learnings[].user_feedback // empty] | unique | join("; ")')

                proposed_content="### False Positive: ${language^}

When reviewing ${language} code, be aware of these common false positives:

${feedback_summary}

These patterns are typically safe and don't require flagging."
                ;;
            "missed_pattern")
                # Collect descriptions of what was missed
                local missed_descriptions
                missed_descriptions=$(echo "${group_json}" | jq -r '[.learnings[].finding.description // empty] | unique | .[:3] | join("\n- ")')

                proposed_content="### Patterns to Detect: ${language^}

Flag these patterns in ${language} code:

- ${missed_descriptions}

These were identified by other reviewers and should be caught."
                ;;
            "valid_catch")
                # Reinforce patterns that work
                proposed_content="### Validated Patterns: ${language^}

The following patterns are confirmed valuable for ${language} reviews:

$(echo "${group_json}" | jq -r '[.learnings[].finding.description // empty] | unique | .[:3] | map("- " + .) | join("\n")')
"
                ;;
            "deferred")
                proposed_content="### Lower Priority: ${language^}

These issues are valid but often deferred for ${language} code. Consider reducing confidence:

$(echo "${group_json}" | jq -r '[.learnings[].finding.description // empty] | unique | .[:3] | map("- " + .) | join("\n")')
"
                ;;
        esac

        # Add to proposals
        proposals=$(echo "${proposals}" | jq \
            --arg target "${target_file}" \
            --arg section "${section_name}" \
            --arg content "${proposed_content}" \
            --argjson count "${count}" \
            --argjson learnings "$(echo "${group_json}" | jq '.learnings')" \
            '. + [{
                target_file: $target,
                section: $section,
                content: $content,
                learnings_count: $count,
                learnings: $learnings
            }]')
    done < <(echo "${grouped}" | jq -c '.[]')

    local actionable_proposals
    actionable_proposals=$(echo "${proposals}" | jq 'length')

    # Build final output
    jq -n \
        --argjson proposals "${proposals}" \
        --argjson total "${total_learnings}" \
        --argjson grouped "${grouped_patterns}" \
        --argjson actionable "${actionable_proposals}" \
        '{
            proposals: $proposals,
            summary: {
                total_learnings: $total,
                grouped_patterns: $grouped,
                actionable_proposals: $actionable
            }
        }'
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
