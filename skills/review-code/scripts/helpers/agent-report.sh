#!/usr/bin/env bash
# agent-report.sh <output-file>
#
# Write the calling subagent's final report to <output-file>, reading the
# report from stdin.
#
# Why this helper exists
# ----------------------
# Claude Code subagents return findings in-conversation; reaching a file
# requires the subagent to invoke a tool after composing its reply. Codex
# subagents are `codex exec` subprocesses whose final message lands at
# --output-last-message directly. Either way, this script is the single
# funnel for "the orchestrator needs a file containing this agent's complete,
# raw findings".
#
# The review orchestrator instructs every subagent (in the prompt it builds)
# to end its turn by piping its findings through this script:
#
#     cat <<'EOF' | ~/.agents/skills/review-code/scripts/helpers/agent-report.sh \
#         <artifacts_dir>/findings/<agent-name>.md
#     ... findings ...
#     EOF
#
# Under Codex, codex-exec-agent.sh already writes the findings to the same
# path via codex's --output-last-message, and the prompt omits this step. The
# script exists primarily so the Claude path doesn't try to "write" via the
# Write tool (which the subagent must not use, because Write requires user
# permission under Claude's tool-gating, and that stalls a fan-out of N
# agents on N approvals).

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <output-file>" >&2
    exit 2
fi

OUTPUT_FILE="$1"
mkdir -p "$(dirname "${OUTPUT_FILE}")"
cat > "${OUTPUT_FILE}"
