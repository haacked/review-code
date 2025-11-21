#!/usr/bin/env bash
# code-language-detect.sh - Detect languages and frameworks from diff
# Requires: bash 4.0+ for associative arrays
#
# Usage:
#   git diff | code-language-detect.sh
#   or
#   code-language-detect.sh < diff.txt
#
# Output (JSON):
#   {
#     "languages": ["python", "typescript", "rust"],
#     "frameworks": ["react", "kea"],
#     "has_frontend": true,
#     "file_extensions": [".py", ".ts", ".tsx", ".rs"]
#   }

set -euo pipefail

# Source debug helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers/debug-helpers.sh
source "$SCRIPT_DIR/helpers/debug-helpers.sh"

debug_time "03-language-detection" "start"

# Read diff from stdin
diff_content=$(cat)

debug_save "03-language-detection" "diff-input.txt" "$diff_content"

# Extract file paths from diff
# Format: +++ b/path/to/file.ext or --- a/path/to/file.ext
# grep returns 1 if no matches (which is fine), but we want to catch real errors
file_paths=$(echo "$diff_content" | { grep -E "^(\+\+\+|---) [ab]/" || test $? = 1; } | sed 's/^... [ab]\///')

# Detect languages from file extensions using associative arrays for O(1) lookups
declare -A seen_languages
declare -A seen_frameworks
declare -A seen_extensions
has_frontend=false

while IFS= read -r file; do
    [ -z "$file" ] && continue

    # Extract extension
    ext="${file##*.}"
    ext=".$ext"

    # Add to extensions map (O(1) check)
    seen_extensions[$ext]=1

    # Detect language from extension
    case "$ext" in
        .py)
            seen_languages[python]=1
            ;;
        .ts | .tsx)
            seen_languages[typescript]=1
            has_frontend=true
            ;;
        .js | .jsx)
            seen_languages[javascript]=1
            has_frontend=true
            ;;
        .rs)
            seen_languages[rust]=1
            ;;
        .go)
            seen_languages[go]=1
            ;;
        .rb)
            seen_languages[ruby]=1
            ;;
        .java)
            seen_languages[java]=1
            ;;
        .php)
            seen_languages[php]=1
            ;;
        .c | .h)
            seen_languages[c]=1
            ;;
        .cpp | .cc | .cxx | .hpp)
            seen_languages[cpp]=1
            ;;
        .cs)
            seen_languages[csharp]=1
            ;;
        .swift)
            seen_languages[swift]=1
            ;;
        .kt | .kts)
            seen_languages[kotlin]=1
            ;;
        .sh | .bash)
            seen_languages[bash]=1
            ;;
        .sql)
            seen_languages[sql]=1
            ;;
    esac
done <<< "$file_paths"

# Convert associative arrays to indexed arrays for JSON output
languages=("${!seen_languages[@]}")
extensions=("${!seen_extensions[@]}")

# Detect frameworks from file content in single pass
# Use awk for single-pass pattern matching instead of 6 grep invocations
while IFS= read -r framework; do
    case "$framework" in
        react | kea)
            seen_frameworks[$framework]=1
            has_frontend=true
            ;;
        *)
            seen_frameworks[$framework]=1
            ;;
    esac
done < <(echo "$diff_content" | awk '
    /import.*from ["'\'']react["'\'']|import React/ { print "react"; next }
    /import.*from ["'\'']kea["'\'']|useValues|useActions/ { print "kea"; next }
    /from django|import django/ { print "django"; next }
    /from flask|import flask/ { print "flask"; next }
    /@SpringBootApplication|import org\.springframework/ { print "spring"; next }
    /use actix_web|use rocket/ { print "actix / rocket"; next }
' | sort -u)

# Convert frameworks map to array
frameworks=("${!seen_frameworks[@]}")

# Convert arrays to JSON format
languages_json=$(printf '%s\n' "${languages[@]}" | jq -R . | jq -s . || echo "[]")
frameworks_json=$(printf '%s\n' "${frameworks[@]}" | jq -R . | jq -s . || echo "[]")
extensions_json=$(printf '%s\n' "${extensions[@]}" | jq -R . | jq -s . || echo "[]")

# Debug: Save detected patterns
# Use safe array handling pattern for set -u compatibility
lang_count=0
framework_count=0
ext_count=0
if [ -n "${languages[@]+"${languages[@]}"}" ]; then
    lang_count="${#languages[@]}"
    debug_save "03-language-detection" "detected-languages.txt" "$(printf '%s\n' "${languages[@]}")"
else
    debug_save "03-language-detection" "detected-languages.txt" "(no languages detected)"
fi
if [ -n "${frameworks[@]+"${frameworks[@]}"}" ]; then
    framework_count="${#frameworks[@]}"
    debug_save "03-language-detection" "detected-frameworks.txt" "$(printf '%s\n' "${frameworks[@]}")"
else
    debug_save "03-language-detection" "detected-frameworks.txt" "(no frameworks detected)"
fi
if [ -n "${extensions[@]+"${extensions[@]}"}" ]; then
    ext_count="${#extensions[@]}"
    debug_save "03-language-detection" "detected-extensions.txt" "$(printf '%s\n' "${extensions[@]}")"
else
    debug_save "03-language-detection" "detected-extensions.txt" "(no extensions detected)"
fi

debug_stats "03-language-detection" \
    languages_count "$lang_count" \
    frameworks_count "$framework_count" \
    extensions_count "$ext_count" \
    has_frontend "$has_frontend"

# Output JSON
output=$(
    cat << EOF
{
    "languages": $languages_json,
    "frameworks": $frameworks_json,
    "has_frontend": $has_frontend,
    "file_extensions": $extensions_json
}
EOF
)

debug_save_json "03-language-detection" "output.json" <<< "$output"
debug_time "03-language-detection" "end"

echo "$output"
