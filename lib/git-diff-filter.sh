#!/usr/bin/env bash
# Wrapper around git-diff-context.sh that filters out noise files from diffs
# This reduces token usage by 85-95% for PRs with snapshots, lock files, and generated files
#
# Usage: git-diff-filter.sh
# Output: Filtered diff to stdout, metadata to stderr (same interface as git-diff-context.sh)

# Source error helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers/error-helpers.sh
source "$SCRIPT_DIR/helpers/error-helpers.sh"
# shellcheck source=lib/helpers/debug-helpers.sh
source "$SCRIPT_DIR/helpers/debug-helpers.sh"

set -euo pipefail

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared exclusion patterns
source "$SCRIPT_DIR/helpers/exclusion-patterns.sh"

# Get comprehensive exclusion patterns
mapfile -t EXCLUDE_PATTERNS < <(get_exclusion_patterns extended)

debug_time "02-diff-filter" "start"
debug_save "02-diff-filter" "exclusion-patterns.txt" "$(printf '%s\n' "${EXCLUDE_PATTERNS[@]}")"
debug_trace "02-diff-filter" "Using extended exclusion patterns ($(echo "${EXCLUDE_PATTERNS[@]}" | wc -w | tr -d ' ') patterns)"

# Detect diff type by calling git-diff-context.sh and capturing stderr
# Only suppress exit code 1 (no changes), not other errors
diff_metadata=$("$SCRIPT_DIR/git-diff-context.sh" 2>&1 > /dev/null || test $? = 1)

# Output the metadata to stderr (preserve original behavior)
echo "$diff_metadata" >&2

debug_save "02-diff-filter" "metadata.txt" "$diff_metadata"

# Parse metadata in single pass using read loop
diff_type=""
base_branch=""

while IFS= read -r line; do
    case "$line" in
        "DIFF_TYPE: staged")
            diff_type="staged"
            ;;
        "DIFF_TYPE: unstaged")
            diff_type="unstaged"
            ;;
        "DIFF_TYPE: branch")
            diff_type="branch"
            ;;
        "BASE_BRANCH:"*)
            base_branch="${line#BASE_BRANCH: }"
            ;;
    esac
done <<< "$diff_metadata"

# Token Optimization: Use minimal context lines (default is 3)
# Agents can read full files if they need more context
CONTEXT_LINES="${DIFF_CONTEXT_LINES:-1}"

# Capture raw diff (without exclusions) for debugging
raw_lines=0
if is_debug_enabled; then
    case "$diff_type" in
        staged)
            raw_diff=$(git diff --staged --unified="$CONTEXT_LINES" 2> /dev/null || test $? = 1)
            ;;
        unstaged)
            raw_diff=$(git diff --unified="$CONTEXT_LINES" 2> /dev/null || test $? = 1)
            ;;
        branch)
            if [ -n "$base_branch" ]; then
                raw_diff=$(git diff --unified="$CONTEXT_LINES" "$base_branch"...HEAD 2> /dev/null || test $? = 1)
            fi
            ;;
    esac
    debug_save "02-diff-filter" "raw-diff.txt" "$raw_diff"
    raw_lines=$(echo "$raw_diff" | wc -l | tr -d ' ')
    debug_trace "02-diff-filter" "Raw diff: $raw_lines lines"
fi

# Generate filtered diff based on type
filtered_diff=""
case "$diff_type" in
    staged)
        # Staged changes (suppress exit code 1 for no differences)
        filtered_diff=$(git diff --staged --unified="$CONTEXT_LINES" -- . "${EXCLUDE_PATTERNS[@]}" 2> /dev/null || test $? = 1)
        ;;
    unstaged)
        # Unstaged changes (suppress exit code 1 for no differences)
        filtered_diff=$(git diff --unified="$CONTEXT_LINES" -- . "${EXCLUDE_PATTERNS[@]}" 2> /dev/null || test $? = 1)
        ;;
    branch)
        # Branch changes (suppress exit code 1 for no differences)
        if [ -n "$base_branch" ]; then
            filtered_diff=$(git diff --unified="$CONTEXT_LINES" "$base_branch"...HEAD -- . "${EXCLUDE_PATTERNS[@]}" 2> /dev/null || test $? = 1)
        fi
        ;;
    *)
        # Fallback: no changes or error
        exit 0
        ;;
esac

# Output the filtered diff
echo "$filtered_diff"

# Debug: Save filtered diff and calculate statistics
if is_debug_enabled; then
    debug_save "02-diff-filter" "filtered-diff.txt" "$filtered_diff"
    filtered_lines=$(echo "$filtered_diff" | wc -l | tr -d ' ')
    reduction=0
    if [ "$raw_lines" -gt 0 ]; then
        reduction=$((100 - (filtered_lines * 100 / raw_lines)))
    fi

    # Estimate token counts (rough estimate: ~4 chars per token for code)
    raw_chars=$(echo "$raw_diff" | wc -c | tr -d ' ')
    filtered_chars=$(echo "$filtered_diff" | wc -c | tr -d ' ')
    raw_tokens=$((raw_chars / 4))
    filtered_tokens=$((filtered_chars / 4))
    tokens_saved=$((raw_tokens - filtered_tokens))

    debug_stats "02-diff-filter" \
        raw_lines "$raw_lines" \
        filtered_lines "$filtered_lines" \
        reduction_percent "$reduction" \
        diff_type "$diff_type" \
        raw_tokens "$raw_tokens" \
        filtered_tokens "$filtered_tokens" \
        tokens_saved "$tokens_saved"
    debug_trace "02-diff-filter" "Filtered diff: $filtered_lines lines (${reduction}% reduction, ~$tokens_saved tokens saved)"
    debug_time "02-diff-filter" "end"
fi
