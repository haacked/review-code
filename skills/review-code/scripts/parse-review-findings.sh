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

# Append a finding as a single JSONL line.
# Args: $1=agent, $2=confidence, $3=file, $4=line, $5=description,
#       $6=number (optional), $7=prefix (optional), $8=title (optional),
#       $9=conclusion_status (optional), $10=conclusion_reason (optional)
# Uses: findings_jsonl variable (must be in scope)
# Modifies: findings_jsonl variable
save_finding() {
    local agent="$1"
    local conf="$2"
    local file="$3"
    local line="$4"
    local desc="$5"
    local number="${6:-}"
    local prefix="${7:-}"
    local title="${8:-}"
    local conclusion_status="${9:-}"
    local conclusion_reason="${10:-}"

    desc=$(echo "${desc}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -c 500)
    local entry
    entry=$(jq -nc --arg agent "${agent}" \
        --arg conf "${conf}" \
        --arg file "${file}" \
        --arg line "${line}" \
        --arg desc "${desc}" \
        --arg number "${number}" \
        --arg prefix "${prefix}" \
        --arg title "${title}" \
        --arg cstatus "${conclusion_status}" \
        --arg creason "${conclusion_reason}" \
        '{
            agent: $agent,
            confidence: ($conf | tonumber),
            file: $file,
            line: ($line | tonumber),
            description: $desc,
            number: (if $number == "" then null else $number end),
            prefix: (if $prefix == "" then null else $prefix end),
            title: (if $title == "" then null else $title end),
            conclusion: (if $cstatus == "" then null else {
                status: $cstatus,
                reason: (if $creason == "" then null else $creason end)
            } end)
        }')
    findings_jsonl+="${entry}"$'\n'
}

# Flush any pending finding to the findings array
# Uses parent scope variables: in_finding, finding_file, finding_description,
#   finding_line, current_agent, current_confidence, finding_number,
#   finding_prefix, finding_title, finding_conclusion_status,
#   finding_conclusion_reason
flush_pending_finding() {
    if [[ "${in_finding}" == true ]] && [[ -n "${finding_description}" ]]; then
        save_finding "${current_agent:-unknown}" "${current_confidence:-0}" \
            "${finding_file:-}" "${finding_line:-0}" "${finding_description}" \
            "${finding_number:-}" "${finding_prefix:-}" "${finding_title:-}" \
            "${finding_conclusion_status:-}" "${finding_conclusion_reason:-}"
    fi
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

    # Parse the review file and extract findings as JSONL (one JSON object per line)
    local findings_jsonl=""
    local current_agent=""
    local current_confidence=""
    local in_finding=false
    local finding_file=""
    local finding_line=""
    local finding_description=""
    local finding_number=""
    local finding_prefix=""
    local finding_title=""
    local finding_conclusion_status=""
    local finding_conclusion_reason=""

    # Regex patterns stored in variables to avoid bash parsing issues with )
    local re_trailing_paren='^(.+)[[:space:]]+\([^)]+\)$'
    local re_qn_heading='^\#{2,4}[[:space:]]+(Q[0-9]+|N[0-9]+):[[:space:]]*(.+)$'

    # Helper to reset finding-level state
    reset_finding_state() {
        finding_file=""
        finding_line=""
        finding_description=""
        finding_number=""
        finding_prefix=""
        finding_title=""
        finding_conclusion_status=""
        finding_conclusion_reason=""
        current_confidence=""
    }

    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Detect agent section headers (## Security Review, ## Performance Review, etc.)
        if [[ "${line}" =~ ^##[[:space:]]+(Security|Performance|Correctness|Maintainability|Testing|Compatibility|Architecture|Frontend)[[:space:]]+Review ]]; then
            flush_pending_finding
            in_finding=false
            current_agent=$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
            reset_finding_state
            continue
        fi

        # Detect CONCLUSION lines (case-insensitive) within a finding
        if [[ "${in_finding}" == true ]]; then
            local line_lower
            line_lower=$(echo "${line}" | tr '[:upper:]' '[:lower:]')
            if [[ "${line_lower}" =~ ^conclusion:[[:space:]]* ]]; then
                # Extract the raw value after "CONCLUSION: " (preserving original case)
                local conclusion_raw="${line#*: }"
                # Handle case where there's no space after colon
                if [[ "${conclusion_raw}" == "${line}" ]]; then
                    conclusion_raw="${line#*:}"
                    conclusion_raw="${conclusion_raw#"${conclusion_raw%%[![:space:]]*}"}"
                fi
                # Strip trailing period
                conclusion_raw="${conclusion_raw%.}"
                # Split on first " - " (space-dash-space) to get status and optional reason
                if [[ "${conclusion_raw}" == *" - "* ]]; then
                    finding_conclusion_status="${conclusion_raw%% - *}"
                    finding_conclusion_reason="${conclusion_raw#* - }"
                else
                    finding_conclusion_status="${conclusion_raw}"
                    finding_conclusion_reason=""
                fi
                continue
            fi
        fi

        # Pattern: Numbered finding heading
        # Matches: ### 1. `blocking`: Title (Agent, 85%)
        #          #### 8. `suggestion`: Title (Agent 95% + Agent 80%, 2 agents)
        if [[ "${line}" =~ ^\#{2,4}[[:space:]]+([0-9]+)\.[[:space:]]+\`(blocking|suggestion|nit|question)\`:[[:space:]]*(.+)$ ]]; then
            flush_pending_finding

            finding_number="${BASH_REMATCH[1]}"
            finding_prefix="${BASH_REMATCH[2]}"
            # Extract title: strip trailing parenthetical (agent info)
            local raw_title="${BASH_REMATCH[3]}"
            if [[ "${raw_title}" =~ ${re_trailing_paren} ]]; then
                finding_title="${BASH_REMATCH[1]}"
            else
                finding_title="${raw_title}"
            fi
            finding_description="${finding_title}"
            finding_file=""
            finding_line="0"
            finding_conclusion_status=""
            finding_conclusion_reason=""
            in_finding=true
            continue
        fi

        # Pattern: Q/N-prefix heading
        # Matches: ### Q1: Title (Agent, 50%)
        #          ### N2: Title
        if [[ "${line}" =~ ${re_qn_heading} ]]; then
            flush_pending_finding

            finding_number="${BASH_REMATCH[1]}"
            local raw_title="${BASH_REMATCH[2]}"
            # Infer prefix from letter
            if [[ "${finding_number}" =~ ^Q ]]; then
                finding_prefix="question"
            else
                finding_prefix="nit"
            fi
            if [[ "${raw_title}" =~ ${re_trailing_paren} ]]; then
                finding_title="${BASH_REMATCH[1]}"
            else
                finding_title="${raw_title}"
            fi
            finding_description="${finding_title}"
            finding_file=""
            finding_line="0"
            finding_conclusion_status=""
            finding_conclusion_reason=""
            in_finding=true
            continue
        fi

        # Detect file:line reference patterns
        # Pattern 1: #### `path/to/file.py:123`
        if [[ "${line}" =~ ^\#{3,4}[[:space:]]+\`([^:]+):([0-9]+)\` ]]; then
            flush_pending_finding
            reset_finding_state

            finding_file="${BASH_REMATCH[1]}"
            finding_line="${BASH_REMATCH[2]}"
            in_finding=true
            continue
        fi

        # Pattern 5: ### `severity`: Description Title (unnumbered)
        # Matches the review format: ### `blocking`: IPv6-Mapped IPv4 Address SSRF Bypass
        if [[ "${line}" =~ ^\#{2,3}[[:space:]]+\`(blocking|suggestion|nit|question)\`:[[:space:]]*(.+)$ ]]; then
            flush_pending_finding

            finding_prefix="${BASH_REMATCH[1]}"
            finding_description="${BASH_REMATCH[2]}"
            finding_title="${BASH_REMATCH[2]}"
            finding_number=""
            finding_file=""
            finding_line="0"
            finding_conclusion_status=""
            finding_conclusion_reason=""
            in_finding=true
            continue
        fi

        # Pattern 6: **File:** `path/to/file.py` (optionally with line info)
        # Captures the file path from the first backtick-quoted string after **File:**
        if [[ "${in_finding}" == true ]] && [[ "${line}" =~ ^\*\*File:\*\*[[:space:]]*\`([^\`]+)\` ]]; then
            finding_file="${BASH_REMATCH[1]}"

            # Check if file path itself contains :linenum
            if [[ "${finding_file}" =~ ^(.+):([0-9]+)$ ]]; then
                finding_file="${BASH_REMATCH[1]}"
                finding_line="${BASH_REMATCH[2]}"
            # Check rest of line for "line(s) N" pattern
            elif [[ "${line}" =~ lines?[[:space:]]+([0-9]+) ]]; then
                finding_line="${BASH_REMATCH[1]}"
            fi
            continue
        fi

        # Pattern 7: **`file:line`** or **`file:line-line`** (bold backtick file ref within a finding)
        # Matches: **`posthog/storage/team_access_cache.py:22-28`**
        if [[ "${in_finding}" == true ]] && [[ "${line}" =~ ^\*\*\`([^:]+):([0-9]+)(-[0-9]+)?\`\*\* ]]; then
            finding_file="${BASH_REMATCH[1]}"
            finding_line="${BASH_REMATCH[2]}"
            continue
        fi

        # Pattern 2: - **`path/to/file.py:123`**: description
        if [[ "${line}" =~ ^-[[:space:]]+\*\*\`([^:]+):([0-9]+)\`\*\*:[[:space:]]*(.*)$ ]]; then
            flush_pending_finding
            reset_finding_state

            finding_file="${BASH_REMATCH[1]}"
            finding_line="${BASH_REMATCH[2]}"
            finding_description="${BASH_REMATCH[3]}"

            # Check for confidence in the description
            if [[ "${finding_description}" =~ \[([0-9]+)%\] ]] || [[ "${finding_description}" =~ \(([0-9]+)%[[:space:]]*confidence\) ]]; then
                current_confidence="${BASH_REMATCH[1]}"
            fi

            # This pattern includes the description inline, so save it immediately
            save_finding "${current_agent:-unknown}" "${current_confidence:-0}" "${finding_file}" "${finding_line}" "${finding_description}"

            reset_finding_state
            in_finding=false
            continue
        fi

        # Pattern 3: **Location**: `path/to/file.py:123`
        if [[ "${line}" =~ ^\*\*Location\*\*:[[:space:]]*\`([^:]+):([0-9]+)\` ]]; then
            flush_pending_finding
            reset_finding_state

            finding_file="${BASH_REMATCH[1]}"
            finding_line="${BASH_REMATCH[2]}"
            in_finding=true
            continue
        fi

        # Pattern 4: [Agent 85%] description (file.py:123)
        if [[ "${line}" =~ \[(Security|Performance|Correctness|Maintainability|Testing|Compatibility|Architecture|Frontend)[[:space:]]+([0-9]+)%\][[:space:]]+(.+)[[:space:]]+\(([^:]+):([0-9]+)\) ]]; then
            flush_pending_finding
            reset_finding_state

            local agent_name
            agent_name=$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
            current_confidence="${BASH_REMATCH[2]}"
            finding_description="${BASH_REMATCH[3]}"
            finding_file="${BASH_REMATCH[4]}"
            finding_line="${BASH_REMATCH[5]}"

            # Save this finding immediately (inline pattern)
            save_finding "${agent_name}" "${current_confidence}" "${finding_file}" "${finding_line}" "${finding_description}"

            reset_finding_state
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
    flush_pending_finding

    # Convert JSONL lines to a JSON array
    if [[ -z "${findings_jsonl}" ]]; then
        echo "[]"
    else
        echo "${findings_jsonl}" | jq -s '.'
    fi
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
