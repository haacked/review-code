#!/usr/bin/env bash
# shellcheck disable=SC2016  # regex literals; $ and backslashes are ERE syntax, not shell expansions
# parse-review-findings.sh - Extract structured findings from review markdown files
#
# Usage:
#   parse-review-findings.sh [--with-spans] <review-file-path>
#
# Description:
#   Parses a code review markdown file and extracts structured findings.
#   Looks for patterns like:
#   - File:line references in headers: #### `path/to/file.py:123`
#   - Confidence markers: [Security 85%], (75% confidence)
#   - Agent section headers: ## Security Review, ## Performance Review
#
# Options:
#   --with-spans  Add the line range each finding occupies in the file, plus
#                 whether that range is safe to cut. carry-forward-findings.sh
#                 uses it to prune a review in place without the document
#                 entering a conversation.
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
#
#   With --with-spans, each finding also carries:
#     "start_line": 12, "end_line": 30, "deletable": true
#   `start_line` is the finding's opening line and `end_line` the last non-blank
#   line before the next heading or thematic break. `deletable` is false when the
#   opener is not a heading (a `**Location**:` line, say), where the extent is a
#   guess and cutting on it could take a sibling's text along.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source error helpers
source "${SCRIPT_DIR}/helpers/error-helpers.sh"

WITH_SPANS=false

# Append a finding as a single JSONL line.
# Args: $1=agent, $2=confidence, $3=file, $4=line, $5=description,
#       $6=start_line, $7=end_line, $8=deletable
# Uses: findings_jsonl variable (must be in scope)
# Modifies: findings_jsonl variable
save_finding() {
    local agent="$1"
    local conf="$2"
    local file="$3"
    local line="$4"
    local desc="$5"
    local start="${6:-0}"
    local end="${7:-0}"
    local deletable="${8:-false}"

    desc=$(echo "${desc}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -c 500)
    local entry
    entry=$(jq -nc --arg agent "${agent}" \
        --arg conf "${conf}" \
        --arg file "${file}" \
        --arg line "${line}" \
        --arg desc "${desc}" \
        --arg start "${start}" \
        --arg end "${end}" \
        --arg deletable "${deletable}" \
        --arg spans "${WITH_SPANS}" \
        '{
            agent: $agent,
            confidence: ($conf | tonumber),
            file: $file,
            line: ($line | tonumber),
            description: $desc
        }
        + (if $spans == "true" then {
            start_line: ($start | tonumber),
            end_line: ($end | tonumber),
            deletable: ($deletable == "true")
        } else {} end)')
    findings_jsonl+="${entry}"$'\n'
}

# Flush any pending finding to the findings array
# Uses parent scope variables: in_finding, finding_file, finding_description,
#   finding_line, current_agent, current_confidence, findings
flush_pending_finding() {
    if [[ "${in_finding}" == true ]] && [[ -n "${finding_description}" ]]; then
        local end="${finding_end}"
        # A finding that never met a heading runs to the last non-blank line seen.
        if [[ "${end}" -eq 0 ]]; then
            end="${prev_nonblank}"
        fi
        save_finding "${current_agent:-unknown}" "${current_confidence:-0}" "${finding_file:-}" "${finding_line:-0}" "${finding_description}" \
            "${finding_start:-0}" "${end}" "${finding_deletable:-false}"
    fi
}

main() {
    local review_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --with-spans)
                WITH_SPANS=true
                shift
                ;;
            *)
                review_file="$1"
                shift
                ;;
        esac
    done

    if [[ -z "${review_file}" ]]; then
        error "Usage: parse-review-findings.sh [--with-spans] <review-file-path>"
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
    local finding_start=0
    local finding_end=0
    local finding_deletable=false
    local lineno=0
    local prev_nonblank=0
    local fence_depth=0
    local fence_stack=()

    # H3/H4 finding header with optional numbering and optional backticks
    # around the path:line token (see Pattern 1 below). Kept in variables
    # because a backtick inside a bracket expression defeats inline =~.
    local finding_header_re='^#{3,4}[[:space:]]+([0-9]+\.[[:space:]]+)?`?([^:`]+):([0-9]+)`?'
    # Numbered prose-title finding header: ### 2. The allowlist does not hold
    local prose_header_re='^#{3,4}[[:space:]]+[0-9]+\.[[:space:]]+(.+)$'
    # Standalone location line under a prose-titled finding: `path/file.sh:14`
    # or `path/file.sh:73-74`
    local standalone_loc_re='^`([^:`]+):([0-9]+)(-[0-9]+)?`[[:space:]]*$'
    # Fenced code block delimiter, with the marker run and whatever follows it
    # captured separately. Nesting is counted rather than toggled: this repo's
    # own finding format puts a ```suggestion block inside a ```text body, which
    # a strict CommonMark toggle reads as a close followed by an open, and every
    # heading after it then looks like code.
    local fence_re='^[[:space:]]{0,3}(`{3,}|~{3,})(.*)$'
    # A heading or thematic break ends the finding block above it.
    local block_break_re='^(#{1,6}([[:space:]]|$)|-{3,}[[:space:]]*$|\*{3,}[[:space:]]*$)'

    while IFS= read -r line || [[ -n "${line}" ]]; do
        lineno=$((lineno + 1))

        # Track fenced code blocks. A `#` inside one is a comment, not a
        # heading, and a finding pattern inside one is an example, not a finding.
        # A delimiter carrying an info string (```suggestion) always opens a
        # block; a bare delimiter closes the innermost open block, or opens one
        # when nothing is open.
        local is_fence_line=false
        if [[ "${line}" =~ ${fence_re} ]]; then
            local fence_char="${BASH_REMATCH[1]:0:1}"
            local fence_rest="${BASH_REMATCH[2]}"
            is_fence_line=true
            if [[ "${fence_rest}" =~ ^[[:space:]]*$ ]] && [[ "${fence_depth}" -gt 0 ]] \
                && [[ "${fence_stack[$((fence_depth - 1))]}" == "${fence_char}" ]]; then
                unset 'fence_stack[fence_depth-1]'
                fence_depth=$((fence_depth - 1))
            else
                fence_stack[fence_depth]="${fence_char}"
                fence_depth=$((fence_depth + 1))
            fi
        fi

        if [[ "${fence_depth}" -eq 0 ]] && [[ "${is_fence_line}" == false ]] \
            && [[ "${line}" =~ ${block_break_re} ]] \
            && [[ "${in_finding}" == true ]] && [[ "${finding_end}" -eq 0 ]]; then
            finding_end="${prev_nonblank}"
        fi

        if [[ -n "${line}" ]]; then
            prev_nonblank="${lineno}"
        fi

        if [[ "${fence_depth}" -gt 0 ]] || [[ "${is_fence_line}" == true ]]; then
            # Inside a code block only description accumulation applies, and it
            # skips lines starting with `#` exactly as it always has.
            if [[ "${in_finding}" == true ]] && [[ -n "${line}" ]] && [[ ! "${line}" =~ ^# ]]; then
                if [[ -n "${finding_description}" ]]; then
                    finding_description="${finding_description} ${line}"
                else
                    finding_description="${line}"
                fi
            fi
            continue
        fi

        # Detect agent section headers (## Security Review, ## Performance Review, etc.)
        if [[ "${line}" =~ ^##[[:space:]]+(Security|Performance|Correctness|Maintainability|Testing|Compatibility|Architecture|Frontend)[[:space:]]+Review ]]; then
            flush_pending_finding
            in_finding=false
            current_agent=$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
            finding_file=""
            finding_line=""
            finding_description=""
            current_confidence=""
            continue
        fi

        # Detect file:line reference patterns
        # Pattern 1: #### `path/to/file.py:123`. Reviews vary the header shape,
        # so accept optional "N. " numbering (### 1. `path:123`) and headers
        # without backticks (#### path/to/file.py:123).
        if [[ "${line}" =~ ${finding_header_re} ]]; then
            flush_pending_finding

            finding_file="${BASH_REMATCH[2]}"
            finding_line="${BASH_REMATCH[3]}"
            finding_description=""
            current_confidence=""
            in_finding=true
            finding_start="${lineno}"
            finding_end=0
            finding_deletable=true
            continue
        fi

        # Pattern 1b: numbered prose-title header (### 2. The allowlist does
        # not hold). The location arrives later, either inline in the body or
        # as a standalone `path:line` line (Pattern 1c).
        if [[ "${line}" =~ ${prose_header_re} ]]; then
            flush_pending_finding

            finding_file=""
            finding_line=""
            finding_description="${BASH_REMATCH[1]}"
            current_confidence=""
            in_finding=true
            finding_start="${lineno}"
            finding_end=0
            finding_deletable=true
            continue
        fi

        # Pattern 1c: standalone location line for the current finding. For a
        # range, keep the starting line.
        if [[ "${in_finding}" == true ]] && [[ -z "${finding_file}" ]] \
            && [[ "${line}" =~ ${standalone_loc_re} ]]; then
            finding_file="${BASH_REMATCH[1]}"
            finding_line="${BASH_REMATCH[2]}"
            continue
        fi

        # Pattern 5: ### `severity`: Description Title
        # Matches the review format: ### `blocking`: IPv6-Mapped IPv4 Address SSRF Bypass
        if [[ "${line}" =~ ^\#{2,3}[[:space:]]+\`(blocking|suggestion|nit|question)\`:[[:space:]]*(.+)$ ]]; then
            flush_pending_finding

            finding_description="${BASH_REMATCH[2]}"
            finding_file=""
            finding_line="0"
            in_finding=true
            finding_start="${lineno}"
            finding_end=0
            finding_deletable=true
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

        # Pattern 2: - **`path/to/file.py:123`**: description
        if [[ "${line}" =~ ^-[[:space:]]+\*\*\`([^:]+):([0-9]+)\`\*\*:[[:space:]]*(.*)$ ]]; then
            flush_pending_finding

            finding_file="${BASH_REMATCH[1]}"
            finding_line="${BASH_REMATCH[2]}"
            finding_description="${BASH_REMATCH[3]}"

            # Check for confidence in the description
            if [[ "${finding_description}" =~ \[([0-9]+)%\] ]] || [[ "${finding_description}" =~ \(([0-9]+)%[[:space:]]*confidence\) ]]; then
                current_confidence="${BASH_REMATCH[1]}"
            fi

            # This pattern includes the description inline, so save it immediately
            save_finding "${current_agent:-unknown}" "${current_confidence:-0}" "${finding_file}" "${finding_line}" "${finding_description}" \
                "${lineno}" "${lineno}" true

            finding_file=""
            finding_line=""
            finding_description=""
            current_confidence=""
            in_finding=false
            continue
        fi

        # Pattern 3: **Location**: `path/to/file.py:123`
        if [[ "${line}" =~ ^\*\*Location\*\*:[[:space:]]*\`([^:]+):([0-9]+)\` ]]; then
            flush_pending_finding

            finding_file="${BASH_REMATCH[1]}"
            finding_line="${BASH_REMATCH[2]}"
            finding_description=""
            current_confidence=""
            in_finding=true
            finding_start="${lineno}"
            finding_end=0
            # The opener is body text rather than a heading, so where this
            # finding ends is a guess. Report it, never let a caller cut on it.
            finding_deletable=false
            continue
        fi

        # Pattern 4: [Agent 85%] description (file.py:123)
        if [[ "${line}" =~ \[(Security|Performance|Correctness|Maintainability|Testing|Compatibility|Architecture|Frontend)[[:space:]]+([0-9]+)%\][[:space:]]+(.+)[[:space:]]+\(([^:]+):([0-9]+)\) ]]; then
            flush_pending_finding

            local agent_name
            agent_name=$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
            current_confidence="${BASH_REMATCH[2]}"
            finding_description="${BASH_REMATCH[3]}"
            finding_file="${BASH_REMATCH[4]}"
            finding_line="${BASH_REMATCH[5]}"

            # Save this finding immediately (inline pattern)
            save_finding "${agent_name}" "${current_confidence}" "${finding_file}" "${finding_line}" "${finding_description}" \
                "${lineno}" "${lineno}" true

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
