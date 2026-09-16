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
#         "deleted": false,
#         "type": "source",
#         "language": "python",
#         "is_test": false,
#         "is_infra_config": false,
#         "likely_test_path": "backend/api/test_auth.py"
#       }
#     ],
#     "file_count": 5,
#     "deleted_file_count": 0,
#     "has_tests": true,
#     "has_migrations": false,
#     "has_config": false,
#     "has_infra_config": false
#   }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=helpers/git-diff-paths.sh
source "${SCRIPT_DIR}/helpers/git-diff-paths.sh"

# Detect file type and generate metadata
# Git paths cannot contain NUL, so the parser uses it to preserve control characters.
while IFS= read -r -d '' deleted && IFS= read -r -d '' file; do
    [[ -z "${file}" ]] && continue

    # Extract components
    basename="${file##*/}"
    if [[ "${file}" == */* ]]; then
        dirname="${file%/*}"
    else
        dirname="."
    fi
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
    is_infra_config=false
    if [[ "${basename}" =~ \.(json|yaml|yml|toml|ini|env|config)$ ]] \
        || [[ "${basename}" =~ ^(package\.json|tsconfig|Cargo\.toml|pyproject\.toml|setup\.py|Gemfile|composer\.json)$ ]]; then
        file_type="config"
    fi

    # Files that are always both config and infra-config
    if [[ "${basename}" =~ \.(tf(vars)?|hcl)$ ]] \
        || [[ "${basename}" =~ ^(Dockerfile|Jenkinsfile)$ ]] \
        || [[ "${basename}" =~ ^(docker-compose)\.ya?ml$ ]] \
        || [[ "${basename}" =~ ^\.gitlab-ci\.yml$ ]]; then
        file_type="config"
        is_infra_config=true
    fi

    # Check remaining infra-config patterns for files already classified as config
    if [[ "${file_type}" = "config" ]] && [[ "${is_infra_config}" = false ]]; then
        # Detect by directory path patterns
        if [[ "${dirname}" =~ (^|/)(argocd|helm|charts|k8s|kubernetes|terraform|infra|deploy|kustomize)(/|$) ]] \
            || [[ "${dirname}" =~ (^|/)\.github/workflows(/|$) ]]; then
            is_infra_config=true
        fi
        # Detect by filename patterns (Helm/K8s specific)
        if [[ "${basename}" =~ ^(Chart|values|helmfile|kustomization)\.ya?ml$ ]]; then
            is_infra_config=true
        fi
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

    printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
        "${file}" "${deleted}" "${file_type}" "${language}" "${is_test}" "${is_infra_config}" "${likely_test_path}"
done < <(git_diff_paths) | jq -Rs '
        split("\u0000")[:-1]
        | [range(0; length; 7) as $i | {
            path: .[$i],
            deleted: (.[($i + 1)] == "true"),
            type: .[$i + 2],
            language: .[$i + 3],
            is_test: (.[($i + 4)] == "true"),
            is_infra_config: (.[($i + 5)] == "true"),
            likely_test_path: .[$i + 6]
        }]
        | {
            modified_files: ., file_count: length,
            deleted_file_count: (map(select(.deleted)) | length),
            has_tests: any(.is_test),
            has_migrations: any(.type == "migration"),
            has_config: any(.type == "config"),
            has_infra_config: any(.is_infra_config)
        }
    '
