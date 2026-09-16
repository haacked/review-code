#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPTS="$PROJECT_ROOT/skills/review-code/scripts"
    export CLAUDE_SESSION_DIR="$BATS_TEST_TMPDIR/sessions"
    ARTIFACTS="$CLAUDE_SESSION_DIR/review-code/artifacts-deletions"
    SESSION_FILE="$CLAUDE_SESSION_DIR/review-code/review-code-12345-1234567890.json"
    mkdir -p "$ARTIFACTS"
}

prepare_session() {
    "$SCRIPTS/pre-review-context.sh" < "$ARTIFACTS/diff.patch" > "$BATS_TEST_TMPDIR/metadata.json"
    jq -n --arg dir "$ARTIFACTS" --argjson has_frontend "${1:-true}" --slurpfile metadata "$BATS_TEST_TMPDIR/metadata.json" '{
        status: "ready",
        mode: "pr",
        artifacts_dir: $dir,
        diff_path: ($dir + "/diff.patch"),
        diff_tokens: 3000,
        file_metadata: $metadata[0],
        languages: {has_frontend: $has_frontend},
        review_context: "Review infrastructure removal.",
        pr: {number: 1, title: "Remove unused infrastructure", url: "https://example.com/1",
             author: "testuser", base: "main", head: "cleanup", state: "OPEN", body: "",
             comments: {conversation: [], reviews: [], inline: []}}
    }' > "$SESSION_FILE"
}

write_mixed_diff() {
    cat > "$ARTIFACTS/diff.patch" <<'DIFF'
diff --git a/stacks/main.tf b/stacks/main.tf
--- a/stacks/main.tf
+++ b/stacks/main.tf
@@ -1 +1 @@
-count = 1
+count = 2
diff --git a/stacks/terragrunt.hcl b/stacks/terragrunt.hcl
deleted file mode 100644
--- a/stacks/terragrunt.hcl
+++ /dev/null
@@ -1 +0,0 @@
-include "retired" {}
diff --git a/backend/old.py b/backend/old.py
deleted file mode 100644
--- a/backend/old.py
+++ /dev/null
@@ -1 +0,0 @@
-retired_backend = True
diff --git a/frontend/Old.tsx b/frontend/Old.tsx
deleted file mode 100644
--- a/frontend/Old.tsx
+++ /dev/null
@@ -1 +0,0 @@
-export const Old = () => <div>retired frontend</div>
DIFF
}

build_selected_briefing() {
    "$SCRIPTS/classify-review-scope.sh" "$SESSION_FILE" > "$BATS_TEST_TMPDIR/classification.json"
    local agents
    agents=$(jq -r '.agents | join(" ")' "$BATS_TEST_TMPDIR/classification.json")
    run "$SCRIPTS/build-agent-briefing.sh" "$SESSION_FILE" --agents "$agents" "$@"
    [ "$status" -eq 0 ]
}

write_real_rename_diff() {
    local repo="$BATS_TEST_TMPDIR/repo" destination="$1"
    git init -q "$repo"
    mkdir "$repo/old b"
    printf '%s\n' 'count = 1' > "$repo/old b/foo.tf"
    git -C "$repo" add .
    git -C "$repo" -c commit.gpgsign=false -c user.name="Test User" -c user.email="test@example.com" commit -qm "Add infrastructure"
    git -C "$repo" mv 'old b/foo.tf' "$destination"
    git -C "$repo" -c core.quotePath=true diff --cached --find-renames=100% --no-ext-diff --src-prefix=a/ --dst-prefix=b/ > "$ARTIFACTS/diff.patch"
    grep -q '^similarity index 100%$' "$ARTIFACTS/diff.patch"
    ! grep -q '^--- ' "$ARTIFACTS/diff.patch"
}

@test "pure rename with b slash in the old path records the destination metadata" {
    write_real_rename_diff new.tf
    prepare_session false

    jq -e '.file_metadata | .file_count == 1 and .deleted_file_count == 0 and .modified_files == [{path: "new.tf", deleted: false, type: "config", language: "unknown", is_test: false, is_infra_config: true, likely_test_path: ""}]' "$SESSION_FILE"
}

@test "pure rename with b slash in the old path retains the complete scoped patch" {
    write_real_rename_diff new.tf

    run bash -c 'printf "%s\n" new.tf | "$1/split-diff-by-path.sh" "$2/diff.patch" "$2/diff-infra-config.patch"' _ "$SCRIPTS" "$ARTIFACTS"
    [ "$status" -eq 0 ]
    cmp "$ARTIFACTS/diff.patch" "$ARTIFACTS/diff-infra-config.patch"
}

@test "pure rename to a quoted destination retains metadata and the scoped patch" {
    write_real_rename_diff 'café.tf'
    prepare_session false

    jq -e '.file_metadata.modified_files | map(.path) == ["café.tf"]' "$SESSION_FILE"
    build_selected_briefing

    jq -e '.agents == ["infra-config"]' "$BATS_TEST_TMPDIR/classification.json"
    cmp "$ARTIFACTS/diff.patch" "$ARTIFACTS/diff-infra-config.patch"
}

@test "quoted frontend deletion selects the frontend reviewer from detected languages" {
    local repo="$BATS_TEST_TMPDIR/repo"
    git init -q "$repo"
    mkdir "$repo/frontend"
    printf '%s\n' 'export const label = "retired"' > "$repo/frontend/café.tsx"
    git -C "$repo" add .
    rm "$repo/frontend/café.tsx"
    git -C "$repo" -c core.quotePath=true diff --no-ext-diff --no-renames --src-prefix=a/ --dst-prefix=b/ > "$ARTIFACTS/diff.patch"
    prepare_session false
    "$SCRIPTS/code-language-detect.sh" < "$ARTIFACTS/diff.patch" > "$BATS_TEST_TMPDIR/languages.json"
    jq --slurpfile languages "$BATS_TEST_TMPDIR/languages.json" '.languages = $languages[0] | .diff_tokens = 800' "$SESSION_FILE" > "$BATS_TEST_TMPDIR/session.json"
    mv "$BATS_TEST_TMPDIR/session.json" "$SESSION_FILE"

    build_selected_briefing

    jq -e '.file_metadata.modified_files | any(.path == "frontend/café.tsx" and .deleted == true and .language == "typescript")' "$SESSION_FILE"
    jq -e '.agents | contains(["frontend"])' "$BATS_TEST_TMPDIR/classification.json"
    cmp "$ARTIFACTS/diff.patch" "$ARTIFACTS/diff-frontend.patch"
}

@test "deletion pipeline sends every Terraform and Terragrunt deletion to infra-config" {
    for path in stacks/main.tf stacks/terragrunt.hcl; do
        printf '%s\n' "diff --git a/$path b/$path" 'deleted file mode 100644' \
            "--- a/$path" '+++ /dev/null' '@@ -1 +0,0 @@' '-retired = true'
    done > "$ARTIFACTS/diff.patch"
    prepare_session
    jq '.languages.has_frontend = false' "$SESSION_FILE" > "$BATS_TEST_TMPDIR/session.json"
    mv "$BATS_TEST_TMPDIR/session.json" "$SESSION_FILE"

    build_selected_briefing

    jq -e '.agents == ["infra-config"]' "$BATS_TEST_TMPDIR/classification.json"
    [ -s "$ARTIFACTS/diff-infra-config.patch" ]
    cmp "$ARTIFACTS/diff.patch" "$ARTIFACTS/diff-infra-config.patch"
    echo "$output" | jq -e '.scoped_diffs["diff-infra-config.patch"] > 0'
}

@test "deletion pipeline scopes infra deletions and names excluded source deletions" {
    write_mixed_diff
    prepare_session

    build_selected_briefing

    jq -e '.agents | contains(["correctness", "infra-config"])' "$BATS_TEST_TMPDIR/classification.json"
    [ "$(grep -c '^diff --git' "$ARTIFACTS/diff-infra-config.patch")" -eq 2 ]
    grep -q '^--- a/stacks/terragrunt.hcl$' "$ARTIFACTS/diff-infra-config.patch"
    grep -q '^+++ /dev/null$' "$ARTIFACTS/diff-infra-config.patch"
    grep -q '^-include "retired" {}$' "$ARTIFACTS/diff-infra-config.patch"
    grep -q 'backend/old.py' "$ARTIFACTS/diff-infra-config.patch"
    grep -q 'frontend/Old.tsx' "$ARTIFACTS/diff-infra-config.patch"
    ! grep -q '^diff --git.*backend/old.py' "$ARTIFACTS/diff-infra-config.patch"
    ! grep -q 'retired_backend\|retired frontend' "$ARTIFACTS/diff-infra-config.patch"
}

@test "deletion pipeline scopes the override diff for an incremental review" {
    write_mixed_diff
    prepare_session
    delta="$BATS_TEST_TMPDIR/delta.patch"
    cat > "$delta" <<'DIFF'
diff --git a/stacks/terragrunt.hcl b/stacks/terragrunt.hcl
deleted file mode 100644
--- a/stacks/terragrunt.hcl
+++ /dev/null
@@ -1 +0,0 @@
-override = true
DIFF

    build_selected_briefing --diff-file "$delta"

    cmp "$delta" "$ARTIFACTS/diff-infra-config.patch"
    echo "$output" | jq -e --arg delta "$delta" '.diff_path == $delta and .scoped_diffs["diff-infra-config.patch"] > 0'
}

@test "deletion pipeline includes a deleted component in the frontend scoped diff" {
    write_mixed_diff
    prepare_session

    build_selected_briefing

    [ "$(grep -c '^diff --git' "$ARTIFACTS/diff-frontend.patch")" -eq 1 ]
    grep -q '^--- a/frontend/Old.tsx$' "$ARTIFACTS/diff-frontend.patch"
    grep -q '^+++ /dev/null$' "$ARTIFACTS/diff-frontend.patch"
    grep -q '^-export const Old' "$ARTIFACTS/diff-frontend.patch"
    ! grep -q '^diff --git.*stacks/' "$ARTIFACTS/diff-frontend.patch"
}

@test "quoted source deletion prevents infra-only selection in a real Git diff" {
    local repo="$BATS_TEST_TMPDIR/repo"
    git init -q "$repo"
    printf '%s\n' 'retired = True' > "$repo/café.py"
    printf '%s\n' 'count = 1' > "$repo/main.tf"
    git -C "$repo" add .
    rm "$repo/café.py"
    printf '%s\n' 'count = 2' > "$repo/main.tf"
    git -C "$repo" -c core.quotePath=true diff --no-ext-diff --no-renames --src-prefix=a/ --dst-prefix=b/ > "$ARTIFACTS/diff.patch"
    prepare_session false

    jq -e '.file_metadata | .file_count == 2 and .deleted_file_count == 1' "$SESSION_FILE"
    jq -e '.file_metadata.modified_files | any(.path == "café.py" and .deleted == true and .type == "source")' "$SESSION_FILE"
    build_selected_briefing

    jq -e '.agents | contains(["correctness", "infra-config"])' "$BATS_TEST_TMPDIR/classification.json"
    grep -q '^diff --git a/main.tf b/main.tf$' "$ARTIFACTS/diff-infra-config.patch"
    grep -q 'café.py' "$ARTIFACTS/diff-infra-config.patch"
    ! grep -q '^-retired = True$' "$ARTIFACTS/diff-infra-config.patch"
}

@test "quoted infrastructure deletions retain decoded paths and complete Git diff blocks" {
    local repo="$BATS_TEST_TMPDIR/repo" path
    git init -q "$repo"
    mkdir "$repo/stacks"
    for path in 'stacks/café.tf' 'stacks/say"hi.tf' 'stacks/back\slash.tf'; do
        printf '%s\n' 'retired = true' > "$repo/$path"
    done
    git -C "$repo" add .
    for path in 'stacks/café.tf' 'stacks/say"hi.tf' 'stacks/back\slash.tf'; do
        rm "$repo/$path"
    done
    git -C "$repo" -c core.quotePath=true diff --no-ext-diff --no-renames --src-prefix=a/ --dst-prefix=b/ > "$ARTIFACTS/diff.patch"
    prepare_session false

    jq -e '.file_metadata | .file_count == 3 and .deleted_file_count == 3' "$SESSION_FILE"
    jq -e '.file_metadata.modified_files | map(.path) | sort == (["stacks/café.tf", "stacks/say\"hi.tf", "stacks/back\\slash.tf"] | sort)' "$SESSION_FILE"
    jq -e '.file_metadata.modified_files | all(.deleted == true and .is_infra_config == true and .type == "config")' "$SESSION_FILE"
    build_selected_briefing

    jq -e '.agents == ["infra-config"]' "$BATS_TEST_TMPDIR/classification.json"
    cmp "$ARTIFACTS/diff.patch" "$ARTIFACTS/diff-infra-config.patch"
    echo "$output" | jq -e '.scoped_diffs["diff-infra-config.patch"] > 0'
}

@test "newline infrastructure deletion retains its complete scoped diff block" {
    local repo="$BATS_TEST_TMPDIR/repo" path=$'stacks/line\nbreak.tf'
    git init -q "$repo"
    mkdir "$repo/stacks"
    printf '%s\n' 'retired = true' > "$repo/$path"
    git -C "$repo" add .
    rm "$repo/$path"
    git -C "$repo" -c core.quotePath=true diff --no-ext-diff --no-renames --src-prefix=a/ --dst-prefix=b/ > "$ARTIFACTS/diff.patch"
    prepare_session false

    jq -e --arg path "$path" '.file_metadata.modified_files == [{path: $path, deleted: true, type: "config", language: "unknown", is_test: false, is_infra_config: true, likely_test_path: ""}]' "$SESSION_FILE"
    build_selected_briefing

    jq -e '.agents == ["infra-config"]' "$BATS_TEST_TMPDIR/classification.json"
    cmp "$ARTIFACTS/diff.patch" "$ARTIFACTS/diff-infra-config.patch"
}

@test "unquoted path containing b slash retains its complete scoped diff block" {
    local repo="$BATS_TEST_TMPDIR/repo" path='stacks/foo b/bar.tf'
    git init -q "$repo"
    mkdir -p "$repo/stacks/foo b"
    printf '%s\n' 'retired = true' > "$repo/$path"
    git -C "$repo" add .
    rm "$repo/$path"
    git -C "$repo" -c core.quotePath=true diff --no-ext-diff --no-renames --src-prefix=a/ --dst-prefix=b/ > "$ARTIFACTS/diff.patch"
    prepare_session false

    jq -e --arg path "$path" '.file_metadata.modified_files | map(.path) == [$path]' "$SESSION_FILE"
    build_selected_briefing

    jq -e '.agents == ["infra-config"]' "$BATS_TEST_TMPDIR/classification.json"
    cmp "$ARTIFACTS/diff.patch" "$ARTIFACTS/diff-infra-config.patch"
}
