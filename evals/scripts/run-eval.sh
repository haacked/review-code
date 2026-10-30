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
# Results are saved to evals/results/. Each skill run keeps its review files,
# session state, and PR worktrees under its own result directory, so a run never
# reads or replaces the installed skill's reviews of the same PR.
#
# A skill run installs this checkout into a scratch HOME and reviews with it, so
# the result measures this checkout's skill and agents rather than the copy that
# bin/setup last installed. Two checkouts can therefore be compared without
# reinstalling between them. Run them one after the other: PR benchmarks fetch
# into the same local clone, and the two installs do not share its lock.
#
# Environment:
#   EVAL_TARGET_REPO   Git repository that crafted benchmark patches are applied
#                      on top of (default: this repo). Each run clones its HEAD,
#                      so point both sides of a comparison at the same one.
#   EVAL_WORK_DIR      Where each run keeps its scratch HOME, crafted clone, and
#                      session directory (default: ${TMPDIR:-/tmp}/review-code-eval).
#                      The run's manifest records the path.
#   EVAL_BUDGET_USD    Per-benchmark budget cap, overriding each benchmark's
#                      metadata (default: no cap). A benchmark killed mid-review
#                      by a cap produces an unscoreable partial result, so caps
#                      are opt-in.

set -euo pipefail
# Bash 5.2+ expands each & in a ${var//pattern/replacement} replacement to the
# matched text. That turns && in a benchmark diff into {diff_content}{diff_content}.
# Older bash has no such option. The || true discards the shopt error there.
shopt -u patsub_replacement 2> /dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVALS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${EVALS_DIR}/.." && pwd)"
TARGET_REPO="${EVAL_TARGET_REPO:-${REPO_ROOT}}"
REGISTRY="${EVALS_DIR}/benchmarks/registry.json"
RESULTS_DIR="${EVALS_DIR}/results"
BASELINE_PROMPT="${EVALS_DIR}/prompts/baseline.md"
EVAL_WORK_ROOT="${EVAL_WORK_DIR:-${TMPDIR:-/tmp}/review-code-eval}"

source "${SCRIPT_DIR}/helpers/eval-helpers.sh"
# shellcheck source=../../skills/review-code/scripts/helpers/repos-config.sh
source "${REPO_ROOT}/skills/review-code/scripts/helpers/repos-config.sh"

# Set by prepare_eval_home for skill runs.
EVAL_HOME=""
EVAL_SKILL_DIR=""
EVAL_SESSION_DIR=""

# Build the claude -p prompt that runs the review-code skill.
# `claude -p` does not register personal skills as slash commands (verified on
# claude 2.1.219: both `/review-code` and the Skill tool report unknown), so
# instruct the model to load the skill file and follow it directly.
# Print mode cannot answer AskUserQuestion prompts, so pin the answer the
# skill's current-branch disambiguation would ask for: review the branch
# against its base, never a substitute range (a range changes the review
# file's name and the harness then can't find the output).
# Args: $1 = the /review-code arguments (e.g. "my-branch --force")
skill_prompt() {
    echo "Read ${EVAL_SKILL_DIR}/SKILL.md and follow its instructions exactly, as if the user ran: /review-code $1
This session cannot answer interactive prompts. If the skill asks what to review (uncommitted vs branch changes), review the branch changes vs the base branch, re-initializing the session with the branch argument if needed."
}

# Install this checkout into a scratch HOME, clone the crafted target, and make
# a session directory for PR reviews. Sets EVAL_HOME, EVAL_SKILL_DIR,
# EVAL_SESSION_DIR, and TARGET_REPO.
# Args: $1 = work directory for this run
prepare_eval_home() {
    local work_dir="$1"
    local real_home="${HOME}"
    EVAL_HOME="${work_dir}/home"
    EVAL_SESSION_DIR="${work_dir}/session"
    mkdir -p "${EVAL_HOME}/.claude" "${EVAL_SESSION_DIR}" || return 1

    # Setup must run before the links below exist. It installs agents into
    # every PostHog Desktop config home under ~/Library and ~/.config, so with
    # those linked it would write into the real ones. Without CLAUDE_CONFIG_DIR
    # it writes Claude config under the scratch HOME only.
    if ! env -u CLAUDE_CONFIG_DIR HOME="${EVAL_HOME}" CODEX_HOME="${EVAL_HOME}/.codex" \
        "${REPO_ROOT}/bin/setup" > "${work_dir}/setup.log" 2>&1; then
        echo "Error: bin/setup failed; see ${work_dir}/setup.log" >&2
        return 1
    fi

    # The rest of the scratch HOME links to the real one. The claude login is
    # in the keychain under ~/Library. gh, git, and the hooks in user settings
    # read their files under HOME.
    local entry name
    for entry in "${real_home}"/.[!.]* "${real_home}"/*; do
        [[ -e "${entry}" || -L "${entry}" ]] || continue
        name="${entry##*/}"
        [[ -e "${EVAL_HOME}/${name}" || -L "${EVAL_HOME}/${name}" ]] \
            || ln -s "${entry}" "${EVAL_HOME}/${name}" || return 1
    done

    EVAL_SKILL_DIR=$(HOME="${EVAL_HOME}" get_skill_dir)

    # repos.conf maps a PR's repository to its local clone. It is user config,
    # and setup never writes it.
    local repos_conf
    if repos_conf=$(find_repos_config); then
        cp "${repos_conf}" "${EVAL_SKILL_DIR}/" || return 1
    fi

    # The clone's main and origin/main both point at the cloned HEAD, so a
    # branch review of a benchmark diffs against exactly the commit the patch
    # was applied to. Its origin URL is the source's, because the skill and
    # this script read org and repo from it.
    local target="${work_dir}/target"
    local origin_url
    if ! origin_url=$(git -C "${TARGET_REPO}" remote get-url origin) \
        || ! git clone --quiet "${TARGET_REPO}" "${target}" \
        || ! git -C "${target}" remote set-url origin "${origin_url}" \
        || ! git -C "${target}" checkout --quiet -B main \
        || ! git -C "${target}" update-ref refs/remotes/origin/main HEAD \
        || ! git -C "${target}" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main; then
        echo "Error: could not clone ${TARGET_REPO} into ${target}" >&2
        return 1
    fi
    echo "/.claude/" >> "${target}/.git/info/exclude"
    TARGET_REPO="${target}"

    link_eval_agents "${TARGET_REPO}" && link_eval_agents "${EVAL_SESSION_DIR}"
}

# A project's .claude/agents takes precedence over the user's agents, so a
# session started in this directory dispatches the scratch install's agents
# instead of the ones in the real Claude config. A repository that tracks its
# own .claude/agents directory cannot take the link: ln would put it inside
# that directory, and the session would use the installed agents.
# Args: $1 = directory a review session starts in
link_eval_agents() {
    local agents_dir="$1/.claude/agents"
    if [[ -e "${agents_dir}" && ! -L "${agents_dir}" ]]; then
        echo "Error: ${agents_dir} is a directory, so the eval cannot replace its agents" >&2
        return 1
    fi
    mkdir -p "$1/.claude" && ln -sfn "${EVAL_HOME}/.claude/agents" "${agents_dir}"
}

# Run the skill in claude -p against the scratch install and record the
# session's cost, turns, and duration in run-stats.json.
# Args: $1 = result dir, $2 = directory the session starts in,
#       $3 = /review-code arguments, $4 = budget (empty for none),
#       remaining = extra VAR=value entries for the session's environment
run_skill_session() {
    local result_dir="$1"
    local session_dir="$2"
    local review_args="$3"
    local budget="$4"
    shift 4

    echo "  Budget: ${budget:+\$}${budget:-none}"
    local budget_args=()
    [[ -z "${budget}" ]] || budget_args=(--max-budget-usd "${budget}")

    # The keychain stores the login under a name derived from CLAUDE_CONFIG_DIR,
    # and setting it to the default path changes that name. So the session
    # inherits the caller's value, set or unset. When it is unset, the config
    # directory follows HOME to the scratch install, and --settings loads the
    # real user settings in its place.
    local settings_args=()
    if [[ -z "${CLAUDE_CONFIG_DIR:-}" && -f "${HOME}/.claude/settings.json" ]]; then
        settings_args=(--settings "${HOME}/.claude/settings.json")
    fi

    # Unset CLAUDECODE to allow running inside an existing Claude Code session.
    local claude_exit=0
    (
        cd "${session_dir}" \
            && env -u CLAUDECODE HOME="${EVAL_HOME}" "$@" \
                claude -p "$(skill_prompt "${review_args}")" \
                --dangerously-skip-permissions \
                --output-format json \
                "${settings_args[@]}" \
                "${budget_args[@]}"
    ) > "${result_dir}/claude-output.json" 2> "${result_dir}/claude-stderr.txt" || claude_exit=$?

    if [[ ${claude_exit} -ne 0 ]]; then
        echo "  Warning: claude exited with code ${claude_exit}" >&2
    fi

    jq -r '.result // ""' "${result_dir}/claude-output.json" > "${result_dir}/claude-output.txt" 2> /dev/null || true
    jq '{cost_usd: .total_cost_usd, duration_ms, num_turns, is_error}' \
        "${result_dir}/claude-output.json" > "${result_dir}/run-stats.json" 2> /dev/null \
        || echo "  Warning: no session stats in ${result_dir}/claude-output.json" >&2
}

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
    # The metadata description can name the bug the answer key expects.
    # pr-body.md is the description the skill approach sees.
    if [[ -f "${bench_dir}/pr-body.md" ]]; then
        pr_description=$(cat "${bench_dir}/pr-body.md")
    else
        pr_description=$(jq -r '.description // empty' "${bench_dir}/metadata.json" 2> /dev/null)
    fi

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
    local budget="${4:-}"

    local diff_content
    diff_content=$(read_benchmark_diff "${bench_dir}") || return 1

    local prompt
    prompt=$(build_baseline_prompt "${bench_dir}" "${diff_content}")

    echo "  Running baseline review (bare prompt)..."
    echo "  Budget: ${budget:+\$}${budget:-none}"

    local budget_args=()
    [[ -z "${budget}" ]] || budget_args=(--max-budget-usd "${budget}")

    local claude_exit=0
    env -u CLAUDECODE claude -p "${prompt}" \
        --dangerously-skip-permissions \
        "${budget_args[@]}" \
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

    # Budget cap: EVAL_BUDGET_USD or none. Benchmark metadata budget_usd is
    # ignored; a cap that kills a run mid-review leaves a partial result that
    # scores as a false regression.
    local budget="${EVAL_BUDGET_USD:-}"

    if [[ "${approach}" == "baseline" ]]; then
        run_baseline_benchmark "${id}" "${bench_dir}" "${result_dir}" "${budget}"
        return
    fi

    # With the installed skill's roots, a benchmark of a PR the user has already
    # reviewed finds the user's pr-<N>.md. The skill then asks whether to
    # overwrite or append to it. Overwriting deletes the user's review, and
    # appending turns the benchmark into a re-review of that file. Separate
    # roots per benchmark also keep concurrent runs out of each other's sessions.
    local state_dir="${result_dir}/state"
    mkdir -p "${state_dir}/reviews" "${state_dir}/sessions" "${state_dir}/worktrees"
    export REVIEW_CODE_REVIEW_DIR="${state_dir}/reviews"
    export CLAUDE_SESSION_DIR="${state_dir}/sessions"
    export REVIEW_CODE_WORKTREE_DIR="${state_dir}/worktrees"

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
    local budget="${5:-}"

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

    # A frozen diff alone leaves the checkout on the PR's current head, and
    # agents verify every line by reading the file there. On an open PR that
    # means they read the author's later corrections and drop the findings the
    # answer key expects. source_sha pins the checkout to the commit the diff
    # was taken from.
    local source_sha
    source_sha=$(jq -r '.source_sha // ""' "${bench_dir}/metadata.json" 2> /dev/null)
    if [[ -n "${source_sha}" ]]; then
        frozen_env+=(REVIEW_CODE_PR_SHA="${source_sha}")
        echo "  Pinning checkout to ${source_sha}"
    fi

    # The live PR description can describe fixes made after source_sha.
    # pr-body.md holds the description as it read at source_sha.
    if [[ -f "${bench_dir}/pr-body.md" ]]; then
        frozen_env+=(REVIEW_CODE_FROZEN_PR_BODY="${bench_dir}/pr-body.md")
        echo "  Using frozen PR description from ${bench_dir}/pr-body.md"
    fi

    run_skill_session "${result_dir}" "${EVAL_SESSION_DIR}" "${pr_url} --force" "${budget}" \
        "${frozen_env[@]}"

    # The skill removes its PR worktree when the review finishes. A run that
    # dies first leaves the checkout behind and registered in the local clone,
    # where the installed skill's stale-worktree cleanup never looks.
    local leftover
    while IFS= read -r leftover; do
        echo "  Warning: review left a worktree at ${leftover}; remove it with git worktree remove" >&2
    done < <(find "${REVIEW_CODE_WORKTREE_DIR}" -mindepth 3 -maxdepth 3 -type d 2> /dev/null)

    # The review file is saved under the PR's org/repo
    local review_file="${REVIEW_CODE_REVIEW_DIR}/${org}/${repo}/pr-${pr_number}.md"
    if [[ -f "${review_file}" ]]; then
        cp "${review_file}" "${result_dir}/review.md"
        echo "  Review saved to ${result_dir}/review.md"
    else
        echo "  Warning: review file not found at ${review_file}" >&2
        # Fallback: search for any file matching the PR number
        local found
        found=$(find "${REVIEW_CODE_REVIEW_DIR}/${org}/${repo}" -name "*${pr_number}*" -type f 2> /dev/null | head -1)
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
    local budget="${4:-}"

    local patch="${bench_dir}/diff.patch"
    if [[ ! -f "${patch}" ]]; then
        echo "Error: patch not found at ${patch}" >&2
        return 1
    fi

    # The reviewing agent is handed the branch name (skill_prompt puts it in the
    # prompt) and reads the commit messages, so neither may carry the benchmark
    # id: names like shadow-diff-duplication or unsafe-api tell it what to look
    # for before it sees any code. Hash the id instead, which keeps the branch
    # unique per benchmark within a run.
    local bench_tag
    bench_tag=$(printf '%s' "${id}" | git -C "${TARGET_REPO}" hash-object --stdin | cut -c1-12)
    local tmp_branch="eval-tmp-${bench_tag}"

    # Return the clone to main for the run's next benchmark. Called explicitly
    # at every exit path; a RETURN trap is unreliable here (bash fires it after
    # the function's locals are out of scope, aborting under set -u).
    cleanup_crafted_benchmark() {
        git -C "${TARGET_REPO}" checkout main --quiet 2> /dev/null || true
        git -C "${TARGET_REPO}" branch -D "${tmp_branch}" --quiet 2> /dev/null || true
    }

    echo "  Applying patch for ${id} to ${tmp_branch}…"
    git -C "${TARGET_REPO}" checkout -b "${tmp_branch}" --quiet

    # Apply base.patch first if it exists (creates files needed by diff.patch)
    local base_patch="${bench_dir}/base.patch"
    if [[ -f "${base_patch}" ]]; then
        echo "  Applying base patch…"
        if ! git -C "${TARGET_REPO}" apply "${base_patch}"; then
            echo "  Error: failed to apply base patch for ${id}" >&2
            cleanup_crafted_benchmark
            return 1
        fi
        git -C "${TARGET_REPO}" add -A
        git -C "${TARGET_REPO}" commit -m "eval: base state ${bench_tag}" --quiet --no-gpg-sign
    fi

    if ! git -C "${TARGET_REPO}" apply --check "${patch}" 2> /dev/null; then
        echo "  Warning: patch does not apply cleanly, attempting forced apply" >&2
        if ! git -C "${TARGET_REPO}" apply "${patch}" --allow-empty 2> /dev/null; then
            echo "  Error: failed to apply patch for ${id}" >&2
            cleanup_crafted_benchmark
            return 1
        fi
    else
        git -C "${TARGET_REPO}" apply "${patch}"
    fi

    git -C "${TARGET_REPO}" add -A
    git -C "${TARGET_REPO}" commit -m "eval: apply patch ${bench_tag}" --quiet --no-gpg-sign

    echo "  Running review on ${tmp_branch} (${id})…"

    # Determine the org/repo for locating the review output. Plain string
    # slicing instead of sed: BSD sed rejects the lazy quantifier a trailing
    # optional .git group would need.
    local origin_url org repo
    origin_url=$(git -C "${TARGET_REPO}" remote get-url origin)
    origin_url="${origin_url%.git}"
    repo="${origin_url##*/}"
    org="${origin_url%/*}"
    org="${org##*[:/]}"

    # Run the review from inside the target repo, so the skill's git commands
    # operate on the checkout that has the benchmark branch.
    touch "${result_dir}/.start"
    run_skill_session "${result_dir}" "${TARGET_REPO}" "${tmp_branch} --force" "${budget}"

    # Branch reviews are saved as <branch>.md. Otherwise take a review in the
    # repo's directory written since this benchmark started, because the skill
    # may have reviewed an equivalent range and saved it under the range's name.
    # -maxdepth 1 skips the .artifacts directories beside each review, which
    # hold reviewer reports that are also .md files.
    local review_file="${REVIEW_CODE_REVIEW_DIR}/${org}/${repo}/${tmp_branch}.md"
    if [[ ! -f "${review_file}" ]]; then
        review_file=$(find "${REVIEW_CODE_REVIEW_DIR}/${org}/${repo}" -maxdepth 1 -name '*.md' -type f \
            -newer "${result_dir}/.start" 2> /dev/null | head -1)
        [[ -z "${review_file}" ]] || echo "  Note: matched review by timestamp: ${review_file}" >&2
    fi

    if [[ -n "${review_file}" ]]; then
        cp "${review_file}" "${result_dir}/review.md"
        echo "  Review saved to ${result_dir}/review.md"
    else
        echo "  Warning: no review output found for ${id} (${tmp_branch})" >&2
    fi

    cleanup_crafted_benchmark
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
        --arg home "${EVAL_HOME}" \
        --argjson benchmarks "${benchmark_json}" \
        '{
            run_id: $run_id,
            approach: $approach,
            git_sha: $sha,
            model: $model,
            timestamp: $timestamp,
            eval_home: (if $home == "" then null else $home end),
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

    if [[ "${approach}" == "skill" ]]; then
        echo "Installing ${REPO_ROOT} into ${EVAL_WORK_ROOT}/${run_id}/home…"
        prepare_eval_home "${EVAL_WORK_ROOT}/${run_id}" || return 1
    fi
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

    return "${failed}"
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
        *)
            echo "Error: unhandled mode '${mode}'." >&2
            exit 1
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

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
