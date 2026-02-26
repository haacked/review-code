#!/usr/bin/env bash
# score-eval.sh - Score eval results against answer keys
#
# Usage:
#   score-eval.sh <run-id>                 Score all benchmarks in a run
#   score-eval.sh <run-id> <benchmark-id>  Score a specific benchmark
#   score-eval.sh <run-id> --no-llm        Skip LLM judge (pattern matching only)
#
# Compares review output to answer keys using two tiers:
# 1. Automated pattern matching (recall, precision, severity accuracy)
# 2. LLM-as-judge scoring (actionability, specificity, signal-to-noise)
#
# Outputs per-benchmark score JSON and appends to evals/history/scores.jsonl.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVALS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${EVALS_DIR}/.." && pwd)"
REGISTRY="${EVALS_DIR}/benchmarks/registry.json"
RESULTS_DIR="${EVALS_DIR}/results"
HISTORY_FILE="${EVALS_DIR}/history/scores.jsonl"
PARSE_FINDINGS="${REPO_ROOT}/skills/review-code/scripts/parse-review-findings.sh"

# Resolve the benchmark directory from an ID
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

# Check if a finding matches an expected finding from the answer key.
# A match requires: same file path, overlapping line range, and at least one
# keyword present in the description.
# Args: $1 = parsed finding (JSON), $2 = expected finding (JSON)
# Returns: 0 if match, 1 if no match
check_finding_match() {
    local parsed="$1"
    local expected="$2"

    local parsed_file parsed_line
    parsed_file=$(echo "${parsed}" | jq -r '.file')
    parsed_line=$(echo "${parsed}" | jq -r '.line')

    local expected_file expected_start expected_end
    expected_file=$(echo "${expected}" | jq -r '.file')
    expected_start=$(echo "${expected}" | jq -r '.line_start')
    expected_end=$(echo "${expected}" | jq -r '.line_end')

    # File must match (allow partial path match)
    if [[ "${parsed_file}" != *"${expected_file}"* ]] && [[ "${expected_file}" != *"${parsed_file}"* ]]; then
        return 1
    fi

    # Line must be within a generous range (within 10 lines of the expected range)
    local margin=10
    if ((parsed_line < expected_start - margin || parsed_line > expected_end + margin)); then
        return 1
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
    done < <(echo "${expected}" | jq -r '.keywords[]')

    if [[ "${keyword_found}" != "true" ]]; then
        return 1
    fi

    return 0
}

# Check if a parsed finding triggers a false-positive trap.
# Args: $1 = parsed finding (JSON), $2 = trap (JSON)
# Returns: 0 if trap triggered, 1 if not
check_trap_match() {
    local parsed="$1"
    local trap="$2"

    local parsed_file parsed_line
    parsed_file=$(echo "${parsed}" | jq -r '.file')
    parsed_line=$(echo "${parsed}" | jq -r '.line')

    local trap_file trap_start trap_end
    trap_file=$(echo "${trap}" | jq -r '.file')
    trap_start=$(echo "${trap}" | jq -r '.line_start')
    trap_end=$(echo "${trap}" | jq -r '.line_end')

    # File must match
    if [[ "${parsed_file}" != *"${trap_file}"* ]] && [[ "${trap_file}" != *"${parsed_file}"* ]]; then
        return 1
    fi

    # Line must be within the trap range (tight margin)
    local margin=5
    if ((parsed_line < trap_start - margin || parsed_line > trap_end + margin)); then
        return 1
    fi

    # Check trap keywords in description
    local desc
    desc=$(echo "${parsed}" | jq -r '.description' | tr '[:upper:]' '[:lower:]')

    local keyword_found=false
    while IFS= read -r kw; do
        kw_lower=$(echo "${kw}" | tr '[:upper:]' '[:lower:]')
        if [[ "${desc}" == *"${kw_lower}"* ]]; then
            keyword_found=true
            break
        fi
    done < <(echo "${trap}" | jq -r '.trap_keywords[]')

    if [[ "${keyword_found}" == "true" ]]; then
        return 0
    fi
    return 1
}

# Tier 1: Automated pattern matching
# Args: $1 = review file path, $2 = answer key path
# Outputs: JSON score object on stdout
score_pattern_matching() {
    local review_file="$1"
    local answer_key="$2"

    # Parse findings from the review
    local parsed_findings
    parsed_findings=$("${PARSE_FINDINGS}" "${review_file}" 2> /dev/null || echo "[]")

    local parsed_count
    parsed_count=$(echo "${parsed_findings}" | jq 'length')

    # Load answer key
    local expected_findings traps clean_areas
    expected_findings=$(jq '.expected_findings' "${answer_key}")
    traps=$(jq '.false_positive_traps' "${answer_key}")
    clean_areas=$(jq '.clean_areas' "${answer_key}")

    local expected_count
    expected_count=$(echo "${expected_findings}" | jq 'length')

    # Match expected findings against parsed findings
    local caught="[]"
    local missed="[]"
    local total_weight=0
    local caught_weight=0

    for i in $(seq 0 $((expected_count - 1))); do
        local expected
        expected=$(echo "${expected_findings}" | jq ".[$i]")
        local eid weight
        eid=$(echo "${expected}" | jq -r '.id')
        weight=$(echo "${expected}" | jq -r '.weight')
        total_weight=$((total_weight + weight))

        local found=false
        for j in $(seq 0 $((parsed_count - 1))); do
            local parsed
            parsed=$(echo "${parsed_findings}" | jq ".[$j]")
            if check_finding_match "${parsed}" "${expected}"; then
                found=true
                break
            fi
        done

        if [[ "${found}" == "true" ]]; then
            caught=$(echo "${caught}" | jq --arg id "${eid}" '. + [$id]')
            caught_weight=$((caught_weight + weight))
        else
            missed=$(echo "${missed}" | jq --arg id "${eid}" '. + [$id]')
        fi
    done

    # Calculate weighted recall
    local recall_weighted="0"
    if [[ ${total_weight} -gt 0 ]]; then
        recall_weighted=$(echo "scale=2; ${caught_weight} / ${total_weight}" | bc)
    fi

    # Check for false-positive traps
    local traps_triggered="[]"
    local trap_count
    trap_count=$(echo "${traps}" | jq 'length')

    local true_positives=0
    local false_positives=0

    for j in $(seq 0 $((parsed_count - 1))); do
        local parsed
        parsed=$(echo "${parsed_findings}" | jq ".[$j]")

        # Check if this finding matches any expected finding
        local matches_expected=false
        for i in $(seq 0 $((expected_count - 1))); do
            local expected
            expected=$(echo "${expected_findings}" | jq ".[$i]")
            if check_finding_match "${parsed}" "${expected}"; then
                matches_expected=true
                break
            fi
        done

        if [[ "${matches_expected}" == "true" ]]; then
            true_positives=$((true_positives + 1))
            continue
        fi

        # Check if it triggers a trap
        local triggers_trap=false
        for k in $(seq 0 $((trap_count - 1))); do
            local trap
            trap=$(echo "${traps}" | jq ".[$k]")
            if check_trap_match "${parsed}" "${trap}"; then
                local tid
                tid=$(echo "${trap}" | jq -r '.id')
                traps_triggered=$(echo "${traps_triggered}" | jq --arg id "${tid}" '. + [$id]')
                triggers_trap=true
                break
            fi
        done

        if [[ "${triggers_trap}" == "true" ]]; then
            false_positives=$((false_positives + 1))
        fi
        # Unmatched findings that aren't traps are neutral (may be valid extras)
    done

    # Precision ratio
    local total_flagged=$((true_positives + false_positives))
    local precision="1.0"
    if [[ ${total_flagged} -gt 0 ]]; then
        precision=$(echo "scale=2; ${true_positives} / ${total_flagged}" | bc)
    fi

    # Check clean area violations
    local clean_violations=0
    local clean_count
    clean_count=$(echo "${clean_areas}" | jq 'length')
    for j in $(seq 0 $((parsed_count - 1))); do
        local agent
        agent=$(echo "${parsed_findings}" | jq -r ".[$j].agent")
        for c in $(seq 0 $((clean_count - 1))); do
            local area
            area=$(echo "${clean_areas}" | jq -r ".[$c]")
            if [[ "${agent}" == "${area}" ]]; then
                clean_violations=$((clean_violations + 1))
            fi
        done
    done

    # Output score JSON
    jq -n \
        --arg recall "${recall_weighted}" \
        --argjson caught "${caught}" \
        --argjson missed "${missed}" \
        --arg tp "${true_positives}" \
        --arg fp "${false_positives}" \
        --argjson traps "${traps_triggered}" \
        --arg precision "${precision}" \
        --arg violations "${clean_violations}" \
        '{
            recall: {
                weighted: ($recall | tonumber),
                findings_caught: $caught,
                findings_missed: $missed
            },
            precision: {
                true_positives: ($tp | tonumber),
                false_positives: ($fp | tonumber),
                traps_triggered: $traps,
                ratio: ($precision | tonumber)
            },
            clean_area_violations: ($violations | tonumber)
        }'
}

# Tier 2: LLM-as-judge scoring
# Args: $1 = review file path, $2 = answer key path
# Outputs: JSON score object on stdout
score_llm_judge() {
    local review_file="$1"
    local answer_key="$2"

    local review_content answer_content
    review_content=$(cat "${review_file}")
    answer_content=$(cat "${answer_key}")

    local judge_schema='{
        "type": "object",
        "properties": {
            "actionability": {"type": "integer", "minimum": 1, "maximum": 5},
            "specificity": {"type": "integer", "minimum": 1, "maximum": 5},
            "signal_to_noise": {"type": "integer", "minimum": 1, "maximum": 5},
            "overall_quality": {"type": "integer", "minimum": 1, "maximum": 5},
            "notes": {"type": "string"}
        },
        "required": ["actionability", "specificity", "signal_to_noise", "overall_quality", "notes"]
    }'

    local prompt
    prompt=$(
        cat << PROMPT
You are an expert code review evaluator. Score this code review on four dimensions.

## The Review Being Evaluated

${review_content}

## Answer Key (Expected Findings)

${answer_content}

## Scoring Criteria

Rate each dimension from 1 (poor) to 5 (excellent):

- **actionability**: Are findings specific enough to act on? Do they tell the developer exactly what to fix and how?
- **specificity**: Do findings reference exact code locations, quote specific lines, and identify precise issues? Or are they vague generalities?
- **signal_to_noise**: What is the ratio of valuable, real findings to filler, noise, or false positives? High signal = mostly real issues.
- **overall_quality**: Overall quality of the review as a professional code review.

Also provide brief notes explaining your scoring rationale.
PROMPT
    )

    local judge_result
    judge_result=$(claude -p "${prompt}" \
        --output-format json \
        --max-budget-usd 0.50 \
        2> /dev/null || echo '{"actionability":0,"specificity":0,"signal_to_noise":0,"overall_quality":0,"notes":"LLM judge failed"}')

    # Extract just the fields we need (claude output may have wrapper)
    echo "${judge_result}" | jq '{
        actionability: (.actionability // 0),
        specificity: (.specificity // 0),
        signal_to_noise: (.signal_to_noise // 0),
        overall_quality: (.overall_quality // 0),
        notes: (.notes // "")
    }'
}

# Compute composite score from pattern matching and LLM judge results
# Args: $1 = pattern matching JSON, $2 = LLM judge JSON
# Outputs: composite score (float) on stdout
compute_composite() {
    local pattern="$1"
    local llm="$2"

    local recall precision overall
    recall=$(echo "${pattern}" | jq -r '.recall.weighted')
    precision=$(echo "${pattern}" | jq -r '.precision.ratio')
    overall=$(echo "${llm}" | jq -r '.overall_quality')

    # Composite: 0.4 * recall + 0.2 * precision + 0.15 * severity_accuracy + 0.25 * (llm_overall / 5)
    # We skip severity_accuracy for now (not yet tracked) and redistribute its weight
    # Adjusted: 0.45 * recall + 0.25 * precision + 0.30 * (llm_overall / 5)
    echo "scale=2; 0.45 * ${recall} + 0.25 * ${precision} + 0.30 * (${overall} / 5)" | bc
}

# Score a single benchmark
# Args: $1 = run ID, $2 = benchmark ID, $3 = skip LLM (true/false)
score_benchmark() {
    local run_id="$1"
    local benchmark_id="$2"
    local skip_llm="${3:-false}"

    local result_dir="${RESULTS_DIR}/${run_id}/${benchmark_id}"
    local review_file="${result_dir}/review.md"

    if [[ ! -f "${review_file}" ]]; then
        echo "Error: review file not found at ${review_file}" >&2
        return 1
    fi

    # Resolve answer key
    local bench_dir
    bench_dir=$(resolve_benchmark_dir "${benchmark_id}") || return 1
    local answer_key="${bench_dir}/answer-key.json"

    if [[ ! -f "${answer_key}" ]]; then
        echo "Error: answer key not found at ${answer_key}" >&2
        return 1
    fi

    echo "  Scoring pattern matching…"
    local pattern_score
    pattern_score=$(score_pattern_matching "${review_file}" "${answer_key}")

    local llm_score='{"actionability":0,"specificity":0,"signal_to_noise":0,"overall_quality":0,"notes":"skipped"}'
    if [[ "${skip_llm}" != "true" ]]; then
        echo "  Running LLM judge…"
        llm_score=$(score_llm_judge "${review_file}" "${answer_key}")
    fi

    local composite
    composite=$(compute_composite "${pattern_score}" "${llm_score}")

    # Get run metadata
    local manifest="${RESULTS_DIR}/${run_id}/manifest.json"
    local git_sha timestamp
    git_sha=$(jq -r '.git_sha' "${manifest}" 2> /dev/null || echo "unknown")
    timestamp=$(jq -r '.timestamp' "${manifest}" 2> /dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)

    # Build final score
    local score
    score=$(jq -n \
        --arg run_id "${run_id}" \
        --arg benchmark_id "${benchmark_id}" \
        --arg git_sha "${git_sha}" \
        --arg timestamp "${timestamp}" \
        --argjson pattern "${pattern_score}" \
        --argjson llm "${llm_score}" \
        --arg composite "${composite}" \
        '{
            run_id: $run_id,
            benchmark_id: $benchmark_id,
            git_sha: $git_sha,
            timestamp: $timestamp,
            pattern_matching: $pattern,
            llm_judge: $llm,
            composite_score: ($composite | tonumber)
        }')

    # Save individual score
    echo "${score}" | jq '.' > "${result_dir}/score.json"

    # Append to history
    echo "${score}" | jq -c '.' >> "${HISTORY_FILE}"

    echo "  Composite score: ${composite}"
    echo "${score}"
}

main() {
    local run_id="" benchmark_id="" skip_llm=false

    # Parse arguments
    local positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-llm)
                skip_llm=true
                shift
                ;;
            -h | --help)
                echo "Usage: score-eval.sh <run-id> [benchmark-id] [--no-llm]"
                exit 0
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    if [[ ${#positional[@]} -lt 1 ]]; then
        echo "Usage: score-eval.sh <run-id> [benchmark-id] [--no-llm]" >&2
        exit 1
    fi

    run_id="${positional[0]}"
    benchmark_id="${positional[1]:-}"

    local run_dir="${RESULTS_DIR}/${run_id}"
    if [[ ! -d "${run_dir}" ]]; then
        echo "Error: run directory not found: ${run_dir}" >&2
        exit 1
    fi

    # Collect benchmarks to score
    local benchmarks=()
    if [[ -n "${benchmark_id}" ]]; then
        benchmarks=("${benchmark_id}")
    else
        # Score all benchmarks in the run
        while IFS= read -r dir; do
            local name
            name=$(basename "${dir}")
            if [[ "${name}" != "manifest.json" ]] && [[ -d "${dir}" ]]; then
                benchmarks+=("${name}")
            fi
        done < <(find "${run_dir}" -mindepth 1 -maxdepth 1 -not -name "manifest.json")
    fi

    if [[ ${#benchmarks[@]} -eq 0 ]]; then
        echo "No benchmarks found in run ${run_id}" >&2
        exit 1
    fi

    echo "Scoring run: ${run_id}"
    echo ""

    local total_composite=0
    local count=0

    for id in "${benchmarks[@]}"; do
        echo "Scoring: ${id}"
        if score_benchmark "${run_id}" "${id}" "${skip_llm}"; then
            local score
            score=$(jq -r '.composite_score' "${RESULTS_DIR}/${run_id}/${id}/score.json")
            total_composite=$(echo "${total_composite} + ${score}" | bc)
            count=$((count + 1))
        fi
        echo ""
    done

    if [[ ${count} -gt 0 ]]; then
        local avg
        avg=$(echo "scale=2; ${total_composite} / ${count}" | bc)
        echo "Average composite score: ${avg}"
    fi

    echo "Scores appended to: ${HISTORY_FILE}"
}

main "$@"
