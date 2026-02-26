#!/usr/bin/env bash
# run-eval.sh - Run review-code benchmarks through Claude
#
# Usage:
#   run-eval.sh --benchmark <id>     Run a single benchmark
#   run-eval.sh --all                Run all benchmarks
#   run-eval.sh --category <cat>     Run all benchmarks in a category
#
# Each benchmark is applied as a patch to a temporary branch, reviewed
# via `claude -p`, and the resulting review is saved to evals/results/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVALS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${EVALS_DIR}/.." && pwd)"
REGISTRY="${EVALS_DIR}/benchmarks/registry.json"
RESULTS_DIR="${EVALS_DIR}/results"
SKILL_REVIEWS_DIR="${HOME}/.claude/skills/review-code/reviews"

# Generate a unique run ID from timestamp + short git SHA
generate_run_id() {
    local timestamp sha
    timestamp=$(date +%Y%m%d-%H%M%S)
    sha=$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2> /dev/null || echo "unknown")
    echo "${timestamp}-${sha}"
}

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

# List benchmark IDs, optionally filtered by category
list_benchmarks() {
    local category="${1:-}"
    if [[ -n "${category}" ]]; then
        jq -r --arg cat "${category}" '.benchmarks[] | select(.category == $cat) | .id' "${REGISTRY}"
    else
        jq -r '.benchmarks[].id' "${REGISTRY}"
    fi
}

# Run a single benchmark and save the review output
# Args: $1 = benchmark ID, $2 = run ID
run_benchmark() {
    local id="$1"
    local run_id="$2"

    local bench_dir
    bench_dir=$(resolve_benchmark_dir "${id}") || return 1

    local patch="${bench_dir}/diff.patch"
    if [[ ! -f "${patch}" ]]; then
        echo "Error: patch not found at ${patch}" >&2
        return 1
    fi

    local result_dir="${RESULTS_DIR}/${run_id}/${id}"
    mkdir -p "${result_dir}"

    local tmp_branch="eval-tmp-${id}"
    local original_branch
    original_branch=$(git -C "${REPO_ROOT}" branch --show-current 2> /dev/null || echo "HEAD")

    echo "  Applying patch to ${tmp_branch}…"

    # Create a temporary branch from HEAD, apply the patch, and commit
    git -C "${REPO_ROOT}" checkout -b "${tmp_branch}" --quiet 2> /dev/null || {
        # Branch may already exist from a previous failed run; clean it up
        git -C "${REPO_ROOT}" branch -D "${tmp_branch}" --quiet 2> /dev/null || true
        git -C "${REPO_ROOT}" checkout -b "${tmp_branch}" --quiet
    }

    # Apply base.patch first if it exists (creates files needed by diff.patch)
    local base_patch="${bench_dir}/base.patch"
    if [[ -f "${base_patch}" ]]; then
        echo "  Applying base patch…"
        git -C "${REPO_ROOT}" apply "${base_patch}" || {
            echo "  Error: failed to apply base patch for ${id}" >&2
            git -C "${REPO_ROOT}" checkout "${original_branch}" --quiet
            git -C "${REPO_ROOT}" branch -D "${tmp_branch}" --quiet 2> /dev/null || true
            return 1
        }
        git -C "${REPO_ROOT}" add -A
        git -C "${REPO_ROOT}" commit -m "eval: base state for ${id}" --quiet --no-gpg-sign
    fi

    if ! git -C "${REPO_ROOT}" apply --check "${patch}" 2> /dev/null; then
        echo "  Warning: patch does not apply cleanly, attempting forced apply" >&2
        git -C "${REPO_ROOT}" apply "${patch}" --allow-empty 2> /dev/null || {
            echo "  Error: failed to apply patch for ${id}" >&2
            git -C "${REPO_ROOT}" checkout "${original_branch}" --quiet
            git -C "${REPO_ROOT}" branch -D "${tmp_branch}" --quiet 2> /dev/null || true
            return 1
        }
    else
        git -C "${REPO_ROOT}" apply "${patch}"
    fi

    git -C "${REPO_ROOT}" add -A
    git -C "${REPO_ROOT}" commit -m "eval: apply benchmark ${id}" --quiet --no-gpg-sign

    echo "  Running review on ${tmp_branch}…"

    # Determine the org/repo for locating the review output
    local org repo
    org=$(git -C "${REPO_ROOT}" remote get-url origin 2> /dev/null | sed -E 's#.*[:/]([^/]+)/([^/]+?)(\.git)?$#\1#' || echo "unknown")
    repo=$(git -C "${REPO_ROOT}" remote get-url origin 2> /dev/null | sed -E 's#.*[:/]([^/]+)/([^/]+?)(\.git)?$#\2#' || echo "unknown")

    # Run the review via claude -p
    local claude_exit=0
    claude -p "/review-code ${tmp_branch} --force" \
        --dangerously-skip-permissions \
        --max-budget-usd 5 \
        > "${result_dir}/claude-output.txt" 2>&1 || claude_exit=$?

    if [[ ${claude_exit} -ne 0 ]]; then
        echo "  Warning: claude exited with code ${claude_exit}" >&2
    fi

    # Locate the review file and copy it to results
    local review_file="${SKILL_REVIEWS_DIR}/${org}/${repo}/branch-${tmp_branch}.md"
    if [[ -f "${review_file}" ]]; then
        cp "${review_file}" "${result_dir}/review.md"
        echo "  Review saved to ${result_dir}/review.md"
    else
        echo "  Warning: review file not found at ${review_file}" >&2
        echo "  Checking for any review matching this branch…" >&2
        # Fallback: search for any file matching the branch name
        local found
        found=$(find "${SKILL_REVIEWS_DIR}" -name "*${tmp_branch}*" -type f 2> /dev/null | head -1)
        if [[ -n "${found}" ]]; then
            cp "${found}" "${result_dir}/review.md"
            echo "  Found review at ${found}"
        else
            echo "  No review output found" >&2
        fi
    fi

    # Clean up: switch back and delete the temporary branch
    echo "  Cleaning up ${tmp_branch}…"
    git -C "${REPO_ROOT}" checkout "${original_branch}" --quiet
    git -C "${REPO_ROOT}" branch -D "${tmp_branch}" --quiet 2> /dev/null || true

    echo "  Done with ${id}"
}

# Write a run manifest with metadata
write_manifest() {
    local run_id="$1"
    shift
    local benchmarks=("$@")

    local manifest="${RESULTS_DIR}/${run_id}/manifest.json"
    local sha model timestamp
    sha=$(git -C "${REPO_ROOT}" rev-parse HEAD 2> /dev/null || echo "unknown")
    model=$(claude --version 2> /dev/null || echo "unknown")
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local benchmark_json="[]"
    for b in "${benchmarks[@]}"; do
        benchmark_json=$(echo "${benchmark_json}" | jq --arg id "${b}" '. + [$id]')
    done

    jq -n \
        --arg run_id "${run_id}" \
        --arg sha "${sha}" \
        --arg model "${model}" \
        --arg timestamp "${timestamp}" \
        --argjson benchmarks "${benchmark_json}" \
        '{
            run_id: $run_id,
            git_sha: $sha,
            model: $model,
            timestamp: $timestamp,
            benchmarks: $benchmarks
        }' > "${manifest}"
}

main() {
    local mode="" target=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --benchmark)
                mode="single"
                target="${2:?--benchmark requires an ID}"
                shift 2
                ;;
            --all)
                mode="all"
                shift
                ;;
            --category)
                mode="category"
                target="${2:?--category requires a name}"
                shift 2
                ;;
            -h | --help)
                echo "Usage: run-eval.sh --benchmark <id> | --all | --category <cat>"
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                exit 1
                ;;
        esac
    done

    if [[ -z "${mode}" ]]; then
        echo "Usage: run-eval.sh --benchmark <id> | --all | --category <cat>" >&2
        exit 1
    fi

    # Validate prerequisites
    if ! command -v claude > /dev/null 2>&1; then
        echo "Error: claude CLI not found" >&2
        exit 1
    fi

    if ! command -v jq > /dev/null 2>&1; then
        echo "Error: jq not found" >&2
        exit 1
    fi

    if [[ ! -f "${REGISTRY}" ]]; then
        echo "Error: registry not found at ${REGISTRY}" >&2
        exit 1
    fi

    # Collect benchmark IDs to run
    local benchmarks=()
    case "${mode}" in
        single)
            benchmarks=("${target}")
            ;;
        all)
            while IFS= read -r id; do
                benchmarks+=("${id}")
            done < <(list_benchmarks)
            ;;
        category)
            while IFS= read -r id; do
                benchmarks+=("${id}")
            done < <(list_benchmarks "${target}")
            ;;
    esac

    if [[ ${#benchmarks[@]} -eq 0 ]]; then
        echo "No benchmarks found" >&2
        exit 1
    fi

    local run_id
    run_id=$(generate_run_id)

    echo "Starting eval run: ${run_id}"
    echo "Benchmarks: ${benchmarks[*]}"
    echo ""

    local failed=0
    for id in "${benchmarks[@]}"; do
        echo "Running benchmark: ${id}"
        if ! run_benchmark "${id}" "${run_id}"; then
            echo "  FAILED: ${id}" >&2
            ((failed++))
        fi
        echo ""
    done

    write_manifest "${run_id}" "${benchmarks[@]}"

    echo "Run complete: ${run_id}"
    echo "Results: ${RESULTS_DIR}/${run_id}/"
    if [[ ${failed} -gt 0 ]]; then
        echo "${failed} benchmark(s) failed" >&2
        exit 1
    fi
}

main "$@"
