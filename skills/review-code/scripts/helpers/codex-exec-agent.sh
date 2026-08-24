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
# `codex exec` also has no flag for selecting a custom agent: the TOMLs under
# ~/.codex/agents are configuration layers Codex applies to sessions it spawns
# itself, and it spawns those only when a parent session delegates to an agent
# by name. Going through a parent would make the final message an
# orchestrator's summary, and --output-last-message captures the final message,
# so the findings would never reach <output-file> intact. This helper therefore
# applies the rendered agent itself: its model and reasoning effort become
# flags, and its developer_instructions lead the prompt. One `codex exec` turn
# per reviewer, with that reviewer's own findings as the final message.
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

CODEX_HOME_DIR="${CODEX_HOME:-${HOME}/.codex}"
AGENT_TOML="${CODEX_HOME_DIR}/agents/${AGENT_NAME}.toml"

# Refuse to fall back to a bare `codex exec`. A review that silently runs with
# no reviewer instructions and the default model looks like a finished review.
[[ -f "${AGENT_TOML}" ]] || {
    echo "ERROR: no rendered Codex agent at ${AGENT_TOML}" >&2
    echo "  Run bin/setup to render and install the review-code agents." >&2
    exit 1
}

INSTRUCTIONS_FILE="$(mktemp)"
trap 'rm -f "${INSTRUCTIONS_FILE}"' EXIT

# render-codex-agents.py writes each field as a JSON string literal, so the
# instructions arrive here with escaped newlines; tomllib decodes them back
# into the agent definition's own prose. Parse rather than pattern-match: this
# directory also holds agents installed from elsewhere, whose TOML is written
# by hand and may use multi-line string syntax we never emit. An agent whose
# model is `inherit` renders without model or effort, and the empty fields that
# produces mean "leave the parent session's setting alone".
agent_config="$(
    python3 - "${AGENT_TOML}" "${INSTRUCTIONS_FILE}" << 'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    agent = tomllib.load(handle)

instructions = agent.get("developer_instructions", "")
if not instructions.strip():
    sys.exit(f"{sys.argv[1]}: no developer_instructions")

with open(sys.argv[2], "w") as handle:
    handle.write(instructions)

print(f"{agent.get('model', '')}|{agent.get('model_reasoning_effort', '')}")
PY
)" || {
    echo "ERROR: could not read the agent definition at ${AGENT_TOML}" >&2
    echo "  Reading it needs python3 3.11 or newer (tomllib)." >&2
    exit 1
}

# Split on a literal '|' rather than whitespace so an absent model still
# leaves the effort in the second field.
IFS='|' read -r AGENT_MODEL AGENT_EFFORT <<< "${agent_config}"

mkdir -p "$(dirname "${OUTPUT_FILE}")"

# --json keeps stdout parseable; we extract the last agent_message. --sandbox
# read-only matches review-code's contract: agents read, never mutate. Codex
# writes the final text only when --output-last-message is provided, which
# keeps the raw JSONL stream (which can be large) out of the findings file.
codex_args=(
    exec
    --json
    --sandbox read-only
    --output-last-message "${OUTPUT_FILE}"
)
if [[ -n "${AGENT_MODEL}" ]]; then
    codex_args+=(--model "${AGENT_MODEL}")
fi
if [[ -n "${AGENT_EFFORT}" ]]; then
    # Codex parses a -c value as TOML and falls back to the raw string, so a
    # bare effort name needs no quoting of its own.
    codex_args+=(-c "model_reasoning_effort=${AGENT_EFFORT}")
fi

codex "${codex_args[@]}" "$(cat "${INSTRUCTIONS_FILE}")

$(cat "${PROMPT_FILE}")"
