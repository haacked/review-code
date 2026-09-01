#!/usr/bin/env bats
# Unit tests for classify-review-scope.sh

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/classify-review-scope.sh"
    TMPDIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMPDIR"
}

# Helper to create a session file with given parameters
create_session() {
    local diff_tokens="${1:-100}"
    local files_json="${2:-[]}"
    local has_frontend="${3:-false}"
    local deleted_count="${4:-0}"

    cat > "$TMPDIR/session.json" <<ENDJSON
{
    "diff_tokens": $diff_tokens,
    "file_metadata": {
        "modified_files": $files_json,
        "file_count": $(echo "$files_json" | jq 'length'),
        "deleted_file_count": $deleted_count
    },
    "languages": {
        "has_frontend": $has_frontend
    }
}
ENDJSON
    echo "$TMPDIR/session.json"
}

@test "classify-review-scope.sh exists and is executable" {
    [ -x "$SCRIPT" ]
}

@test "infra-config-only selects infra-config agent with minimal exploration" {
    session=$(create_session 200 '[
        {"path":"argocd/contour-ingress/values/values.prod-us.yaml","type":"config","is_infra_config":true,"is_test":false},
        {"path":"argocd/contour-ingress/values/values.prod-eu.yaml","type":"config","is_infra_config":true,"is_test":false},
        {"path":"argocd/contour-ingress/values/values.dev.yaml","type":"config","is_infra_config":true,"is_test":false}
    ]')

    result=$("$SCRIPT" "$session")
    echo "$result" | jq -e '.exploration_depth == "minimal"'
    echo "$result" | jq -e '.agents == ["infra-config"]'
    echo "$result" | jq -e '.reasoning | contains("Infra-config-only")'
}

@test "regular config-only still selects correctness + compatibility" {
    session=$(create_session 200 '[
        {"path":"package.json","type":"config","is_infra_config":false,"is_test":false},
        {"path":"tsconfig.json","type":"config","is_infra_config":false,"is_test":false}
    ]')

    result=$("$SCRIPT" "$session")
    echo "$result" | jq -e '.agents | contains(["correctness", "compatibility"])'
    echo "$result" | jq -e '.agents | contains(["infra-config"]) | not'
}

@test "config-only selects correctness + compatibility above 2000 diff tokens" {
    session=$(create_session 3000 '[
        {"path":"package.json","type":"config","is_infra_config":false,"is_test":false},
        {"path":"tsconfig.json","type":"config","is_infra_config":false,"is_test":false}
    ]')

    result=$("$SCRIPT" "$session")
    echo "$result" | jq -e '.agents == ["correctness", "compatibility"]'
}

@test "test-only selects testing + correctness + maintainability above 2000 diff tokens" {
    session=$(create_session 3000 '[
        {"path":"tests/test_api.py","type":"test","is_infra_config":false,"is_test":true},
        {"path":"tests/test_web.py","type":"test","is_infra_config":false,"is_test":true}
    ]')

    result=$("$SCRIPT" "$session")
    echo "$result" | jq -e '.agents == ["testing", "correctness", "maintainability"]'
}

@test "migration-only selects correctness + compatibility + security above 2000 diff tokens" {
    session=$(create_session 3000 '[
        {"path":"migrations/001_add_index.py","type":"migration","is_infra_config":false,"is_test":false},
        {"path":"migrations/002_backfill.py","type":"migration","is_infra_config":false,"is_test":false}
    ]')

    result=$("$SCRIPT" "$session")
    echo "$result" | jq -e '.agents == ["correctness", "compatibility", "security"]'
}

@test "mixed infra + source includes infra-config agent" {
    session=$(create_session 800 '[
        {"path":"argocd/service/values/values.yaml","type":"config","is_infra_config":true,"is_test":false},
        {"path":"backend/api.py","type":"source","is_infra_config":false,"is_test":false}
    ]')

    result=$("$SCRIPT" "$session")
    echo "$result" | jq -e '.agents | contains(["infra-config"])'
    echo "$result" | jq -e '.agents | contains(["correctness"])'
}

@test "large diff with infra files includes infra-config alongside all agents" {
    session=$(create_session 3000 '[
        {"path":"argocd/service/values/values.yaml","type":"config","is_infra_config":true,"is_test":false},
        {"path":"backend/api.py","type":"source","is_infra_config":false,"is_test":false},
        {"path":"backend/models.py","type":"source","is_infra_config":false,"is_test":false}
    ]')

    result=$("$SCRIPT" "$session")
    echo "$result" | jq -e '.agents | contains(["infra-config"])'
    echo "$result" | jq -e '.agents | contains(["correctness", "security"])'
    echo "$result" | jq -e '.exploration_depth == "thorough"'
}

@test "large infra-config change with a deleted source file uses all core agents plus infra-config" {
    session=$(create_session 3000 '[
        {"path":"argocd/service/values/values.prod-us.yaml","type":"config","is_infra_config":true,"is_test":false},
        {"path":"argocd/service/values/values.prod-eu.yaml","type":"config","is_infra_config":true,"is_test":false}
    ]' false 1)

    result=$("$SCRIPT" "$session")
    echo "$result" | jq -e '.agents == ["security", "performance", "correctness", "maintainability", "testing", "compatibility", "architecture", "infra-config"]'
    echo "$result" | jq -e '.reasoning | contains("running all agents")'
}

@test "infra-config-only forces minimal exploration even for larger diffs (standard range)" {
    session=$(create_session 1500 '[
        {"path":"terraform/main.tf","type":"config","is_infra_config":true,"is_test":false},
        {"path":"terraform/variables.tf","type":"config","is_infra_config":true,"is_test":false},
        {"path":"terraform/outputs.tf","type":"config","is_infra_config":true,"is_test":false}
    ]')

    result=$("$SCRIPT" "$session")
    echo "$result" | jq -e '.exploration_depth == "minimal"'
    echo "$result" | jq -e '.agents == ["infra-config"]'
}

@test "infra-config-only still selects infra-config agent for large diffs (>= 2000 tokens)" {
    session=$(create_session 3000 '[
        {"path":"argocd/contour-ingress/values/values.prod-us.yaml","type":"config","is_infra_config":true,"is_test":false},
        {"path":"argocd/contour-ingress/values/values.prod-eu.yaml","type":"config","is_infra_config":true,"is_test":false},
        {"path":"argocd/contour-ingress/values/values.dev.yaml","type":"config","is_infra_config":true,"is_test":false}
    ]')

    result=$("$SCRIPT" "$session")
    echo "$result" | jq -e '.agents == ["infra-config"]'
    echo "$result" | jq -e '.agents | contains(["security"]) | not'
}

@test "infra-config not in skipped_agents when no infra files present" {
    session=$(create_session 200 '[
        {"path":"backend/api.py","type":"source","is_infra_config":false,"is_test":false}
    ]')

    result=$("$SCRIPT" "$session")
    # infra-config should not appear in skipped when there are no infra files (follows frontend pattern)
    echo "$result" | jq -e '.skipped_agents | contains(["infra-config"]) | not'
}

@test "no files with is_infra_config defaults to 0 count" {
    session=$(create_session 200 '[
        {"path":"backend/api.py","type":"source","is_test":false}
    ]')

    result=$("$SCRIPT" "$session")
    # Should not crash and should not select infra-config
    echo "$result" | jq -e '.agents | contains(["infra-config"]) | not'
}

@test "missing languages block still classifies from the file counts" {
    # The `// false` default on .languages.has_frontend is what keeps this a false
    # field. Without it jq emits an empty @tsv field, which read swallows, shifting
    # every count after it by one. This fixture is test-only, so a shifted read
    # reports zero test files and falls through to the generic small-diff agents.
    session_file="$TMPDIR/session.json"
    cat > "$session_file" <<'ENDJSON'
{
    "diff_tokens": 200,
    "file_metadata": {
        "modified_files": [
            {"path":"tests/test_api.py","type":"test","is_test":true,"is_infra_config":false},
            {"path":"tests/test_web.py","type":"test","is_test":true,"is_infra_config":false}
        ],
        "file_count": 2
    }
}
ENDJSON

    result=$("$SCRIPT" "$session_file")
    echo "$result" | jq -e '.agents == ["testing", "correctness", "maintainability"]'
}

@test "infra-config + deleted source file does not use infra-config-only shortcut" {
    # Simulates: 2 infra-config files modified + 1 source file deleted.
    # pre-review-context.sh only captures modified files, so deleted_file_count must be
    # set explicitly here to reflect what the script would produce from the diff.
    session_file="$TMPDIR/session.json"
    cat > "$session_file" <<ENDJSON
{
    "diff_tokens": 400,
    "file_metadata": {
        "modified_files": [
            {"path":"argocd/contour-ingress/values/values.prod-us.yaml","type":"config","is_infra_config":true,"is_test":false},
            {"path":"argocd/contour-ingress/values/values.prod-eu.yaml","type":"config","is_infra_config":true,"is_test":false}
        ],
        "file_count": 2,
        "deleted_file_count": 1
    },
    "languages": {
        "has_frontend": false
    }
}
ENDJSON

    result=$("$SCRIPT" "$session_file")
    # Should NOT select infra-config-only (deletions must be reviewed by core agents)
    echo "$result" | jq -e '.agents == ["infra-config"] | not'
    # Should include correctness to catch the source deletion
    echo "$result" | jq -e '.agents | contains(["correctness"])'
    # infra-config agent must still be included so the infra changes are reviewed
    echo "$result" | jq -e '.agents | contains(["infra-config"])'
}
