#!/usr/bin/env bash
# codex-meta-review.sh - Use Codex CLI to validate review findings and do a cursory code scan
#
# Usage:
#   echo '{"findings": [...], "diff": "<diff text>", "timeout_seconds": 300}' | codex-meta-review.sh
#
# Input (stdin): JSON with findings array (required), diff (optional), and optional timeout_seconds
# Output (stdout): JSON with available, timed_out, validations, missed_issues, duration_ms
#
# Mirrors copilot-meta-review.sh's contract so the review handler can dispatch to either
# engine interchangeably: validate Claude's findings + cursory scan for obvious misses.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/codex-helpers.sh
source "${SCRIPT_DIR}/helpers/codex-helpers.sh"
# shellcheck source=helpers/meta-review-shared.sh
source "${SCRIPT_DIR}/helpers/meta-review-shared.sh"

main() {
    run_meta_review codex codex_available codex_parse_final_message codex_invoke \
        "${CODEX_LOG_DIR}" "${CODEX_META_REVIEW_TIMEOUT}" "${CODEX_MAX_DIFF_BYTES}"
}

main "$@"
