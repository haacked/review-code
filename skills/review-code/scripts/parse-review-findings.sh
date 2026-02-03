#!/usr/bin/env bash
# parse-review-findings.sh - Extract structured findings from review markdown files
#
# Usage:
#   parse-review-findings.sh <review-file-path>
#
# Description:
#   Parses a code review markdown file and extracts structured findings.
#   Looks for patterns like:
#   - File:line references in headers: #### `path/to/file.py:123`
#   - Confidence markers: [Security 85%], (75% confidence)
#   - Agent section headers: ## Security Review, ## Performance Review
#
# Output:
#   JSON array of findings:
#   [
#     {
#       "agent": "security",
#       "confidence": 85,
#       "file": "auth.py",
#       "line": 45,
#       "description": "SQL injection risk"
#     }
#   ]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source error helpers
source "${SCRIPT_DIR}/helpers/error-helpers.sh"

# Helper function to save a finding to the findings JSON array
# Args: $1=agent, $2=confidence, $3=file, $4=line, $5=description
# Uses: findings variable (must be in scope)
# Modifies: findings variable
save_finding() {
    local agent="$1"
    local conf="$2"
    local file="$3"
    local line="$4"
    local desc="$5"

    desc=$(echo "${desc}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -c 500)
    findings=$(echo "${findings}" | jq --arg agent "${agent}" \
        --arg conf "${conf}" \
        --arg file "${file}" \
        --arg line "${line}" \
        --arg desc "${desc}" \
        '. + [{
            agent: $agent,
            confidence: ($conf | tonumber),
            file: $file,
            line: ($line | tonumber),
            description: $desc
        }]')
}

main() {
    local review_file="${1:-}"

    if [[ -z "${review_file}" ]]; then
        error "Usage: parse-review-findings.sh <review-file-path>"
        exit 1
    fi

    if [[ ! -f "${review_file}" ]]; then
        error "Review file not found: ${review_file}"
        exit 1
    fi

    # Parse the review file and extract findings
    local findings="[]"
    local current_agent=""
    local current_confidence=""
    local in_finding=false
    local finding_file=""
    local finding_line=""
    local finding_description=""

    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Detect agent section headers (## Security Review, ## Performance Review, etc.)
        if [[ "${line}" =~ ^##[[:space:]]+(Security|Performance|Correctness|Maintainability|Testing|Compatibility|Architecture|Frontend)[[:space:]]+Review ]]; then
            # Save any pending finding before switching sections
            if [[ "${in_finding}" == true ]] && [[ -n "${finding_file}" ]] && [[ -n "${finding_description}" ]]; then
                save_finding "${current_agent:-unknown}" "${current_confidence:-0}" "${finding_file}" "${finding_line}" "${finding_description}"
                in_finding=false
            fi
            current_agent=$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
            finding_file=""
            finding_line=""
            finding_description=""
            current_confidence=""
            continue
        fi

        # Detect file:line reference patterns
        # Pattern 1: #### `path/to/file.py:123`
        if [[ "${line}" =~ ^\#{3,4}[[:space:]]+\`([^:]+):([0-9]+)\` ]]; then
            # Save previous finding if exists
            if [[ "${in_finding}" == true ]] && [[ -n "${finding_file}" ]] && [[ -n "${finding_description}" ]]; then
                save_finding "${current_agent:-unknown}" "${current_confidence:-0}" "${finding_file}" "${finding_line}" "${finding_description}"
            fi

            finding_file="${BASH_REMATCH[1]}"
            finding_line="${BASH_REMATCH[2]}"
            finding_description=""
            current_confidence=""
            in_finding=true
            continue
        fi

        # Pattern 2: - **`path/to/file.py:123`**: description
        if [[ "${line}" =~ ^-[[:space:]]+\*\*\`([^:]+):([0-9]+)\`\*\*:[[:space:]]*(.*)$ ]]; then
            # Save previous finding if needed
            if [[ "${in_finding}" == true ]] && [[ -n "${finding_file}" ]] && [[ -n "${finding_description}" ]]; then
                save_finding "${current_agent:-unknown}" "${current_confidence:-0}" "${finding_file}" "${finding_line}" "${finding_description}"
            fi

            finding_file="${BASH_REMATCH[1]}"
            finding_line="${BASH_REMATCH[2]}"
            finding_description="${BASH_REMATCH[3]}"

            # Check for confidence in the description
            if [[ "${finding_description}" =~ \[([0-9]+)%\] ]] || [[ "${finding_description}" =~ \(([0-9]+)%[[:space:]]*confidence\) ]]; then
                current_confidence="${BASH_REMATCH[1]}"
            fi

            # This pattern includes the description inline, so save it immediately
            save_finding "${current_agent:-unknown}" "${current_confidence:-0}" "${finding_file}" "${finding_line}" "${finding_description}"

            finding_file=""
            finding_line=""
            finding_description=""
            current_confidence=""
            in_finding=false
            continue
        fi

        # Pattern 3: **Location**: `path/to/file.py:123`
        if [[ "${line}" =~ ^\*\*Location\*\*:[[:space:]]*\`([^:]+):([0-9]+)\` ]]; then
            # Save previous finding if exists
            if [[ "${in_finding}" == true ]] && [[ -n "${finding_file}" ]] && [[ -n "${finding_description}" ]]; then
                save_finding "${current_agent:-unknown}" "${current_confidence:-0}" "${finding_file}" "${finding_line}" "${finding_description}"
            fi

            finding_file="${BASH_REMATCH[1]}"
            finding_line="${BASH_REMATCH[2]}"
            finding_description=""
            current_confidence=""
            in_finding=true
            continue
        fi

        # Pattern 4: [Agent 85%] description (file.py:123)
        if [[ "${line}" =~ \[(Security|Performance|Correctness|Maintainability|Testing|Compatibility|Architecture|Frontend)[[:space:]]+([0-9]+)%\][[:space:]]+(.+)[[:space:]]+\(([^:]+):([0-9]+)\) ]]; then
            # Save previous finding if needed
            if [[ "${in_finding}" == true ]] && [[ -n "${finding_file}" ]] && [[ -n "${finding_description}" ]]; then
                save_finding "${current_agent:-unknown}" "${current_confidence:-0}" "${finding_file}" "${finding_line}" "${finding_description}"
            fi

            local agent_name
            agent_name=$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
            current_confidence="${BASH_REMATCH[2]}"
            finding_description="${BASH_REMATCH[3]}"
            finding_file="${BASH_REMATCH[4]}"
            finding_line="${BASH_REMATCH[5]}"

            # Save this finding immediately (inline pattern)
            save_finding "${agent_name}" "${current_confidence}" "${finding_file}" "${finding_line}" "${finding_description}"

            finding_file=""
            finding_line=""
            finding_description=""
            current_confidence=""
            in_finding=false
            continue
        fi

        # Detect confidence markers in current context
        if [[ "${line}" =~ \[([0-9]+)%\] ]] || [[ "${line}" =~ \(([0-9]+)%[[:space:]]*confidence\) ]]; then
            current_confidence="${BASH_REMATCH[1]}"
        fi

        # Accumulate description lines when in a finding (skip empty lines and headers)
        if [[ "${in_finding}" == true ]] && [[ -n "${line}" ]] && [[ ! "${line}" =~ ^# ]]; then
            # Skip confidence-only lines
            if [[ "${line}" =~ ^\[([0-9]+)%\]$ ]] || [[ "${line}" =~ ^\(([0-9]+)%[[:space:]]*confidence\)$ ]]; then
                continue
            fi
            if [[ -n "${finding_description}" ]]; then
                finding_description="${finding_description} ${line}"
            else
                finding_description="${line}"
            fi
        fi
    done < "${review_file}"

    # Handle any remaining finding at end of file
    if [[ "${in_finding}" == true ]] && [[ -n "${finding_file}" ]] && [[ -n "${finding_description}" ]]; then
        save_finding "${current_agent:-unknown}" "${current_confidence:-0}" "${finding_file}" "${finding_line}" "${finding_description}"
    fi

    echo "${findings}"
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
