#!/usr/bin/env bash
# report.sh - Display eval score trends from history
#
# Usage:
#   report.sh                          Show all scores
#   report.sh --last <N>               Show last N runs
#   report.sh --compare <sha1> <sha2>  Compare two git SHAs
#   report.sh --benchmark <id>         Filter by benchmark

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVALS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HISTORY_FILE="${EVALS_DIR}/history/scores.jsonl"

# ANSI colors
BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Format a score with color: green >= 0.7, yellow >= 0.4, red < 0.4
color_score() {
    local score="$1"
    if (($(echo "${score} >= 0.7" | bc -l))); then
        echo -e "${GREEN}${score}${NC}"
    elif (($(echo "${score} >= 0.4" | bc -l))); then
        echo -e "${YELLOW}${score}${NC}"
    else
        echo -e "${RED}${score}${NC}"
    fi
}

# Show a table of scores
# Args: stdin = JSONL lines to display
show_table() {
    # Print header
    printf "${BOLD}%-22s %-20s %-10s %-8s %-8s %-8s %-10s${NC}\n" \
        "Run" "Benchmark" "SHA" "Recall" "Precis." "LLM" "Composite"
    printf "%-22s %-20s %-10s %-8s %-8s %-8s %-10s\n" \
        "$(printf '─%.0s' {1..22})" \
        "$(printf '─%.0s' {1..20})" \
        "$(printf '─%.0s' {1..10})" \
        "$(printf '─%.0s' {1..8})" \
        "$(printf '─%.0s' {1..8})" \
        "$(printf '─%.0s' {1..8})" \
        "$(printf '─%.0s' {1..10})"

    while IFS= read -r line; do
        local run_id benchmark sha recall precision llm composite
        run_id=$(echo "${line}" | jq -r '.run_id')
        benchmark=$(echo "${line}" | jq -r '.benchmark_id')
        sha=$(echo "${line}" | jq -r '.git_sha' | head -c 8)
        recall=$(echo "${line}" | jq -r '.pattern_matching.recall.weighted')
        precision=$(echo "${line}" | jq -r '.pattern_matching.precision.ratio')
        llm=$(echo "${line}" | jq -r '.llm_judge.overall_quality')
        composite=$(echo "${line}" | jq -r '.composite_score')

        # Truncate long fields
        run_id="${run_id:0:22}"
        benchmark="${benchmark:0:20}"

        printf "%-22s %-20s %-10s %-8s %-8s %-8s " \
            "${run_id}" "${benchmark}" "${sha}" "${recall}" "${precision}" "${llm}"
        color_score "${composite}"
    done
}

# Show aggregate stats for a set of scores
# Args: stdin = JSONL lines
show_aggregate() {
    local lines
    lines=$(cat)

    if [[ -z "${lines}" ]]; then
        echo "No scores found."
        return
    fi

    local count
    count=$(echo "${lines}" | wc -l | tr -d ' ')

    local total_composite=0
    local total_recall=0
    local total_precision=0

    while IFS= read -r line; do
        local c r p
        c=$(echo "${line}" | jq -r '.composite_score')
        r=$(echo "${line}" | jq -r '.pattern_matching.recall.weighted')
        p=$(echo "${line}" | jq -r '.pattern_matching.precision.ratio')
        total_composite=$(echo "${total_composite} + ${c}" | bc)
        total_recall=$(echo "${total_recall} + ${r}" | bc)
        total_precision=$(echo "${total_precision} + ${p}" | bc)
    done <<< "${lines}"

    local avg_composite avg_recall avg_precision
    avg_composite=$(echo "scale=2; ${total_composite} / ${count}" | bc)
    avg_recall=$(echo "scale=2; ${total_recall} / ${count}" | bc)
    avg_precision=$(echo "scale=2; ${total_precision} / ${count}" | bc)

    echo ""
    echo -e "${BOLD}Aggregate (${count} scores):${NC}"
    printf "  Avg Recall:    %s\n" "${avg_recall}"
    printf "  Avg Precision: %s\n" "${avg_precision}"
    printf "  Avg Composite: "
    color_score "${avg_composite}"
}

# Compare two git SHAs
compare_shas() {
    local sha1="$1"
    local sha2="$2"

    echo -e "${BOLD}Comparing ${CYAN}${sha1:0:8}${NC}${BOLD} vs ${CYAN}${sha2:0:8}${NC}"
    echo ""

    echo -e "${BOLD}SHA: ${sha1:0:8}${NC}"
    grep "\"git_sha\":\"${sha1}" "${HISTORY_FILE}" 2> /dev/null | show_table

    local lines1
    lines1=$(grep "\"git_sha\":\"${sha1}" "${HISTORY_FILE}" 2> /dev/null || true)
    if [[ -n "${lines1}" ]]; then
        echo "${lines1}" | show_aggregate
    fi

    echo ""
    echo -e "${BOLD}SHA: ${sha2:0:8}${NC}"
    grep "\"git_sha\":\"${sha2}" "${HISTORY_FILE}" 2> /dev/null | show_table

    local lines2
    lines2=$(grep "\"git_sha\":\"${sha2}" "${HISTORY_FILE}" 2> /dev/null || true)
    if [[ -n "${lines2}" ]]; then
        echo "${lines2}" | show_aggregate
    fi
}

main() {
    if [[ ! -f "${HISTORY_FILE}" ]]; then
        echo "No score history found at ${HISTORY_FILE}"
        echo "Run evaluations first with: evals/scripts/run-eval.sh --all"
        exit 0
    fi

    local mode="" last_n="" sha1="" sha2="" benchmark_filter=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --last)
                mode="last"
                last_n="${2:?--last requires a number}"
                shift 2
                ;;
            --compare)
                mode="compare"
                sha1="${2:?--compare requires two SHAs}"
                sha2="${3:?--compare requires two SHAs}"
                shift 3
                ;;
            --benchmark)
                benchmark_filter="${2:?--benchmark requires an ID}"
                shift 2
                ;;
            -h | --help)
                echo "Usage: report.sh [--last N] [--compare sha1 sha2] [--benchmark id]"
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                exit 1
                ;;
        esac
    done

    # Apply benchmark filter
    local history_data
    if [[ -n "${benchmark_filter}" ]]; then
        history_data=$(grep "\"benchmark_id\":\"${benchmark_filter}\"" "${HISTORY_FILE}" 2> /dev/null || true)
        if [[ -z "${history_data}" ]]; then
            echo "No scores found for benchmark: ${benchmark_filter}"
            exit 0
        fi
    else
        history_data=$(cat "${HISTORY_FILE}")
    fi

    case "${mode}" in
        "compare")
            compare_shas "${sha1}" "${sha2}"
            ;;
        "last")
            echo -e "${BOLD}Last ${last_n} scores:${NC}"
            echo ""
            local lines
            lines=$(echo "${history_data}" | tail -n "${last_n}")
            echo "${lines}" | show_table
            echo "${lines}" | show_aggregate
            ;;
        *)
            echo -e "${BOLD}All scores:${NC}"
            echo ""
            echo "${history_data}" | show_table
            echo "${history_data}" | show_aggregate
            ;;
    esac
}

main "$@"
