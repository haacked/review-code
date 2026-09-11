#!/usr/bin/env bash
# agent-dispatch.sh - Spawn a review subagent in whichever harness invoked us.
#
# The review orchestrator (handlers/review.md) is harness-agnostic: it
# describes WHAT to run (an agent definition, a prompt, a destination file for
# findings). This helper owns the HOW, which differs:
#
#   - Claude: spawn a subagent through the harness's Task / Agent tool. Claude
#     Code streams findings back in-conversation; the orchestrator writes them
#     out via a follow-up Bash call (see agent-report.sh).
#   - Codex: shell out to `codex exec`. Codex subagents cannot write files
#     back into the orchestrating conversation, so findings land directly in a
#     file under the session's artifacts_dir.
#
# Usage:
#   agent-dispatch.sh --detect
#   agent-dispatch.sh run <agent-name> <prompt-file> <output-file>
#
# Where:
#   agent-name    matches an agents/<agent-name>.md (Claude) or a rendered
#                 ~/.codex/agents/<agent-name>.toml (Codex).
#   prompt-file   path to a markdown file containing the agent's full prompt
#                 (briefing + diff references + file access + output shape).
#   output-file   path where the agent's final report (and nothing else) is
#                 written. The orchestrator reads this file to compose the
#                 review.

set -euo pipefail

_AGENT_DISPATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/config-helpers.sh
source "${_AGENT_DISPATCH_DIR}/config-helpers.sh"

# Detect the harness driving this review. Echoes "claude" or "codex".
detect_harness() {
    if [[ -n "${CLAUDE_CONFIG_DIR:-}" || -n "${CLAUDECODE:-}" ]]; then
        echo "claude"
        return 0
    fi
    if [[ -n "${CODEX_HOME:-}" ]] || command -v codex > /dev/null 2>&1; then
        echo "codex"
        return 0
    fi
    return 1
}

# run_agent <agent-name> <prompt-file> <output-file>
run_agent() {
    local agent_name="$1"
    local prompt_file="$2"
    local output_file="$3"

    [[ -f "${prompt_file}" ]] || {
        echo "ERROR: prompt file not found: ${prompt_file}" >&2
        return 1
    }

    case "$(detect_harness)" in
        claude)
            _run_agent_claude "${agent_name}" "${prompt_file}" "${output_file}"
            ;;
        codex)
            _run_agent_codex "${agent_name}" "${prompt_file}" "${output_file}"
            ;;
        *)
            echo "ERROR: no agent harness detected (neither Claude Code nor \`codex\` CLI found)" >&2
            return 1
            ;;
    esac
}

_run_agent_claude() {
    local agent_name="$1"
    local prompt_file="$2"
    local output_file="$3"

    # Claude drives subagents through its native Task tool, which the
    # orchestrator invokes directly (see handlers/review.md). This helper
    # exists so a non-Task Claude harness could be added in one place.
    echo "ERROR: Claude dispatch is implemented in handlers/review.md (Task tool); this helper handles Codex only." >&2
    echo "  agent: ${agent_name}" >&2
    echo "  prompt: ${prompt_file}" >&2
    echo "  output: ${output_file}" >&2
    return 2
}

_run_agent_codex() {
    local agent_name="$1"
    local prompt_file="$2"
    local output_file="$3"

    exec "${_AGENT_DISPATCH_DIR}/codex-exec-agent.sh" \
        "${agent_name}" "${prompt_file}" "${output_file}"
}

main() {
    local sub="${1:-}"
    case "${sub}" in
        --detect | detect)
            if ! detect_harness; then
                echo "ERROR: no agent harness detected (neither Claude Code nor \`codex\` CLI found)" >&2
                return 1
            fi
            ;;
        run)
            shift
            run_agent "$@"
            ;;
        *)
            echo "Usage: $0 {--detect | run <agent-name> <prompt-file> <output-file>}" >&2
            return 2
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
