#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/classify-review-scope.sh"
    SESSION="$BATS_TEST_TMPDIR/session.json"
    CONTEXT="$BATS_TEST_TMPDIR/explorer.md"
    ALL_AREAS='["security","performance","correctness","maintainability","testing","compatibility","architecture","frontend","infra-config"]'
}

create_session() {
    local diff_tokens="${1:-100}"
    local files_json="${2:-[]}"
    local has_frontend="${3:-false}"
    jq -n --argjson tokens "$diff_tokens" --argjson files "$files_json" --argjson frontend "$has_frontend" '
        {diff_tokens: $tokens,
         file_metadata: {modified_files: $files, file_count: ($files | length)},
         languages: {has_frontend: $frontend}}
    ' > "$SESSION"
}

write_routing() {
    printf '# Explorer findings\n\n```review-routing\n%s\n```\n' "$1" > "$CONTEXT"
}

write_patch() {
    local path="$1"
    cat <<PATCH
diff --git a/$path b/$path
index 1111111..2222222 100644
--- a/$path
+++ b/$path
@@ -1 +1 @@
-old value
+new value
PATCH
}

assert_complete_decisions() {
    printf '%s' "$output" | jq -e --argjson areas "$ALL_AREAS" '
        (.agent_decisions | keys | sort) == ($areas | sort) and
        ([.agents[], .skipped_agents[]] | sort) == ($areas | sort) and
        (.reasoning | type == "string" and test("\\S")) and
        all(.agent_decisions[];
            (.decision == "run" or .decision == "skip") and
            (.reason | type == "string" and test("\\S")) and
            (.evidence | type == "array"))
    '
    printf '%s' "$output" | jq -e '
        . as $result |
        all(.agents[]; $result.agent_decisions[.].decision == "run") and
        all(.skipped_agents[]; $result.agent_decisions[.].decision == "skip")
    '
}

assert_all_run() {
    [ "$status" -eq 0 ]
    assert_complete_decisions
    printf '%s' "$output" | jq -e --argjson areas "$ALL_AREAS" '
        (.agents | sort) == ($areas | sort) and .skipped_agents == []
    '
}

assert_area_override() {
    local requested_area="$1"
    [ "$status" -eq 0 ]
    assert_complete_decisions
    printf '%s' "$output" | jq -e --arg area "$requested_area" --argjson areas "$ALL_AREAS" '
        (["correctness", $area] | unique) as $selected |
        .exploration_depth == "standard" and
        (.agents | sort) == $selected and
        (.skipped_agents | sort) == ($areas - $selected | sort) and
        (.reasoning | ascii_downcase | contains("explicit user scope override")) and
        .agent_decisions.correctness.decision == "run" and
        (.agent_decisions.correctness.reason | ascii_downcase | contains("correctness always runs")) and
        (.agent_decisions.correctness.reason | ascii_downcase | contains("explicit user scope override") | not) and
        (if $area == "correctness" then true else
            .agent_decisions[$area].decision == "run" and
            (.agent_decisions[$area].reason | ascii_downcase | contains("explicit user scope override"))
        end) and
        ([.skipped_agents[] as $skipped |
            .agent_decisions[$skipped].decision == "skip" and
            (.agent_decisions[$skipped].reason | ascii_downcase | contains("explicit user scope override")) and
            .agent_decisions[$skipped].evidence == []] | all)
    '
}

@test "metadata alone cannot skip specialists at any exploration depth" {
    for tokens in 100 500 1999 2000 4000; do
        for frontend in false true; do
            create_session "$tokens" '[{"path":"backend/api.py","type":"source"}]' "$frontend"
            run "$SCRIPT" "$SESSION"
            assert_all_run
            if [ "$tokens" -lt 500 ]; then
                expected=minimal
            elif [ "$tokens" -lt 2000 ]; then
                expected=standard
            else
                expected=thorough
            fi
            printf '%s' "$output" | jq -e --arg depth "$expected" '.exploration_depth == $depth'
        done
    done
}

@test "config test and migration files cannot skip specialists including deletions" {
    for type in config test migration; do
        for deleted in false true; do
            files=$(jq -nc --arg type "$type" --argjson deleted "$deleted" '[{path:"changed-file",type:$type,deleted:$deleted,is_infra_config:false}]')
            create_session 3000 "$files"
            run "$SCRIPT" "$SESSION"
            assert_all_run
        done
    done
}

@test "infra-only changes keep minimal exploration and all reviewers including deletions" {
    for tokens in 200 1500 3000; do
        for deleted in false true; do
            files=$(jq -nc --argjson deleted "$deleted" '[{path:"terraform/main.tf",type:"config",is_infra_config:true,deleted:$deleted}]')
            create_session "$tokens" "$files"
            run "$SCRIPT" "$SESSION"
            assert_all_run
            printf '%s' "$output" | jq -e '.exploration_depth == "minimal"'
        done
    done
}

@test "deleted source files prevent the infra-only exploration shortcut" {
    create_session 3000 '[
        {"path":"terraform/main.tf","type":"config","is_infra_config":true},
        {"path":"backend/old.py","type":"source","deleted":true}
    ]'
    run "$SCRIPT" "$SESSION"
    assert_all_run
    printf '%s' "$output" | jq -e '.exploration_depth == "thorough"'
}

@test "missing metadata or language flags cannot skip reviewers" {
    for session in '{}' '{"diff_tokens":100}' '{"diff_tokens":3000,"file_metadata":{"modified_files":[]}}' '{"file_metadata":{"modified_files":[{"path":"tests/test_api.py","type":"test"}]}}'; do
        printf '%s\n' "$session" > "$SESSION"
        run "$SCRIPT" "$SESSION"
        assert_all_run
    done
}

@test "only concrete negative evidence skips a specialist while uncertainty runs" {
    create_session
    write_routing '{"scope":"full","areas":{
        "performance":{"status":"not_applicable","evidence":[{"check":"Read backend/api.py and searched rg cache backend","result":"The diff changes only static response text and introduces no loops or I/O."}]},
        "security":{"status":"uncertain","evidence":[{"check":"Read the changed response handler","result":"Authorization is delegated to middleware outside the inspected files."}]},
        "frontend":{"status":"applies"}
    }}'
    run "$SCRIPT" "$SESSION" --explorer-context "$CONTEXT"
    [ "$status" -eq 0 ]
    assert_complete_decisions
    printf '%s' "$output" | jq -e '
        .skipped_agents == ["performance"] and
        .agent_decisions.security.decision == "run" and
        .agent_decisions.frontend.decision == "run" and
        .agent_decisions.compatibility.decision == "run" and
        .agent_decisions.performance.evidence == [{check:"Read backend/api.py and searched rg cache backend",result:"The diff changes only static response text and introduces no loops or I/O."}]
    '
}

@test "concrete negative explorer evidence can skip security" {
    create_session
    write_routing '{"scope":"full","areas":{
        "security":{"status":"not_applicable","evidence":[{"check":"Read every changed file and searched authentication and authorization call sites","result":"The diff changes only static response text and does not touch an authentication boundary."}]}
    }}'
    run "$SCRIPT" "$SESSION" --explorer-context "$CONTEXT"
    [ "$status" -eq 0 ]
    assert_complete_decisions
    printf '%s' "$output" | jq -e '
        .agent_decisions.security.decision == "skip" and
        .agent_decisions.security.evidence == [{check:"Read every changed file and searched authentication and authorization call sites",result:"The diff changes only static response text and does not touch an authentication boundary."}] and
        (.agents | index("security")) == null and
        .skipped_agents == ["security"]
    '
}

@test "correctness always runs even when every area has negative evidence" {
    create_session 3000
    routing=$(jq -nc --argjson areas "$ALL_AREAS" '{scope:"full",areas:($areas | map({key:.,value:{status:"not_applicable",evidence:[{check:"Read every changed file and searched its callers",result:"Only documentation text changed; no executable or deployment files changed."}]}}) | from_entries)}')
    write_routing "$routing"
    run "$SCRIPT" "$SESSION" --explorer-context "$CONTEXT"
    [ "$status" -eq 0 ]
    assert_complete_decisions
    printf '%s' "$output" | jq -e '
        .agents == ["correctness"] and
        (.skipped_agents | length) == 8 and
        (.agent_decisions.correctness.reason | ascii_downcase | contains("correctness always runs"))
    '
}

@test "every explicit area keeps correctness and the requested reviewer despite negative evidence" {
    create_session 3000
    routing=$(jq -nc --argjson areas "$ALL_AREAS" '{scope:"full",areas:($areas | map({key:.,value:{status:"not_applicable",evidence:[{check:"Read every changed file and searched its callers",result:"Only documentation text changed; no executable or deployment files changed."}]}}) | from_entries)}')
    write_routing "$routing"
    for area in $(jq -r '.[]' <<< "$ALL_AREAS"); do
        run "$SCRIPT" "$SESSION" --explorer-context "$CONTEXT" --area "$area"
        assert_area_override "$area"
    done
}

@test "every explicit area keeps correctness with missing or malformed explorer evidence" {
    create_session 3000
    write_routing '{'
    for area in $(jq -r '.[]' <<< "$ALL_AREAS"); do
        run "$SCRIPT" "$SESSION" --area "$area"
        assert_area_override "$area"
        for context_path in "$BATS_TEST_TMPDIR/missing.md" "$CONTEXT"; do
            run "$SCRIPT" "$SESSION" --explorer-context "$context_path" --area "$area"
            assert_area_override "$area"
        done
    done
}

@test "unknown explicit areas are rejected" {
    create_session
    run "$SCRIPT" "$SESSION" --area unknown
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid choice: 'unknown'"* ]]
}

@test "malformed area entries do not invalidate another area's concrete evidence" {
    create_session
    for entry in \
        'null' \
        '[]' \
        '"not_applicable"' \
        '{}' \
        '{"status":"unknown","evidence":[{"check":"Read all changed files","result":"No query changed."}]}' \
        '{"status":"not_applicable"}' \
        '{"status":"not_applicable","evidence":[]}' \
        '{"status":"not_applicable","evidence":"No query changed"}' \
        '{"status":"not_applicable","evidence":["No query changed"]}' \
        '{"status":"not_applicable","evidence":[{"check":"Read all changed files"}]}' \
        '{"status":"not_applicable","evidence":[{"check":"   ","result":"No query changed."}]}' \
        '{"status":"not_applicable","evidence":[{"check":"Read all changed files","result":"\t"}]}' \
        '{"status":"not_applicable","evidence":[{"check":1,"result":"No query changed."}]}' \
        '{"status":"not_applicable","evidence":[{"check":"Read all changed files","result":false}]}' \
        '{"status":"not_applicable","evidence":[{"check":"Read all changed files","result":"No query changed."},{}]}'; do
        routing=$(jq -nc --argjson entry "$entry" '{scope:"full",areas:{performance:$entry,architecture:{status:"not_applicable",evidence:[{check:"Read all changed files and their imports",result:"The diff introduces no components or dependencies."}]}}}')
        write_routing "$routing"
        run "$SCRIPT" "$SESSION" --explorer-context "$CONTEXT"
        [ "$status" -eq 0 ]
        assert_complete_decisions
        printf '%s' "$output" | jq -e '.skipped_agents == ["architecture"] and .agent_decisions.performance.decision == "run"'
    done
}

@test "uncertain and applicable areas run even when supplied negative-looking evidence" {
    create_session
    for area_status in uncertain applies; do
        routing=$(jq -nc --arg status "$area_status" '{scope:"full",areas:{security:{status:$status,evidence:[{check:"Read all changed files",result:"No authorization change was found."}]}}}')
        write_routing "$routing"
        run "$SCRIPT" "$SESSION" --explorer-context "$CONTEXT"
        assert_all_run
    done
}

@test "missing unreadable and unstructured explorer context fail open" {
    create_session
    for context_path in "$BATS_TEST_TMPDIR/missing.md" "$BATS_TEST_TMPDIR"; do
        run "$SCRIPT" "$SESSION" --explorer-context "$context_path"
        assert_all_run
    done
    printf '%s\n' 'Performance: not applicable. No query changed.' > "$CONTEXT"
    run "$SCRIPT" "$SESSION" --explorer-context "$CONTEXT"
    assert_all_run
}

@test "missing closed routing fence and multiple routing fences fail open" {
    create_session
    routing='{"scope":"full","areas":{"performance":{"status":"not_applicable","evidence":[{"check":"Read all changed files","result":"No query changed."}]}}}'
    printf '```review-routing\n%s\n' "$routing" > "$CONTEXT"
    run "$SCRIPT" "$SESSION" --explorer-context "$CONTEXT"
    assert_all_run
    write_routing "$routing"
    printf '\n```review-routing\n%s\n```\n' "$routing" >> "$CONTEXT"
    run "$SCRIPT" "$SESSION" --explorer-context "$CONTEXT"
    assert_all_run
    write_routing "$routing"
    printf '\n```review-routing\n%s\n' "$routing" >> "$CONTEXT"
    run "$SCRIPT" "$SESSION" --explorer-context "$CONTEXT"
    assert_all_run
}

@test "routing examples nested in another fence fail open" {
    create_session
    cat > "$CONTEXT" << 'EOF'
````markdown
```review-routing
{"scope":"full","areas":{"performance":{"status":"not_applicable","evidence":[{"check":"Read all changed files","result":"No query changed."}]}}}
```
````
EOF
    run "$SCRIPT" "$SESSION" --explorer-context "$CONTEXT"
    assert_all_run
}

@test "malformed JSON invalid scope and invalid top-level data fail open" {
    create_session
    for routing in \
        '{' \
        'null' \
        '[]' \
        '{"areas":{"performance":{"status":"not_applicable","evidence":[{"check":"Read all changed files","result":"No query changed."}]}}}' \
        '{"scope":"delta","areas":{"performance":{"status":"not_applicable","evidence":[{"check":"Read all changed files","result":"No query changed."}]}}}' \
        '{"scope":true,"areas":{}}' \
        '{"scope":"full"}' \
        '{"scope":"full","areas":[]}' \
        '{"scope":"full","areas":null}'; do
        write_routing "$routing"
        run "$SCRIPT" "$SESSION" --explorer-context "$CONTEXT"
        assert_all_run
    done
}

@test "multiple routing blocks remain ambiguous across Markdown fence styles" {
    create_session
    routing='{"scope":"full","areas":{"performance":{"status":"not_applicable","evidence":[{"check":"Read all changed files","result":"Only documentation prose changed."}]}}}'
    for fence in ' ```' '````' '~~~'; do
        write_routing "$routing"
        printf '\n%sreview-routing\n{"scope":"full","areas":{"performance":{"status":"uncertain"}}}\n%s\n' "$fence" "$fence" >> "$CONTEXT"
        run "$SCRIPT" "$SESSION" --explorer-context "$CONTEXT"
        assert_all_run
    done
}

@test "duplicate JSON keys at every routing level fail open" {
    create_session
    for routing in \
        '{"scope":"delta","scope":"full","areas":{"performance":{"status":"not_applicable","evidence":[{"check":"Read all changed files","result":"No query changed."}]}}}' \
        '{"scope":"full","areas":{"performance":{"status":"uncertain"},"performance":{"status":"not_applicable","evidence":[{"check":"Read all changed files","result":"No query changed."}]}}}' \
        '{"scope":"full","areas":{"performance":{"status":"uncertain","status":"not_applicable","evidence":[{"check":"Read all changed files","result":"No query changed."}]}}}' \
        '{"scope":"full","areas":{"performance":{"status":"not_applicable","evidence":[{"check":"Read all changed files","result":"Unclear","result":"No query changed."}]}}}'; do
        write_routing "$routing"
        run "$SCRIPT" "$SESSION" --explorer-context "$CONTEXT"
        assert_all_run
    done
}

@test "classification preserves the session and exact evidence with special characters" {
    create_session 1500 '[{"path":"backend/api.py","type":"source"}]'
    cp "$SESSION" "$BATS_TEST_TMPDIR/session-before.json"
    routing=$(jq -nc '{scope:"full",areas:{performance:{status:"not_applicable",evidence:[{check:"Read backend/api.py and searched rg \"SELECT|cache\" backend",result:"Only the label \"queue depth\" changed.\nNo runtime behavior changed."},{check:"Read callers in backend/routes.py",result:"The same constant response path is used."}]}}}')
    write_routing "$routing"
    run "$SCRIPT" "$SESSION" --explorer-context "$CONTEXT"
    [ "$status" -eq 0 ]
    assert_complete_decisions
    printf '%s' "$output" | jq -e --argjson routing "$routing" '
        .agent_decisions.performance.decision == "skip" and
        .agent_decisions.performance.evidence == $routing.areas.performance.evidence
    '
    cmp "$SESSION" "$BATS_TEST_TMPDIR/session-before.json"
}

@test "diff override sizes exploration from the reviewed patch without changing evidence routing" {
    create_session 50000 '[{"path":"large/full.py","type":"source"}]'
    write_patch tests/test_delta.py > "$BATS_TEST_TMPDIR/delta.patch"
    write_routing '{"scope":"full","areas":{"frontend":{"status":"not_applicable","evidence":[{"check":"Read the delta and searched its changed symbols","result":"The delta changes one backend test and has no UI consumer."}]}}}'

    run "$SCRIPT" "$SESSION" --diff-file "$BATS_TEST_TMPDIR/delta.patch" --explorer-context "$CONTEXT"

    [ "$status" -eq 0 ]
    assert_complete_decisions
    printf '%s' "$output" | jq -e '
        .exploration_depth == "minimal" and
        .skipped_agents == ["frontend"] and
        (.agents | index("correctness")) != null and
        .agent_decisions.frontend.evidence[0].result == "The delta changes one backend test and has no UI consumer."
    '
}
