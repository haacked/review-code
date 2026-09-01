#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CONTRACT="$PROJECT_ROOT/skills/review-code/scripts/finding-comment-contract.py"
    FIXTURE="$PROJECT_ROOT/tests/fixtures/finding-comments/pr-90970.json"
    INPUT="$BATS_TEST_TMPDIR/input.json"
    COMPOSED="$BATS_TEST_TMPDIR/composed.json"
    VERDICTS="$BATS_TEST_TMPDIR/verdicts.json"
}

write_finding() {
    local description_filter="${1:-null}"
    jq --argjson description "$description_filter" '[{
        id: 90970,
        severity: "blocking",
        location: "rust/feature-flags/src/flags/flag_matching.rs:262",
        file: "rust/feature-flags/src/flags/flag_matching.rs",
        line: 262,
        description: $description,
        proposed_fix: "```suggestion\nself.filter_type == FilterType::Person && overrides.contains(&self.key)\n```",
        facts: .facts
    }]' "$FIXTURE" > "$INPUT"
}

write_verdict() {
    local verdict="$1"
    local inference_required="$2"
    local problem="$3"
    local mechanism="$4"
    jq -n \
        --arg verdict "$verdict" \
        --argjson inference_required "$inference_required" \
        --argjson problem "$problem" \
        --argjson mechanism "$mechanism" \
        '[{
            id: 90970,
            coverage: {
                problem: $problem,
                trigger: true,
                mechanism: $mechanism,
                result: true,
                requested_change: true,
                regression_case: true
            },
            inference_required: $inference_required,
            verdict: $verdict,
            notes: (if $verdict == "PASS" then "" else "The causal relationship is not explicit." end)
        }]' > "$VERDICTS"
}

@test "finding contract: requires structured causal facts for blocking findings" {
    jq '[{
        id: 90970,
        severity: "blocking",
        location: "flag_matching.rs:262",
        file: "flag_matching.rs",
        line: 262,
        description: .bad_description,
        proposed_fix: null,
        facts: {problem: null, trigger: null, mechanism: [], result: null, requested_change: null, regression_case: null, regression_rationale: null}
    }]' "$FIXTURE" > "$INPUT"

    run "$CONTRACT" compose "$INPUT"

    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '.findings | length')" -eq 0 ]
    [ "$(echo "$output" | jq '.withheld | length')" -eq 1 ]
    [ "$(echo "$output" | jq -r '.withheld[0].publishable')" = "false" ]
    [ "$(echo "$output" | jq -r '.withheld[0].reasons | length')" -ge 4 ]
}

@test "finding contract: an empty description fails closed instead of synthesizing public prose" {
    write_finding null

    run "$CONTRACT" compose "$INPUT"

    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '.findings | length')" -eq 0 ]
    [ "$(echo "$output" | jq '.withheld | length')" -eq 1 ]
    [ "$(echo "$output" | jq -r '.withheld[0].quality_state')" = "invalid_contract" ]
    [ "$(echo "$output" | jq -r '.withheld[0].reasons[] | select(. == "description is required")')" = "description is required" ]
}

@test "finding contract: a complete positive finding passes with its body unchanged" {
    desired=$(jq -c '.desired_description' "$FIXTURE")
    write_finding "$desired"
    "$CONTRACT" compose "$INPUT" > "$COMPOSED"
    write_verdict PASS false true true

    run "$CONTRACT" gate "$COMPOSED" "$VERDICTS"

    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.findings[0].description')" = "$(jq -r '.desired_description' "$FIXTURE")" ]
    [ "$(echo "$output" | jq -r '.findings[0].publishable')" = "true" ]
    [ "$(echo "$output" | jq -r '.findings[0].quality_state')" = "passed" ]
    [ "$(echo "$output" | jq '.rewrites_needed | length')" -eq 0 ]
}

@test "finding contract: requires separate file and line fields for automatic fixes" {
    desired=$(jq -c '.desired_description' "$FIXTURE")
    write_finding "$desired"
    jq '.[0] | del(.file, .line) | [.]' "$INPUT" > "$BATS_TEST_TMPDIR/missing-target.json"

    run "$CONTRACT" compose "$BATS_TEST_TMPDIR/missing-target.json"

    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '.findings | length')" -eq 0 ]
    [ "$(echo "$output" | jq '.withheld | length')" -eq 1 ]
    [ "$(echo "$output" | jq -r '.withheld[0].reasons[] | select(. == "file must be a non-empty string")')" = "file must be a non-empty string" ]
    [ "$(echo "$output" | jq -r '.withheld[0].reasons[] | select(. == "line must be a positive integer")')" = "line must be a positive integer" ]
}

@test "finding contract: file and line survive composition and the final gate" {
    desired=$(jq -c '.desired_description' "$FIXTURE")
    write_finding "$desired"
    "$CONTRACT" compose "$INPUT" > "$COMPOSED"
    write_verdict PASS false true true

    run "$CONTRACT" gate --final "$COMPOSED" "$VERDICTS"

    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.findings[0].file')" = "rust/feature-flags/src/flags/flag_matching.rs" ]
    [ "$(echo "$output" | jq -r '.findings[0].line')" -eq 262 ]
}

@test "finding contract: necessary facts written as unexplained mechanisms require a rewrite" {
    description=$(jq -c '.mechanisms_without_explanation' "$FIXTURE")
    write_finding "$description"
    "$CONTRACT" compose "$INPUT" > "$COMPOSED"
    write_verdict PASS true true false

    run "$CONTRACT" gate "$COMPOSED" "$VERDICTS"

    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '.findings | length')" -eq 0 ]
    [ "$(echo "$output" | jq '.rewrites_needed | length')" -eq 1 ]
    [ "$(echo "$output" | jq -r '.rewrites_needed[0].publishable')" = "false" ]
    [ "$(echo "$output" | jq -r '.rewrites_needed[0].quality_state')" = "rewrite_required" ]
    [ "$(echo "$output" | jq -r '.rewrites_needed[0].facts.problem')" = "$(jq -r '.facts.problem' "$FIXTURE")" ]
}

@test "finding contract: a consequence buried at the end requires a rewrite" {
    description=$(jq -c '.consequence_last' "$FIXTURE")
    write_finding "$description"
    "$CONTRACT" compose "$INPUT" > "$COMPOSED"
    write_verdict REWRITE true false true

    run "$CONTRACT" gate "$COMPOSED" "$VERDICTS"

    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '.rewrites_needed | length')" -eq 1 ]
    [ "$(echo "$output" | jq -r '.rewrites_needed[0].quality_state')" = "rewrite_required" ]
}

@test "finding contract: a clear comment remains byte-for-byte unchanged" {
    clear=$(jq -c '.already_clear' "$FIXTURE")
    jq --argjson description "$clear" '[{
        id: 2,
        severity: "blocking",
        location: "auth.py:45",
        file: "auth.py",
        line: 45,
        description: $description,
        proposed_fix: null,
        facts: {
            problem: "A request without an email reaches `validate_user` with `email` set to `None`.",
            trigger: null,
            mechanism: ["The function calls `.lower()` on that value, which raises `AttributeError` and returns a 500."],
            result: "The request returns a 500 instead of a validation response.",
            requested_change: "Check for `None` before normalizing the address.",
            regression_case: "Add a request test without an email.",
            regression_rationale: null
        }
    }]' "$FIXTURE" > "$INPUT"
    "$CONTRACT" compose "$INPUT" > "$COMPOSED"
    jq -n '[{
        id: 2,
        coverage: {problem: true, trigger: true, mechanism: true, result: true, requested_change: true, regression_case: true},
        inference_required: false,
        verdict: "PASS",
        notes: ""
    }]' > "$VERDICTS"

    run "$CONTRACT" gate "$COMPOSED" "$VERDICTS"

    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.findings[0].description')" = "$(jq -r '.already_clear' "$FIXTURE")" ]
}

@test "finding contract: malformed or missing gate output fails closed for publication" {
    desired=$(jq -c '.desired_description' "$FIXTURE")
    write_finding "$desired"
    "$CONTRACT" compose "$INPUT" > "$COMPOSED"
    echo '[]' > "$VERDICTS"

    run "$CONTRACT" gate "$COMPOSED" "$VERDICTS"

    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '.findings | length')" -eq 0 ]
    [ "$(echo "$output" | jq '.withheld | length')" -eq 1 ]
    [ "$(echo "$output" | jq -r '.withheld[0].quality_state')" = "gate_error" ]
    [ "$(echo "$output" | jq -r '.withheld[0].publishable')" = "false" ]
}

@test "finding contract: a final rewrite verdict is withheld instead of restoring the original" {
    bad=$(jq -c '.bad_description' "$FIXTURE")
    write_finding "$bad"
    "$CONTRACT" compose "$INPUT" > "$COMPOSED"
    write_verdict REWRITE true false false

    run "$CONTRACT" gate --final "$COMPOSED" "$VERDICTS"

    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '.findings | length')" -eq 0 ]
    [ "$(echo "$output" | jq '.rewrites_needed | length')" -eq 0 ]
    [ "$(echo "$output" | jq '.withheld | length')" -eq 1 ]
    [ "$(echo "$output" | jq -r '.withheld[0].quality_state')" = "rewrite_failed" ]
    [ "$(echo "$output" | jq -r '.withheld[0].description')" = "$(jq -r '.bad_description' "$FIXTURE")" ]
}

@test "finding contract: PASS cannot override missing causal coverage" {
    desired=$(jq -c '.desired_description' "$FIXTURE")
    write_finding "$desired"
    "$CONTRACT" compose "$INPUT" > "$COMPOSED"
    write_verdict PASS false true false

    run "$CONTRACT" gate "$COMPOSED" "$VERDICTS"

    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '.findings | length')" -eq 0 ]
    [ "$(echo "$output" | jq '.rewrites_needed | length')" -eq 1 ]
}

@test "finding contract: malformed finding ids are withheld instead of crashing the gate" {
    jq '[{
        id: {unexpected: true},
        severity: "blocking",
        location: "flag_matching.rs:262",
        file: "flag_matching.rs",
        line: 262,
        description: .desired_description,
        proposed_fix: null,
        facts: .facts
    }]' "$FIXTURE" > "$INPUT"

    run "$CONTRACT" compose "$INPUT"

    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '.findings | length')" -eq 0 ]
    [ "$(echo "$output" | jq '.withheld | length')" -eq 1 ]
    [ "$(echo "$output" | jq -r '.withheld[0].quality_state')" = "invalid_contract" ]
}

@test "finding contract: malformed verdict ids fail closed instead of crashing" {
    desired=$(jq -c '.desired_description' "$FIXTURE")
    write_finding "$desired"
    "$CONTRACT" compose "$INPUT" > "$COMPOSED"
    echo '[{"id":{"unexpected":true},"verdict":"PASS","coverage":{},"inference_required":false}]' > "$VERDICTS"

    run "$CONTRACT" gate "$COMPOSED" "$VERDICTS"

    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '.findings | length')" -eq 0 ]
    [ "$(echo "$output" | jq '.withheld | length')" -eq 1 ]
    [ "$(echo "$output" | jq -r '.withheld[0].quality_state')" = "gate_error" ]
}

@test "finding contract: duplicate finding ids are withheld as ambiguous" {
    jq -n '[1, 2] | map({
        id: 90970,
        severity: "blocking",
        location: "flag_matching.rs:262",
        file: "flag_matching.rs",
        line: 262,
        description: $fixture[0].desired_description,
        proposed_fix: null,
        facts: $fixture[0].facts
    })' --slurpfile fixture "$FIXTURE" > "$INPUT"

    run "$CONTRACT" compose "$INPUT"

    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '.findings | length')" -eq 0 ]
    [ "$(echo "$output" | jq '.withheld | length')" -eq 2 ]
    [ "$(echo "$output" | jq '[.withheld[].reasons[] | select(. == "id must be unique")] | length')" -eq 2 ]
}

@test "finding contract: accepts and preserves sequential ids for multiple findings" {
    jq -n '[1, 2] | map({
        id: .,
        severity: "blocking",
        location: "flag_matching.rs:262",
        file: "flag_matching.rs",
        line: 262,
        description: $fixture[0].desired_description,
        proposed_fix: null,
        facts: $fixture[0].facts
    })' --slurpfile fixture "$FIXTURE" > "$INPUT"

    run "$CONTRACT" compose "$INPUT"

    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -c '[.findings[].id]')" = '[1,2]' ]
    [ "$(echo "$output" | jq '.withheld | length')" -eq 0 ]
}

@test "finding contract: publication emits only safe draft comments and retains rejected findings" {
    local publication_input="$BATS_TEST_TMPDIR/publication-input.json"
    jq -n '{
        findings: [
            {id: 1, publishable: true, quality_state: "passed", file: "src/good.py", line: 12, side: "RIGHT", line_content: "return good", description: "`blocking`: Good body."},
            {id: 2, publishable: false, quality_state: "rewrite_required", file: "src/unclear.py", line: 8, description: "Opaque body."},
            {id: 3, publishable: true, quality_state: "passed", file: "", line: 0, description: "`blocking`: Missing target."}
        ],
        rewrites_needed: [],
        withheld: [
            {id: 4, publishable: false, quality_state: "gate_error", file: "src/gated.py", line: 4, description: "Rejected body."}
        ]
    }' > "$publication_input"

    run "$CONTRACT" publish "$publication_input"

    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -c '.comments')" = '[{"path":"src/good.py","line":12,"body":"`blocking`: Good body.","side":"RIGHT","line_content":"return good"}]' ]
    [ "$(echo "$output" | jq '.unmapped_comments | length')" -eq 0 ]
    [ "$(echo "$output" | jq -c '[.withheld[].id] | sort')" = '[2,3,4]' ]
    [ "$(echo "$output" | jq -r '.withheld[] | select(.id == 3) | .quality_state')" = "publication_failed" ]
}

@test "finding contract: publication emits zero comments when every finding is withheld" {
    local publication_input="$BATS_TEST_TMPDIR/all-withheld.json"
    jq -n '{
        findings: [],
        rewrites_needed: [],
        withheld: [
            {id: 1, publishable: false, quality_state: "gate_error", file: "src/gated.py", line: 4, description: "Rejected body."}
        ]
    }' > "$publication_input"

    run "$CONTRACT" publish "$publication_input"

    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '.comments | length')" -eq 0 ]
    [ "$(echo "$output" | jq '.unmapped_comments | length')" -eq 0 ]
    [ "$(echo "$output" | jq '.withheld | length')" -eq 1 ]
}

@test "finding contract: draft assembly copies only canonical publication bodies" {
    local draft_input="$BATS_TEST_TMPDIR/draft-input.json"
    jq -n '{
        publication: {
            comments: [
                {path: "src/good.py", line: 12, body: "Canonical body."},
                {path: "src/covered.py", line: 8, body: "Covered body."}
            ],
            unmapped_comments: []
        },
        selected_indices: [0],
        mappings: [
            {path: "src/good.py", line: 12, side: "RIGHT", body: "Injected body."}
        ],
        context: {
            owner: "org",
            repo: "repo",
            pr_number: 42,
            reviewer_username: "reviewer",
            summary: "One issue inline."
        }
    }' > "$draft_input"

    run "$CONTRACT" draft "$draft_input"

    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.comments[0].body')" = "Canonical body." ]
    [ "$(echo "$output" | jq '.comments | length')" -eq 1 ]
    [ "$(echo "$output" | jq -r '.owner')" = "org" ]
}

@test "finding contract: draft assembly defaults to every safe comment" {
    local draft_input="$BATS_TEST_TMPDIR/draft-all.json"
    jq -n '{
        publication: {
            comments: [
                {path: "src/one.py", line: 1, body: "One."},
                {path: "src/two.py", line: 2, body: "Two."}
            ],
            unmapped_comments: []
        },
        mappings: [
            {path: "src/one.py", line: 1, side: "RIGHT"},
            {path: "src/two.py", line: 2, side: "RIGHT"}
        ],
        context: {
            owner: "org",
            repo: "repo",
            pr_number: 42,
            reviewer_username: "reviewer"
        }
    }' > "$draft_input"

    run "$CONTRACT" draft "$draft_input"

    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -c '[.comments[].body]')" = '["One.","Two."]' ]
}

@test "finding contract: draft assembly rejects unknown candidate indices" {
    local draft_input="$BATS_TEST_TMPDIR/draft-invalid.json"
    jq -n '{
        publication: {comments: [{path: "src/one.py", line: 1, body: "One."}], unmapped_comments: []},
        selected_indices: [1],
        mappings: [],
        context: {owner: "org", repo: "repo", pr_number: 42, reviewer_username: "reviewer"}
    }' > "$draft_input"

    run "$CONTRACT" draft "$draft_input"

    [ "$status" -ne 0 ]
    [[ "$output" == *"selected index is outside the publication comments array"* ]]
}

@test "finding contract: draft assembly keeps unmappable canonical bodies in the summary" {
    local draft_input="$BATS_TEST_TMPDIR/draft-unmapped.json"
    jq -n '{
        publication: {
            comments: [{path: "src/one.py", line: 1, body: "Canonical body."}],
            unmapped_comments: [{description: "Existing safe note."}]
        },
        selected_indices: [0],
        mappings: [{path: "src/one.py", line: 1, error: "line not in diff"}],
        context: {owner: "org", repo: "repo", pr_number: 42, reviewer_username: "reviewer"}
    }' > "$draft_input"

    run "$CONTRACT" draft "$draft_input"

    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '.comments | length')" -eq 0 ]
    [ "$(echo "$output" | jq -c '[.unmapped_comments[].description]')" = '["Existing safe note.","Canonical body."]' ]
}

@test "finding contract: append draft assembly derives touched paths from the delta" {
    local draft_input="$BATS_TEST_TMPDIR/draft-append.json"
    local delta_diff="$BATS_TEST_TMPDIR/delta.patch"
    cat > "$delta_diff" <<'EOF'
diff --git a/src/old.py b/src/old.py
index 1111111..2222222 100644
--- a/src/old.py
+++ b/src/old.py
@@ -1 +1 @@
-old
+new
EOF
    jq -n --arg diff "$delta_diff" '{
        publication: {comments: [], unmapped_comments: []},
        selected_indices: [],
        mappings: [],
        context: {
            owner: "org",
            repo: "repo",
            pr_number: 42,
            reviewer_username: "reviewer",
            append: true,
            original_diff_path: $diff
        }
    }' > "$draft_input"

    run "$CONTRACT" draft "$draft_input"

    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -c '.delta_paths')" = '["src/old.py"]' ]
}

@test "finding contract: rename deltas mark both paths as touched" {
    local draft_input="$BATS_TEST_TMPDIR/draft-rename.json"
    local delta_diff="$BATS_TEST_TMPDIR/rename.patch"
    cat > "$delta_diff" <<'EOF'
diff --git a/src/old.py b/src/new.py
similarity index 100%
rename from src/old.py
rename to src/new.py
EOF
    jq -n --arg diff "$delta_diff" '{
        publication: {comments: [], unmapped_comments: []},
        selected_indices: [],
        mappings: [],
        context: {
            owner: "org",
            repo: "repo",
            pr_number: 42,
            reviewer_username: "reviewer",
            append: true,
            original_diff_path: $diff
        }
    }' > "$draft_input"

    run "$CONTRACT" draft "$draft_input"

    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -c '.delta_paths')" = '["src/old.py","src/new.py"]' ]
}

@test "finding contract: copy deltas keep the source path untouched" {
    local draft_input="$BATS_TEST_TMPDIR/draft-copy.json"
    local delta_diff="$BATS_TEST_TMPDIR/copy.patch"
    cat > "$delta_diff" <<'EOF'
diff --git a/src/source.py b/src/copy.py
similarity index 100%
copy from src/source.py
copy to src/copy.py
EOF
    jq -n --arg diff "$delta_diff" '{
        publication: {comments: [], unmapped_comments: []},
        selected_indices: [],
        mappings: [],
        context: {
            owner: "org",
            repo: "repo",
            pr_number: 42,
            reviewer_username: "reviewer",
            append: true,
            original_diff_path: $diff
        }
    }' > "$draft_input"

    run "$CONTRACT" draft "$draft_input"

    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -c '.delta_paths')" = '["src/copy.py"]' ]
}

@test "finding contract: draft assembly extracts line content from the diff" {
    local draft_input="$BATS_TEST_TMPDIR/draft-line-content.json"
    local diff_file="$BATS_TEST_TMPDIR/line-content.patch"
    cat > "$diff_file" <<'EOF'
diff --git a/src/good.py b/src/good.py
index 1111111..2222222 100644
--- a/src/good.py
+++ b/src/good.py
@@ -11,1 +11,2 @@
 old
+return good
EOF
    jq -n --arg diff "$diff_file" '{
        publication: {
            comments: [{path: "src/good.py", line: 12, body: "Canonical body."}],
            unmapped_comments: []
        },
        selected_indices: [0],
        mappings: [{path: "src/good.py", line: 12, side: "RIGHT"}],
        context: {
            owner: "org",
            repo: "repo",
            pr_number: 42,
            reviewer_username: "reviewer",
            original_diff_path: $diff
        }
    }' > "$draft_input"

    run "$CONTRACT" draft "$draft_input"

    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.comments[0].line_content')" = "return good" ]
}
