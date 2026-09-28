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
#   agent-dispatch.sh batch <manifest-json>
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

run_batch() {
    local manifest="$1"
    local rows agent prompt_file output_file index exit_code
    local failed=0
    local -a pids=() agents=() prompts=() outputs=()

    if [[ "$(detect_harness)" != codex ]]; then
        echo "ERROR: batch requires Codex; Claude uses native Task completion notifications." >&2
        return 2
    fi
    if ! rows=$(jq -er '
        if type == "array" and length > 0
            and all(.[];
                type == "object"
                and (.agent | type == "string" and test("^[a-zA-Z0-9_-]+$"))
                and all(.prompt_file, .output_file;
                    type == "string" and length > 0 and (test("[[:cntrl:]]") | not)))
            and ([.[].output_file] | length == (unique | length))
        then .[] | [.agent, .prompt_file, .output_file] | join("\t")
        else error("expected nonempty agent entries with unique output paths") end
    ' "${manifest}"); then
        echo "ERROR: invalid batch manifest: ${manifest}" >&2
        return 2
    fi
    while IFS=$'\t' read -r agent prompt_file output_file; do
        if [[ ! -f "${prompt_file}" || ! -r "${prompt_file}" ]]; then
            echo "ERROR: prompt file missing or unreadable: ${prompt_file}" >&2
            return 1
        fi
        agents+=("${agent}")
        prompts+=("${prompt_file}")
        outputs+=("${output_file}")
    done <<< "${rows}"

    for index in "${!agents[@]}"; do
        _run_agent_codex "${agents[index]}" "${prompts[index]}" "${outputs[index]}" &
        pids+=("$!")
    done

    for index in "${!pids[@]}"; do
        if wait "${pids[index]}"; then
            continue
        else
            exit_code=$?
            echo "ERROR: agent ${agents[index]} exited ${exit_code}: ${outputs[index]}" >&2
            failed=1
        fi
    done
    return "${failed}"
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
        batch)
            if [[ $# -ne 2 ]]; then
                echo "Usage: $0 batch <manifest-json>" >&2
                return 2
            fi
            run_batch "$2"
            ;;
        *)
            echo "Usage: $0 {--detect | run <agent-name> <prompt-file> <output-file> | batch <manifest-json>}" >&2
            return 2
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
