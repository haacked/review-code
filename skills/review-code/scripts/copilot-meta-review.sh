#!/usr/bin/env bash
# copilot-meta-review.sh - Use Copilot CLI to validate review findings and do a cursory code scan
#
# Usage:
#   echo '{"findings": [...], "diff": "<diff text>", "timeout_seconds": 300}' | copilot-meta-review.sh
#
# Input (stdin): JSON with findings array (required), diff (optional), and optional timeout_seconds
# Output (stdout): JSON with available, timed_out, validations, missed_issues, duration_ms
#
# A lighter meta-review than a full parallel pass: validate Claude's findings
# and do a cursory scan for anything obvious that was missed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/copilot-helpers.sh
source "${SCRIPT_DIR}/helpers/copilot-helpers.sh"
# shellcheck source=helpers/meta-review-shared.sh
source "${SCRIPT_DIR}/helpers/meta-review-shared.sh"

main() {
    run_meta_review copilot copilot_available copilot_parse_final_message copilot_invoke \
        "${COPILOT_LOG_DIR}" "${COPILOT_META_REVIEW_TIMEOUT}" "${COPILOT_MAX_DIFF_BYTES}"
}

main "$@"
