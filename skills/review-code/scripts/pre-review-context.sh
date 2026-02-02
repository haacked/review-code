#!/usr/bin/env bash
# pre-review-context.sh - Extract file metadata from diff for context gathering
# Requires: bash 4.0+ for associative arrays
#
# Usage:
#   git diff | pre-review-context.sh
#   or
#   pre-review-context.sh < diff.txt
#
# Output (JSON):
#   {
#     "modified_files": [
#       {
#         "path": "backend/api/auth.py",
#         "type": "source",
#         "language": "python",
#         "is_test": false,
#         "likely_test_path": "backend/api/test_auth.py"
#       }
#     ],
#     "file_count": 5,
#     "has_tests": true,
#     "has_migrations": false,
#     "has_config": false
#   }

set -euo pipefail

# Read diff from stdin
diff_content=$(cat)

# Extract file paths from diff
# Format: +++ b/path/to/file.ext
file_paths=$(echo "${diff_content}" | { grep -E "^\+\+\+ b/" || test $? = 1; } | sed 's/^+++ b\///')

# Detect file type and generate metadata
# Output newline-delimited JSON, capture for single jq processing
file_metadata_ndjson=$(while IFS= read -r file; do
    [[ -z "${file}" ]] && continue

    # Extract components
    basename=$(basename "${file}")
    dirname=$(dirname "${file}")
    ext="${file##*.}"

    # Determine language
    language="unknown"
    case ".${ext}" in
        .py) language="python" ;;
        .ts | .tsx) language="typescript" ;;
        .js | .jsx) language="javascript" ;;
        .rs) language="rust" ;;
        .go) language="go" ;;
        .rb) language="ruby" ;;
        .php) language="php" ;;
        .java) language="java" ;;
        .kt) language="kotlin" ;;
        .swift) language="swift" ;;
        .cs) language="csharp" ;;
        .ex | .exs) language="elixir" ;;
        .sql) language="sql" ;;
        .sh) language="bash" ;;
        *) language="unknown" ;;
    esac

    # Determine file type
    file_type="source"
    is_test=false
    likely_test_path=""

    # Check if it's a test file
    if [[ "${basename}" =~ ^test_ ]] \
        || [[ "${basename}" =~ _test\. ]] \
        || [[ "${basename}" =~ _spec\. ]] \
        || [[ "${basename}" =~ \.test\. ]] \
        || [[ "${basename}" =~ \.spec\. ]] \
        || [[ "${dirname}" =~ /__tests__$ ]] \
        || [[ "${dirname}" =~ /tests?$ ]] \
        || [[ "${dirname}" =~ /specs?$ ]]; then
        file_type="test"
        is_test=true
    fi

    # Check for migrations
    if [[ "${dirname}" =~ /migrations?$ ]] \
        || [[ "${basename}" =~ ^[0-9]{4}_.*\.(sql|py)$ ]]; then
        file_type="migration"
    fi

    # Check for config files
    if [[ "${basename}" =~ \.(json|yaml|yml|toml|ini|env|config)$ ]] \
        || [[ "${basename}" =~ ^(package\.json|tsconfig|Cargo\.toml|pyproject\.toml|setup\.py|Gemfile|composer\.json)$ ]]; then
        file_type="config"
    fi

    # Generate likely test path if this is a source file
    if [[ "${is_test}" = false ]] && [[ "${file_type}" = "source" ]]; then
        case "${language}" in
            python)
                # Python: test_foo.py or foo_test.py in tests/ or same dir
                test_name="test_${basename}"
                if [[ -d "${dirname}/tests" ]]; then
                    likely_test_path="${dirname}/tests/${test_name}"
                else
                    likely_test_path="${dirname}/${test_name}"
                fi
                ;;
            typescript | javascript)
                # TS/JS: foo.test.ts or __tests__/foo.test.ts
                test_name="${basename%.*}.test.${ext}"
                if [[ -d "${dirname}/__tests__" ]]; then
                    likely_test_path="${dirname}/__tests__/${test_name}"
                else
                    likely_test_path="${dirname}/${test_name}"
                fi
                ;;
            rust)
                # Rust: typically in same file or tests/ module
                likely_test_path="${dirname}/tests/${basename}"
                ;;
            go)
                # Go: foo_test.go in same dir
                test_name="${basename%.*}_test.go"
                likely_test_path="${dirname}/${test_name}"
                ;;
            *)
                # Generic: test_foo or foo_test in tests/
                if [[ -d "${dirname}/tests" ]]; then
                    likely_test_path="${dirname}/tests/test_${basename}"
                fi
                ;;
        esac
    fi

    # Build newline-delimited JSON (one object per line)
    # Escape quotes and backslashes for JSON safety
    safe_path=$(printf '%s' "${file}" | sed 's/\\/\\\\/g; s/"/\\"/g')
    safe_test_path=$(printf '%s' "${likely_test_path}" | sed 's/\\/\\\\/g; s/"/\\"/g')

    printf '{"path":"%s","type":"%s","language":"%s","is_test":%s,"likely_test_path":"%s"}\n' \
        "${safe_path}" "${file_type}" "${language}" "${is_test}" "${safe_test_path}"

done <<< "${file_paths}")

# Build final JSON output with single jq call
# Convert newline-delimited JSON to array and calculate metadata
echo "${file_metadata_ndjson}" | jq -s '{
    modified_files: .,
    file_count: length,
    has_tests: (map(select(.is_test == true)) | length > 0),
    has_migrations: (map(select(.type == "migration")) | length > 0),
    has_config: (map(select(.type == "config")) | length > 0)
}'
