#!/usr/bin/env bash
# codex-exec-agent.sh <agent-name> <prompt-file> <output-file>
#
# Invoke a rendered Codex agent (installed by bin/setup to ~/.codex/agents/)
# with the prompt body from <prompt-file>. Output goes to <output-file>.
#
# Codex's `exec` command is the only supported headless invocation; it has no
# persistent "Task" tool, no agent resume, and no way for the subagent to
# stream structured events back into this shell. We tolerate that: the cost
# is that per-agent "bounce" rounds (coverage review, finding-validation
# resume, voice rewrite callbacks) become fresh invocations rather than
# thread-continuations.
#
# Exit codes mirror codex(1).

set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <agent-name> <prompt-file> <output-file>" >&2
    exit 2
fi

AGENT_NAME="$1"
PROMPT_FILE="$2"
OUTPUT_FILE="$3"

[[ -f "${PROMPT_FILE}" ]] || {
    echo "ERROR: prompt file not found: ${PROMPT_FILE}" >&2
    exit 1
}

mkdir -p "$(dirname "${OUTPUT_FILE}")"

# --json keeps stdout parseable; we extract the last agent_message. --sandbox
# read-only matches review-code's contract: agents read, never mutate. Codex
# writes the final text only when --output-last-message is provided, which
# keeps the raw JSONL stream (which can be large) out of the findings file.
codex exec \
    --json \
    --sandbox read-only \
    --output-last-message "${OUTPUT_FILE}" \
    "$(cat "${PROMPT_FILE}")"
