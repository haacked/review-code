#!/usr/bin/env bash
# eval-helpers.sh - Shared helper functions for eval scripts
#
# Provides:
#   resolve_benchmark_dir() - Resolve benchmark directory from ID
#   check_match()           - Generic finding/trap matching logic
#   check_finding_match()   - Check if a parsed finding matches an expected finding
#   check_trap_match()      - Check if a parsed finding triggers a false-positive trap
#
# Requires EVALS_DIR and REGISTRY to be set by the sourcing script.

# Resolve the benchmark directory from an ID.
# Args: $1 = benchmark ID
# Requires: EVALS_DIR, REGISTRY
resolve_benchmark_dir() {
    local id="$1"
    local category
    category=$(jq -r --arg id "${id}" '.benchmarks[] | select(.id == $id) | .category' "${REGISTRY}")
    if [[ -z "${category}" ]]; then
        echo "Error: benchmark '${id}' not found in registry" >&2
        return 1
    fi
    echo "${EVALS_DIR}/benchmarks/${category}/${id}"
}

# Generic match check for findings and traps.
# A match requires: same file path, overlapping line range (within $margin),
# and at least one keyword present in the description.
# Args: $1 = parsed finding (JSON), $2 = expected entry (JSON),
#        $3 = line margin, $4 = jq keyword field expression (e.g. '.keywords[]')
# Returns: 0 if match, 1 if no match
check_match() {
    local parsed="$1"
    local expected="$2"
    local margin="$3"
    local keyword_field="$4"

    local parsed_file parsed_line
    parsed_file=$(echo "${parsed}" | jq -r '.file')
    parsed_line=$(echo "${parsed}" | jq -r '.line')

    local expected_file expected_start expected_end
    expected_file=$(echo "${expected}" | jq -r '.file')
    expected_start=$(echo "${expected}" | jq -r '.line_start')
    expected_end=$(echo "${expected}" | jq -r '.line_end')

    # File must match (allow partial path match), or skip if parsed file is empty
    if [[ -n "${parsed_file}" ]]; then
        if [[ "${parsed_file}" != *"${expected_file}"* ]] && [[ "${expected_file}" != *"${parsed_file}"* ]]; then
            return 1
        fi
    fi

    # Line must be within a generous range (within margin lines of the expected range).
    # Skip line check when parsed line is 0 (unknown) or expected range is null.
    if [[ "${parsed_line}" != "0" ]] && [[ "${expected_start}" != "null" ]] && [[ "${expected_end}" != "null" ]]; then
        if ((parsed_line < expected_start - margin || parsed_line > expected_end + margin)); then
            return 1
        fi
    fi

    # At least one keyword must appear in the description (case-insensitive)
    local desc
    desc=$(echo "${parsed}" | jq -r '.description' | tr '[:upper:]' '[:lower:]')

    local keyword_found=false
    while IFS= read -r kw; do
        kw_lower=$(echo "${kw}" | tr '[:upper:]' '[:lower:]')
        if [[ "${desc}" == *"${kw_lower}"* ]]; then
            keyword_found=true
            break
        fi
    done < <(echo "${expected}" | jq -r "${keyword_field}")

    if [[ "${keyword_found}" != "true" ]]; then
        return 1
    fi

    return 0
}

# Check if a parsed finding matches an expected finding from the answer key.
# Args: $1 = parsed finding (JSON), $2 = expected finding (JSON)
# Returns: 0 if match, 1 if no match
check_finding_match() {
    check_match "$1" "$2" 10 '.keywords[]'
}

# Check if a parsed finding triggers a false-positive trap.
# Args: $1 = parsed finding (JSON), $2 = trap (JSON)
# Returns: 0 if trap triggered, 1 if not
check_trap_match() {
    check_match "$1" "$2" 5 '.trap_keywords[]'
}
