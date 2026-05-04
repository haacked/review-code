#!/usr/bin/env bash
# ci-check-status.sh - Check CI status for a PR
#
# Usage:
#   ci-check-status.sh <pr_number> [<org/repo>]
#
# Output: JSON with overall status, pass/fail counts, and per-check details

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/ci-helpers.sh
source "${SCRIPT_DIR}/helpers/ci-helpers.sh"

pr_number="${1:?Usage: ci-check-status.sh <pr_number> [<org/repo>]}"
repo_arg="${2:-}"

# Build repo flag if provided
repo_flag=()
if [[ -n "${repo_arg}" ]]; then
    repo_flag=(--repo "${repo_arg}")
fi

# ── Fetch check status ──────────────────────────────────────────────────────

# gh pr checks returns structured JSON with check details
checks_json=$(gh pr checks "${pr_number}" \
    "${repo_flag[@]}" \
    --json name,state,bucket,link,workflow,event \
    2> /dev/null) || {
    ci_json_error "Could not fetch checks for PR #${pr_number}"
    exit 0
}

# Count checks by state
total=$(echo "${checks_json}" | jq 'length')

if [[ "${total}" -eq 0 ]]; then
    jq -n '{
    status: "no_checks",
    all_passed: false,
    total: 0,
    passed: 0,
    failed: 0,
    pending: 0,
    checks: [],
    failed_checks: []
  }'
    exit 0
fi

passed=$(echo "${checks_json}" | jq '[.[] | select(.bucket == "pass")] | length')
failed=$(echo "${checks_json}" | jq '[.[] | select(.bucket == "fail")] | length')
pending=$(echo "${checks_json}" | jq '[.[] | select(.bucket == "pending")] | length')

# Determine overall status
if [[ "${pending}" -gt 0 ]]; then
    status="in_progress"
elif [[ "${failed}" -gt 0 ]]; then
    status="completed"
else
    status="completed"
fi

all_passed="false"
if [[ "${failed}" -eq 0 ]] && [[ "${pending}" -eq 0 ]] && [[ "${passed}" -gt 0 ]]; then
    all_passed="true"
fi

# ── Get run IDs for failed checks ───────────────────────────────────────────
# We need run IDs to fetch failure logs. gh pr checks doesn't provide them,
# so we cross-reference with gh run list.

# Get the head branch and SHA for run listing
pr_view_json=$(gh pr view "${pr_number}" "${repo_flag[@]}" --json headRefName,headRefOid 2> /dev/null || echo "{}")
head_branch=$(echo "${pr_view_json}" | jq -r '.headRefName // ""')
head_sha=$(echo "${pr_view_json}" | jq -r '.headRefOid // ""')

runs_json="[]"
if [[ -n "${head_branch}" ]] && [[ "${failed}" -gt 0 ]]; then
    runs_json=$(gh run list \
        --branch "${head_branch}" \
        "${repo_flag[@]}" \
        --limit 20 \
        --json databaseId,status,conclusion,name,workflowName,headSha \
        2> /dev/null) || runs_json="[]"
fi

# ── Build output ─────────────────────────────────────────────────────────────

# Enrich failed checks with run IDs by matching workflow name and head SHA
# to avoid picking up stale runs from earlier commits on the same branch
enriched_checks=$(echo "${checks_json}" | jq --argjson runs "${runs_json}" --arg head_sha "${head_sha}" '
  [.[] | . as $check |
    {
      name: .name,
      state: .state,
      bucket: .bucket,
      workflow: .workflow.name,
      link: .link,
      run_id: (
        if .bucket == "fail" then
          ($runs | map(select(
            (.conclusion == "failure") and
            (.workflowName == $check.workflow.name) and
            (.headSha == $head_sha)
          )) | first | .databaseId // null)
        else null end
      )
    }
  ]
')

failed_checks=$(echo "${enriched_checks}" | jq '[.[] | select(.bucket == "fail")]')

jq -n \
    --arg status "${status}" \
    --argjson all_passed "${all_passed}" \
    --argjson total "${total}" \
    --argjson passed "${passed}" \
    --argjson failed "${failed}" \
    --argjson pending "${pending}" \
    --argjson checks "${enriched_checks}" \
    --argjson failed_checks "${failed_checks}" \
    '{
    status: $status,
    all_passed: $all_passed,
    total: $total,
    passed: $passed,
    failed: $failed,
    pending: $pending,
    checks: $checks,
    failed_checks: $failed_checks
  }'
