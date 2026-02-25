#!/usr/bin/env bash
# load-false-positives.sh - Load false positive patterns from learnings index
#
# Usage:
#   load-false-positives.sh
#
# Description:
#   Reads learnings/index.jsonl, filters for type=="false_positive",
#   groups by agent, and outputs a markdown summary
#   that agents can use to suppress known false positive patterns.
#
# Output (JSON):
#   {"content": "<markdown>", "count": N}
#
#   content: Markdown-formatted false positive patterns grouped by agent
#   count: Number of false positive patterns found

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=helpers/config-helpers.sh
source "${SCRIPT_DIR}/helpers/config-helpers.sh"

# Get learnings directory from config - allow override via LEARNINGS_PATH for tests
LEARNINGS_DIR="${LEARNINGS_PATH:-$(get_learnings_dir)}"

INDEX_FILE="${LEARNINGS_DIR}/index.jsonl"

# Early exit if no learnings file or empty
if [[ ! -f "${INDEX_FILE}" ]] || [[ ! -s "${INDEX_FILE}" ]]; then
    jq -n '{content: "", count: 0}'
    exit 0
fi

# Filter for false_positive entries and group by agent + context
# Uses a single jq invocation to avoid multiple passes over the file
jq -rs '
    # Filter to false_positive entries only
    [.[] | select(.type == "false_positive")] |
    if length == 0 then
        {content: "", count: 0}
    else
        . as $fps |
        # Group by agent
        group_by(.agent // "unknown") |
        map({
            agent: (.[0].agent // "unknown"),
            patterns: [.[] | {
                file: .finding.file,
                description: .finding.description,
                pr: .pr_number
            }]
        }) |
        # Build markdown content
        (map(
            "### \(.agent)\n" +
            (.patterns | map("- \(.description) (`\(.file)`, PR #\(.pr))") | join("\n"))
        ) | join("\n\n")) as $md |
        {
            content: $md,
            count: ($fps | length)
        }
    end
' "${INDEX_FILE}"
