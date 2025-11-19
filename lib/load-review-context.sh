#!/usr/bin/env bash
# load-review-context.sh - Load language/framework/org/repo-specific review context
# Requires: bash 4.0+ for associative arrays
#
# Usage:
#   echo "$lang_info" | load-review-context.sh [org] [repo]
#
# Description:
#   Reads JSON output from code-language-detect.sh via stdin and loads
#   relevant context files from ai/context/ in hierarchical order:
#   language → framework → org → repo
#
# Input (JSON):
#   {
#     "languages": ["python", "typescript"],
#     "frameworks": ["react", "django"],
#     "has_frontend": true,
#     "file_extensions": [".py", ".ts", ".tsx"]
#   }
#
# Arguments:
#   $1 - org (optional, e.g., "posthog")
#   $2 - repo (optional, e.g., "posthog")
#
# Output:
#   Concatenated markdown from matching context files

set -euo pipefail

# Source debug helpers
SCRIPT_DIR_EARLY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers/debug-helpers.sh
source "$SCRIPT_DIR_EARLY/helpers/debug-helpers.sh"
# shellcheck source=lib/helpers/config-helpers.sh
source "$SCRIPT_DIR_EARLY/helpers/config-helpers.sh"

debug_time "04-context-loading" "start"

# Save any externally-set CONTEXT_PATH (for tests)
EXTERNAL_CONTEXT_PATH="${CONTEXT_PATH:-}"

# Load config if available (installed mode)
CONFIG_FILE="$HOME/.claude/review-code.env"
if [ -f "$CONFIG_FILE" ]; then
    load_config_safely "$CONFIG_FILE"
fi

# Get the directory where this script lives and derive context directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW_CODE_DIR="$(dirname "$SCRIPT_DIR")"

# Use CONTEXT_PATH from (1) external env, (2) config file, or (3) relative path
if [ -n "$EXTERNAL_CONTEXT_PATH" ]; then
    CONTEXT_DIR="$EXTERNAL_CONTEXT_PATH"
else
    CONTEXT_DIR="${CONTEXT_PATH:-$REVIEW_CODE_DIR/context}"
fi

# Read JSON from stdin
lang_info=$(cat)

# Validate org/repo parameters to prevent path traversal (defense in depth)
# Upstream validation exists, but we validate here too for security
sanitize_org_repo() {
    local input="$1"

    # Allow empty (optional parameter)
    [[ -z "$input" ]] && return 0

    # Reject absolute paths
    if [[ "$input" == /* ]]; then
        debug_trace "04-context-loading" "Rejected absolute path: $input"
        return 1
    fi

    # Block path traversal
    if [[ "$input" =~ \.\. ]]; then
        debug_trace "04-context-loading" "Rejected path traversal: $input"
        return 1
    fi

    # Only allow lowercase alphanumeric, dash, underscore
    if [[ ! "$input" =~ ^[a-z0-9_-]+$ ]]; then
        debug_trace "04-context-loading" "Rejected invalid characters: $input"
        return 1
    fi

    echo "$input"
    return 0
}

# Get optional org and repo parameters
org="${1:-}"
repo="${2:-}"

# Validate org parameter (defense in depth)
if [ -n "$org" ]; then
    if ! org=$(sanitize_org_repo "$org"); then
        debug_trace "04-context-loading" "Invalid org parameter, ignoring: $1"
        org=""
    fi
fi

# Validate repo parameter (defense in depth)
if [ -n "$repo" ]; then
    if ! repo=$(sanitize_org_repo "$repo"); then
        debug_trace "04-context-loading" "Invalid repo parameter, ignoring: $2"
        repo=""
    fi
fi

# Extract languages and frameworks as space-separated lists
# Allow jq to fail gracefully with malformed JSON
languages=$(echo "$lang_info" | jq -r '.languages[]?' 2> /dev/null | tr '\n' ' ' || true)
frameworks=$(echo "$lang_info" | jq -r '.frameworks[]?' 2> /dev/null | tr '\n' ' ' || true)

debug_save_json "04-context-loading" "input-lang-info.json" <<< "$lang_info"
debug_trace "04-context-loading" "Languages detected: $languages"
debug_trace "04-context-loading" "Frameworks detected: $frameworks"
debug_trace "04-context-loading" "Org: ${org:-none}, Repo: ${repo:-none}"

context=""
declare -A loaded_files
declare -a loaded_file_list

# Load language-specific context
for lang in $languages; do
    # Convert to lowercase using bash parameter expansion
    lang_lower="${lang,,}"
    file="$CONTEXT_DIR/languages/${lang_lower}.md"

    if [ -f "$file" ]; then
        debug_trace "04-context-loading" "Loaded: $file"
        loaded_file_list+=("context/languages/${lang_lower}.md")
        if [ -n "$context" ]; then
            context="$context\n\n"
        fi
        context="$context## ${lang^} Guidelines\n\n$(cat "$file")"
    fi
done

# Load framework-specific context
for fw in $frameworks; do
    # Convert to lowercase using bash parameter expansion
    fw_lower="${fw,,}"
    file="$CONTEXT_DIR/frameworks/${fw_lower}.md"

    # Only load each file once using associative array (O(1) check)
    if [ -f "$file" ] && [ -z "${loaded_files[$file]:-}" ]; then
        loaded_files[$file]=1
        debug_trace "04-context-loading" "Loaded: $file"
        loaded_file_list+=("context/frameworks/${fw_lower}.md")

        # Extract filename without path and extension using bash parameter expansion
        filename="${file##*/}"
        filename="${filename%.md}"

        # Capitalize first letter
        display_name="${filename^}"

        if [ -n "$context" ]; then
            context="$context\n\n"
        fi
        context="$context## ${display_name} Guidelines\n\n$(cat "$file")"
    fi
done

# Load org-specific context if org is provided
if [ -n "$org" ]; then
    # Convert org to lowercase
    org_lower="${org,,}"
    org_file="$CONTEXT_DIR/orgs/${org_lower}/org.md"

    if [ -f "$org_file" ]; then
        debug_trace "04-context-loading" "Loaded: $org_file"
        loaded_file_list+=("context/orgs/${org_lower}/org.md")
        if [ -n "$context" ]; then
            context="$context\n\n"
        fi
        context="$context## ${org^} Organization Guidelines\n\n$(cat "$org_file")"
    fi
fi

# Load repo-specific context if both org and repo are provided
if [ -n "$org" ] && [ -n "$repo" ]; then
    # Convert to lowercase
    org_lower="${org,,}"
    repo_lower="${repo,,}"
    repo_file="$CONTEXT_DIR/orgs/${org_lower}/repos/${repo_lower}.md"

    if [ -f "$repo_file" ]; then
        debug_trace "04-context-loading" "Loaded: $repo_file"
        loaded_file_list+=("context/orgs/${org_lower}/repos/${repo_lower}.md")
        if [ -n "$context" ]; then
            context="$context\n\n"
        fi
        context="$context## ${org^}/${repo^} Repository Guidelines\n\n$(cat "$repo_file")"
    fi
fi

# Debug: Save summary of loaded files
if is_debug_enabled; then
    if [ "${#loaded_file_list[@]}" -gt 0 ]; then
        debug_save "04-context-loading" "loaded-files.txt" "$(printf '%s\n' "${loaded_file_list[@]}")"
    else
        debug_save "04-context-loading" "loaded-files.txt" "(no files loaded)"
    fi
    debug_stats "04-context-loading" \
        files_loaded "${#loaded_file_list[@]}" \
        languages_requested "$(echo "$languages" | wc -w | tr -d ' ')" \
        frameworks_requested "$(echo "$frameworks" | wc -w | tr -d ' ')"
    debug_time "04-context-loading" "end"
fi

# Output context or nothing if no matches
if [ -n "$context" ]; then
    echo -e "$context"
fi
