#!/usr/bin/env bash
# run-eval.sh - Run review-code benchmarks through Claude
#
# Usage:
#   run-eval.sh --benchmark <id>     Run a single benchmark
#   run-eval.sh --all                Run all benchmarks
#   run-eval.sh --category <cat>     Run all benchmarks in a category
#   run-eval.sh --sample             Run one random benchmark
#
# Options:
#   --approach <skill|baseline>      Review approach (default: skill)
#                                    skill = full /review-code skill
#                                    baseline = bare Claude prompt with diff
#                                    When omitted with --sample, runs both
#
# Crafted benchmarks: applies patch to a temporary branch, reviews via `claude -p`
# Real-world PR benchmarks: reviews via PR URL directly (no patch needed)
# Results are saved to evals/results/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVALS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${EVALS_DIR}/.." && pwd)"
REGISTRY="${EVALS_DIR}/benchmarks/registry.json"
RESULTS_DIR="${EVALS_DIR}/results"
SKILL_REVIEWS_DIR="${HOME}/.claude/skills/review-code/reviews"
BASELINE_PROMPT="${EVALS_DIR}/prompts/baseline.md"

source "${SCRIPT_DIR}/helpers/eval-helpers.sh"

# Generate a unique run ID from timestamp + short git SHA
generate_run_id() {
    local timestamp sha
    timestamp=$(date +%Y%m%d-%H%M%S)
    sha=$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2> /dev/null || echo "unknown")
    echo "${timestamp}-${sha}"
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

# Build the baseline prompt by reading the diff and inserting it into the template.
# For PR benchmarks, also includes PR title/description if available.
# Args: $1 = bench dir, $2 = diff content
# Outputs: prompt string on stdout
build_baseline_prompt() {
    local bench_dir="$1"
    local diff_content="$2"

    local template
    template=$(cat "${BASELINE_PROMPT}")

    # Replace the {diff_content} placeholder with an actual diff block
    local prompt="${template//\{diff_content\}/<diff>
${diff_content}
</diff>}"

    # For PR benchmarks, prepend title/description for context
    local pr_title pr_description
    pr_title=$(jq -r '.name // empty' "${bench_dir}/metadata.json" 2> /dev/null)
    pr_description=$(jq -r '.description // empty' "${bench_dir}/metadata.json" 2> /dev/null)

    if [[ -n "${pr_title}" ]] || [[ -n "${pr_description}" ]]; then
        local context=""
        [[ -n "${pr_title}" ]] && context+="PR Title: ${pr_title}"$'\n'
        [[ -n "${pr_description}" ]] && context+="PR Description: ${pr_description}"$'\n'
        prompt="${context}"$'\n'"${prompt}"
    fi

    echo "${prompt}"
}

# Run a baseline review: pass the diff directly to Claude with a bare prompt.
# Args: $1 = benchmark ID, $2 = bench dir, $3 = result dir, $4 = budget
run_baseline_benchmark() {
    local id="$1"
    local bench_dir="$2"
    local result_dir="$3"
    local budget="${4:-5}"

    local diff_content
    diff_content=$(read_benchmark_diff "${bench_dir}") || return 1

    local prompt
    prompt=$(build_baseline_prompt "${bench_dir}" "${diff_content}")

    echo "  Running baseline review (bare prompt)..."
    echo "  Budget: \$${budget}"

    local claude_exit=0
    env -u CLAUDECODE claude -p "${prompt}" \
        --dangerously-skip-permissions \
        --max-budget-usd "${budget}" \
        > "${result_dir}/claude-output.txt" 2>&1 || claude_exit=$?

    if [[ ${claude_exit} -ne 0 ]]; then
        echo "  Warning: claude exited with code ${claude_exit}" >&2
    fi

    # The baseline output is the review itself
    # Extract everything after any system preamble
    cp "${result_dir}/claude-output.txt" "${result_dir}/review.md"
    echo "  Review saved to ${result_dir}/review.md"
    echo "  Done with ${id} (baseline)"
}

# Run a single benchmark and save the review output.
# Dispatches between crafted (apply patch to temp branch) and real-world PR
# (review via PR URL) modes based on whether the metadata has a source field.
# Args: $1 = benchmark ID, $2 = run ID, $3 = approach (skill or baseline)
run_benchmark() {
    local id="$1"
    local run_id="$2"
    local approach="${3:-skill}"

    local bench_dir
    bench_dir=$(resolve_benchmark_dir "${id}") || return 1

    local result_dir="${RESULTS_DIR}/${run_id}/${id}"
    mkdir -p "${result_dir}"

    # Per-benchmark budget from metadata, defaulting to $5
    local budget
    budget=$(jq -r '.budget_usd // 5' "${bench_dir}/metadata.json" 2> /dev/null)

    if [[ "${approach}" == "baseline" ]]; then
        run_baseline_benchmark "${id}" "${bench_dir}" "${result_dir}" "${budget}"
        return
    fi

    # Check if this is a real-world PR benchmark (has source_url in metadata)
    local source_url
    source_url=$(jq -r '.source_url // empty' "${bench_dir}/metadata.json" 2> /dev/null)

    if [[ -n "${source_url}" ]]; then
        run_pr_benchmark "${id}" "${bench_dir}" "${result_dir}" "${source_url}" "${budget}"
    else
        run_crafted_benchmark "${id}" "${bench_dir}" "${result_dir}" "${budget}"
    fi
}

# Run a real-world PR benchmark by reviewing the PR URL directly
# Args: $1 = benchmark ID, $2 = bench dir, $3 = result dir, $4 = PR URL, $5 = budget
run_pr_benchmark() {
    local id="$1"
    local bench_dir="$2"
    local result_dir="$3"
    local pr_url="$4"
    local budget="${5:-5}"

    # Extract org/repo/number from the PR URL (lowercase for file lookup)
    local org repo pr_number
    org=$(echo "${pr_url}" | sed -E 's#.*/([^/]+)/([^/]+)/pull/([0-9]+)#\1#' | tr '[:upper:]' '[:lower:]')
    repo=$(echo "${pr_url}" | sed -E 's#.*/([^/]+)/([^/]+)/pull/([0-9]+)#\2#' | tr '[:upper:]' '[:lower:]')
    pr_number=$(echo "${pr_url}" | sed -E 's#.*/([^/]+)/([^/]+)/pull/([0-9]+)#\3#')

    echo "  Reviewing PR ${pr_url}…"

    # If the benchmark has a frozen diff, tell the reviewer to use it instead of
    # fetching the latest diff from GitHub. This lets us evaluate against the
    # original (pre-fix) code even after the PR author pushes corrections.
    local frozen_diff
    frozen_diff=$(jq -r '.frozen_diff // false' "${bench_dir}/metadata.json" 2> /dev/null)

    local frozen_env=()
    if [[ "${frozen_diff}" == "true" ]]; then
        if [[ -f "${bench_dir}/diff.patch" ]]; then
            frozen_env=(REVIEW_CODE_FROZEN_DIFF="${bench_dir}/diff.patch")
            echo "  Using frozen diff from ${bench_dir}/diff.patch"
        else
            echo "  Error: frozen_diff is true but ${bench_dir}/diff.patch not found" >&2
            return 1
        fi
    fi

    # Run the review via claude -p using the PR URL.
    # Unset CLAUDECODE to allow running inside an existing Claude Code session.
    echo "  Budget: \$${budget}"
    local claude_exit=0
    env -u CLAUDECODE "${frozen_env[@]}" claude -p "/review-code ${pr_url} --force" \
        --dangerously-skip-permissions \
        --max-budget-usd "${budget}" \
        > "${result_dir}/claude-output.txt" 2>&1 || claude_exit=$?

    if [[ ${claude_exit} -ne 0 ]]; then
        echo "  Warning: claude exited with code ${claude_exit}" >&2
    fi

    # The review file is saved under the PR's org/repo
    local review_file="${SKILL_REVIEWS_DIR}/${org}/${repo}/pr-${pr_number}.md"
    if [[ -f "${review_file}" ]]; then
        cp "${review_file}" "${result_dir}/review.md"
        echo "  Review saved to ${result_dir}/review.md"
    else
        echo "  Warning: review file not found at ${review_file}" >&2
        # Fallback: search for any file matching the PR number
        local found
        found=$(find "${SKILL_REVIEWS_DIR}/${org}/${repo}" -name "*${pr_number}*" -type f 2> /dev/null | head -1)
        if [[ -n "${found}" ]]; then
            cp "${found}" "${result_dir}/review.md"
            echo "  Found review at ${found}"
        else
            echo "  No review output found" >&2
        fi
    fi

    echo "  Done with ${id}"
}

# Run a crafted benchmark by applying patch to a temporary branch
# Args: $1 = benchmark ID, $2 = bench dir, $3 = result dir, $4 = budget
run_crafted_benchmark() {
    local id="$1"
    local bench_dir="$2"
    local result_dir="$3"
    local budget="${4:-5}"

    local patch="${bench_dir}/diff.patch"
    if [[ ! -f "${patch}" ]]; then
        echo "Error: patch not found at ${patch}" >&2
        return 1
    fi

    # Fail fast if working tree is dirty — patching on a dirty tree risks losing work
    if [[ -n "$(git -C "${REPO_ROOT}" status --porcelain 2> /dev/null)" ]]; then
        echo "Error: working tree is dirty; commit or stash changes before running crafted benchmarks" >&2
        return 1
    fi

    local tmp_branch="eval-tmp-${id}"
    local original_branch
    original_branch=$(git -C "${REPO_ROOT}" branch --show-current 2> /dev/null || echo "HEAD")

    # Ensure we restore the original branch and clean up the temp branch on any exit
    cleanup_crafted_benchmark() {
        git -C "${REPO_ROOT}" checkout "${original_branch}" --quiet 2> /dev/null || true
        git -C "${REPO_ROOT}" branch -D "${tmp_branch}" --quiet 2> /dev/null || true
    }
    trap cleanup_crafted_benchmark RETURN

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
        if ! git -C "${REPO_ROOT}" apply "${base_patch}"; then
            echo "  Error: failed to apply base patch for ${id}" >&2
            return 1
        fi
        git -C "${REPO_ROOT}" add -A
        git -C "${REPO_ROOT}" commit -m "eval: base state for ${id}" --quiet --no-gpg-sign
    fi

    if ! git -C "${REPO_ROOT}" apply --check "${patch}" 2> /dev/null; then
        echo "  Warning: patch does not apply cleanly, attempting forced apply" >&2
        if ! git -C "${REPO_ROOT}" apply "${patch}" --allow-empty 2> /dev/null; then
            echo "  Error: failed to apply patch for ${id}" >&2
            return 1
        fi
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

    # Run the review via claude -p.
    # Unset CLAUDECODE to allow running inside an existing Claude Code session.
    echo "  Budget: \$${budget}"
    local claude_exit=0
    env -u CLAUDECODE claude -p "/review-code ${tmp_branch} --force" \
        --dangerously-skip-permissions \
        --max-budget-usd "${budget}" \
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
        local found
        found=$(find "${SKILL_REVIEWS_DIR}" -name "*${tmp_branch}*" -type f 2> /dev/null | head -1)
        if [[ -n "${found}" ]]; then
            cp "${found}" "${result_dir}/review.md"
            echo "  Found review at ${found}"
        else
            echo "  No review output found" >&2
        fi
    fi

    # Cleanup happens automatically via the RETURN trap
    echo "  Done with ${id}"
}

# Write a run manifest with metadata
# Args: $1 = run ID, $2 = approach, remaining = benchmark IDs
write_manifest() {
    local run_id="$1"
    local approach="$2"
    shift 2
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
        --arg approach "${approach}" \
        --arg sha "${sha}" \
        --arg model "${model}" \
        --arg timestamp "${timestamp}" \
        --argjson benchmarks "${benchmark_json}" \
        '{
            run_id: $run_id,
            approach: $approach,
            git_sha: $sha,
            model: $model,
            timestamp: $timestamp,
            benchmarks: $benchmarks
        }' > "${manifest}"
}

# Run a set of benchmarks with a given approach and return the run ID.
# Args: $1 = approach, remaining = benchmark IDs
# Outputs: run ID on stdout (after all status messages on stderr)
run_with_approach() {
    local approach="$1"
    shift
    local benchmarks=("$@")

    local run_id
    run_id=$(generate_run_id)
    # Add approach suffix to distinguish parallel runs
    if [[ "${approach}" != "skill" ]]; then
        run_id="${run_id}-${approach}"
    fi

    echo "Starting eval run: ${run_id} (approach: ${approach})"
    echo "Benchmarks: ${benchmarks[*]}"
    echo ""

    local failed=0
    for id in "${benchmarks[@]}"; do
        echo "Running benchmark: ${id}"
        if ! run_benchmark "${id}" "${run_id}" "${approach}"; then
            echo "  FAILED: ${id}" >&2
            ((failed++))
        fi
        echo ""
    done

    write_manifest "${run_id}" "${approach}" "${benchmarks[@]}"

    echo "Run complete: ${run_id}"
    echo "Results: ${RESULTS_DIR}/${run_id}/"
    if [[ ${failed} -gt 0 ]]; then
        echo "${failed} benchmark(s) failed" >&2
    fi

    return ${failed}
}

main() {
    local mode="" target="" approach=""

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
            --sample)
                mode="sample"
                shift
                ;;
            --approach)
                approach="${2:?--approach requires a value (skill or baseline)}"
                if [[ "${approach}" != "skill" ]] && [[ "${approach}" != "baseline" ]]; then
                    echo "Error: --approach must be 'skill' or 'baseline'" >&2
                    exit 1
                fi
                shift 2
                ;;
            -h | --help)
                echo "Usage: run-eval.sh --benchmark <id> | --all | --category <cat> | --sample"
                echo "       [--approach <skill|baseline>]"
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                exit 1
                ;;
        esac
    done

    if [[ -z "${mode}" ]]; then
        echo "Usage: run-eval.sh --benchmark <id> | --all | --category <cat> | --sample" >&2
        echo "       [--approach <skill|baseline>]" >&2
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
        sample)
            local all_ids=()
            while IFS= read -r id; do
                all_ids+=("${id}")
            done < <(list_benchmarks)
            if [[ ${#all_ids[@]} -eq 0 ]]; then
                echo "No benchmarks found" >&2
                exit 1
            fi
            local idx=$((RANDOM % ${#all_ids[@]}))
            benchmarks=("${all_ids[${idx}]}")
            echo "Sampled benchmark: ${benchmarks[0]}"
            echo ""
            ;;
    esac

    if [[ ${#benchmarks[@]} -eq 0 ]]; then
        echo "No benchmarks found" >&2
        exit 1
    fi

    # Determine which approaches to run
    local approaches=()
    if [[ -n "${approach}" ]]; then
        approaches=("${approach}")
    elif [[ "${mode}" == "sample" ]]; then
        # --sample without --approach runs both for direct comparison
        approaches=("skill" "baseline")
    else
        approaches=("skill")
    fi

    local total_failed=0
    for a in "${approaches[@]}"; do
        if ! run_with_approach "${a}" "${benchmarks[@]}"; then
            ((total_failed++))
        fi
    done

    if [[ ${total_failed} -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
