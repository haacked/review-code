#!/usr/bin/env bash
# ci-fetch-logs.sh - Fetch failure logs for a workflow run
#
# Usage:
#   ci-fetch-logs.sh <run_id> [<org/repo>]
#
# Output: JSON with structured failure log excerpts, truncated to last N lines per job

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/ci-helpers.sh
source "${SCRIPT_DIR}/helpers/ci-helpers.sh"

run_id="${1:?Usage: ci-fetch-logs.sh <run_id> [<org/repo>]}"
repo_arg="${2:-}"

repo_flag=()
if [[ -n "${repo_arg}" ]]; then
    repo_flag=(--repo "${repo_arg}")
fi

# ── Fetch run metadata ──────────────────────────────────────────────────────

run_json=$(gh run view "${run_id}" \
    "${repo_flag[@]}" \
    --json name,workflowName,conclusion,jobs \
    2> /dev/null) || {
    ci_json_error "Could not fetch run ${run_id}"
    exit 0
}

workflow_name=$(echo "${run_json}" | jq -r '.workflowName // .name // "unknown"')

# ── Fetch failed job logs ────────────────────────────────────────────────────

# gh run view --log-failed outputs logs prefixed with job/step names
raw_logs=$(gh run view "${run_id}" \
    "${repo_flag[@]}" \
    --log-failed \
    2> /dev/null) || raw_logs=""

if [[ -z "${raw_logs}" ]]; then
    # No failed logs available - might be a non-test failure (e.g., cancelled)
    jq -n \
        --arg run_id "${run_id}" \
        --arg workflow "${workflow_name}" \
        '{
      run_id: ($run_id | tonumber),
      workflow: $workflow,
      failed_jobs: [],
      error: "No failure logs available. The run may have been cancelled or the logs expired."
    }'
    exit 0
fi

# Parse logs by job name (first tab-separated field)
# Group lines by job, keep last CI_LOG_TAIL_LINES per job
failed_jobs_json=$(echo "${raw_logs}" | awk -F'\t' -v tail_lines="${CI_LOG_TAIL_LINES}" '
BEGIN {
  job_count = 0
}
{
  # Extract job name from first field
  job = $1
  # Rest is the log line (rejoin remaining fields)
  log_line = ""
  for (i = 2; i <= NF; i++) {
    if (i > 2) log_line = log_line "\t"
    log_line = log_line $i
  }

  if (!(job in seen)) {
    seen[job] = 1
    jobs[job_count] = job
    job_count++
    line_count[job] = 0
  }

  # Store lines in a circular buffer
  idx = line_count[job] % tail_lines
  lines[job, idx] = log_line
  line_count[job]++
}
END {
  printf "["
  for (j = 0; j < job_count; j++) {
    job = jobs[j]
    count = line_count[job]
    start = 0
    total = count
    if (count > tail_lines) {
      start = count % tail_lines
      total = tail_lines
    }

    if (j > 0) printf ","
    printf "{\"name\":%s,\"log_excerpt\":\"", json_escape_key(job)

    for (k = 0; k < total; k++) {
      idx = (start + k) % tail_lines
      line = lines[job, idx]
      # Escape JSON special characters
      gsub(/\\/, "\\\\", line)
      gsub(/"/, "\\\"", line)
      gsub(/\t/, "\\t", line)
      gsub(/\r/, "", line)
      if (k > 0) printf "\\n"
      printf "%s", line
    }
    printf "\"}"
  }
  printf "]"
}

function json_escape_key(s) {
  gsub(/\\/, "\\\\", s)
  gsub(/"/, "\\\"", s)
  return "\"" s "\""
}
')

# ── Output ───────────────────────────────────────────────────────────────────

jq -n \
    --arg run_id "${run_id}" \
    --arg workflow "${workflow_name}" \
    --argjson failed_jobs "${failed_jobs_json}" \
    '{
    run_id: ($run_id | tonumber),
    workflow: $workflow,
    failed_jobs: $failed_jobs,
    error: null
  }'
