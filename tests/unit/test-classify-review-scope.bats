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

    cat > "$TMPDIR/session.json" <<ENDJSON
{
    "diff_tokens": $diff_tokens,
    "file_metadata": {
        "modified_files": $files_json,
        "file_count": $(echo "$files_json" | jq 'length')
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
