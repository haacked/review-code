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

source "${SCRIPT_DIR}/helpers/eval-helpers.sh"

# Tier 1: Automated pattern matching
# Args: $1 = review file path, $2 = answer key path
# Outputs: JSON score object on stdout
score_pattern_matching() {
    local review_file="$1"
    local answer_key="$2"

    # Parse findings from the review
    local parsed_findings
    parsed_findings=$("${PARSE_FINDINGS}" "${review_file}" 2> /dev/null || echo "[]")

    # Pre-extract arrays as JSONL (one jq call each instead of per-iteration indexing)
    local parsed_jsonl expected_jsonl traps_jsonl clean_areas_jsonl
    parsed_jsonl=$(echo "${parsed_findings}" | jq -c '.[]' 2> /dev/null || true)
    expected_jsonl=$(jq -c '.expected_findings[]' "${answer_key}" 2> /dev/null || true)
    traps_jsonl=$(jq -c '.false_positive_traps[]' "${answer_key}" 2> /dev/null || true)
    clean_areas_jsonl=$(jq -r '.clean_areas[]' "${answer_key}" 2> /dev/null || true)

    # Match expected findings against parsed findings
    local caught_ids="" missed_ids=""
    local total_weight=0
    local caught_weight=0

    while IFS= read -r expected; do
        [[ -z "${expected}" ]] && continue
        local eid weight
        eid=$(echo "${expected}" | jq -r '.id')
        weight=$(echo "${expected}" | jq -r '.weight // 1')
        total_weight=$((total_weight + weight))

        local found=false
        while IFS= read -r parsed; do
            [[ -z "${parsed}" ]] && continue
            if check_finding_match "${parsed}" "${expected}"; then
                found=true
                break
            fi
        done <<< "${parsed_jsonl}"

        if [[ "${found}" == "true" ]]; then
            caught_ids+="\"${eid}\","
            caught_weight=$((caught_weight + weight))
        else
            missed_ids+="\"${eid}\","
        fi
    done <<< "${expected_jsonl}"

    # Build JSON arrays from accumulated IDs
    local caught="[${caught_ids%,}]"
    local missed="[${missed_ids%,}]"

    # Calculate weighted recall
    local recall_weighted="0"
    if [[ ${total_weight} -gt 0 ]]; then
        recall_weighted=$(echo "scale=2; ${caught_weight} / ${total_weight}" | bc)
    fi

    # Check for false-positive traps
    local traps_triggered_ids=""
    local true_positives=0
    local false_positives=0

    while IFS= read -r parsed; do
        [[ -z "${parsed}" ]] && continue

        # Check if this finding matches any expected finding
        local matches_expected=false
        while IFS= read -r expected; do
            [[ -z "${expected}" ]] && continue
            if check_finding_match "${parsed}" "${expected}"; then
                matches_expected=true
                break
            fi
        done <<< "${expected_jsonl}"

        if [[ "${matches_expected}" == "true" ]]; then
            true_positives=$((true_positives + 1))
            continue
        fi

        # Check if it triggers a trap
        local triggers_trap=false
        while IFS= read -r trap_entry; do
            [[ -z "${trap_entry}" ]] && continue
            if check_trap_match "${parsed}" "${trap_entry}"; then
                local tid
                tid=$(echo "${trap_entry}" | jq -r '.id')
                traps_triggered_ids+="\"${tid}\","
                triggers_trap=true
                break
            fi
        done <<< "${traps_jsonl}"

        if [[ "${triggers_trap}" == "true" ]]; then
            false_positives=$((false_positives + 1))
        fi
        # Unmatched findings that aren't traps are neutral (may be valid extras)
    done <<< "${parsed_jsonl}"

    local traps_triggered="[${traps_triggered_ids%,}]"

    # Precision ratio
    local total_flagged=$((true_positives + false_positives))
    local precision="1.0"
    if [[ ${total_flagged} -gt 0 ]]; then
        precision=$(echo "scale=2; ${true_positives} / ${total_flagged}" | bc)
    fi

    # Check clean area violations
    local clean_violations=0
    while IFS= read -r parsed; do
        [[ -z "${parsed}" ]] && continue
        local agent
        agent=$(echo "${parsed}" | jq -r '.agent')
        while IFS= read -r area; do
            [[ -z "${area}" ]] && continue
            if [[ "${agent}" == "${area}" ]]; then
                clean_violations=$((clean_violations + 1))
            fi
        done <<< "${clean_areas_jsonl}"
    done <<< "${parsed_jsonl}"

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
    # Validate prerequisites
    for cmd in jq bc; do
        if ! command -v "${cmd}" > /dev/null 2>&1; then
            echo "Error: ${cmd} not found" >&2
            exit 1
        fi
    done

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
