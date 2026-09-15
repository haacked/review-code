#!/usr/bin/env bats
# Unit tests for pre-review-context.sh

setup() {
    # Get the directory containing this test file
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/pre-review-context.sh"
}

@test "pre-review-context.sh exists and is executable" {
    [ -x "$SCRIPT" ]
}

@test "detects Python files correctly" {
    diff=$(cat <<'EOF'
diff --git a/backend/api.py b/backend/api.py
+++ b/backend/api.py
@@ -1,0 +1,2 @@
+def hello():
+    return "world"
EOF
)

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.file_count == 1'
    echo "$result" | jq -e '.modified_files[0].language == "python"'
    echo "$result" | jq -e '.modified_files[0].path == "backend/api.py"'
}

@test "detects TypeScript files correctly" {
    diff=$(cat <<'EOF'
diff --git a/src/Component.tsx b/src/Component.tsx
+++ b/src/Component.tsx
@@ -1,0 +1,2 @@
+export const App = () => {
+  return <div>Hello</div>
+}
EOF
)

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.file_count == 1'
    echo "$result" | jq -e '.modified_files[0].language == "typescript"'
    echo "$result" | jq -e '.modified_files[0].path == "src/Component.tsx"'
}

@test "detects test files by prefix" {
    diff=$(cat <<'EOF'
diff --git a/tests/test_auth.py b/tests/test_auth.py
+++ b/tests/test_auth.py
@@ -1,0 +1,2 @@
+def test_login():
+    assert True
EOF
)

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.has_tests == true'
    echo "$result" | jq -e '.modified_files[0].is_test == true'
    echo "$result" | jq -e '.modified_files[0].type == "test"'
}

@test "detects test files by suffix" {
    diff=$(cat <<'EOF'
diff --git a/src/Component.test.tsx b/src/Component.test.tsx
+++ b/src/Component.test.tsx
@@ -1,0 +1,2 @@
+test('renders', () => {})
EOF
)

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.has_tests == true'
    echo "$result" | jq -e '.modified_files[0].is_test == true'
}

@test "detects config files" {
    diff=$(cat <<'EOF'
diff --git a/package.json b/package.json
+++ b/package.json
@@ -1,0 +1,3 @@
+{
+  "name": "test"
+}
EOF
)

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.has_config == true'
    echo "$result" | jq -e '.modified_files[0].type == "config"'
}

@test "handles multiple files in single diff" {
    diff=$(cat <<'EOF'
diff --git a/backend/api.py b/backend/api.py
+++ b/backend/api.py
@@ -1,0 +1,1 @@
+# Python file
diff --git a/frontend/App.tsx b/frontend/App.tsx
+++ b/frontend/App.tsx
@@ -1,0 +1,1 @@
+// TypeScript file
diff --git a/README.md b/README.md
+++ b/README.md
@@ -1,0 +1,1 @@
+# Markdown file
EOF
)

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.file_count == 3'
    echo "$result" | jq -e '[.modified_files[].language] | contains(["python", "typescript", "unknown"])'
}

@test "handles files with quotes in path" {
    diff=$(cat <<'EOF'
diff --git a/path/with"quotes/file.py b/path/with"quotes/file.py
+++ b/path/with"quotes/file.py
@@ -1,0 +1,1 @@
+# Test
EOF
)

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.file_count == 1'
    echo "$result" | jq -e '.modified_files[0].path == "path/with\"quotes/file.py"'
}

@test "handles empty diff" {
    diff=""

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.file_count == 0'
    echo "$result" | jq -e '.modified_files | length == 0'
    echo "$result" | jq -e '.has_tests == false'
}

@test "generates valid JSON output" {
    diff=$(cat <<'EOF'
diff --git a/test.py b/test.py
+++ b/test.py
@@ -1,0 +1,1 @@
+print("hello")
EOF
)

    result=$(echo "$diff" | "$SCRIPT")
    # If jq can parse it without error, it's valid JSON
    echo "$result" | jq -e 'type == "object"'
}

@test "suggests likely test path for Python source files" {
    diff=$(cat <<'EOF'
diff --git a/backend/auth.py b/backend/auth.py
+++ b/backend/auth.py
@@ -1,0 +1,1 @@
+def login(): pass
EOF
)

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.modified_files[0].likely_test_path != ""'
    echo "$result" | jq -r '.modified_files[0].likely_test_path' | grep -q "test_auth.py"
}

@test "suggests likely test path for TypeScript source files" {
    diff=$(cat <<'EOF'
diff --git a/src/Component.tsx b/src/Component.tsx
+++ b/src/Component.tsx
@@ -1,0 +1,1 @@
+export const App = () => null
EOF
)

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.modified_files[0].likely_test_path != ""'
    echo "$result" | jq -r '.modified_files[0].likely_test_path' | grep -q "Component.test.tsx"
}

# Infra-config detection tests

@test "detects YAML files in argocd/ as infra-config" {
    diff=$(cat <<'EOF'
diff --git a/argocd/contour-ingress/values/values.prod-us.yaml b/argocd/contour-ingress/values/values.prod-us.yaml
+++ b/argocd/contour-ingress/values/values.prod-us.yaml
@@ -1,0 +1,2 @@
+route:
+  path: /flags/definitions
EOF
)

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.modified_files[0].is_infra_config == true'
    echo "$result" | jq -e '.modified_files[0].type == "config"'
    echo "$result" | jq -e '.has_infra_config == true'
}

@test "detects YAML files in helm/ as infra-config" {
    diff=$(cat <<'EOF'
diff --git a/helm/my-service/values.yaml b/helm/my-service/values.yaml
+++ b/helm/my-service/values.yaml
@@ -1,0 +1,2 @@
+replicaCount: 3
EOF
)

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.modified_files[0].is_infra_config == true'
    echo "$result" | jq -e '.has_infra_config == true'
}

@test "detects values.yaml by filename as infra-config" {
    diff=$(cat <<'EOF'
diff --git a/some/path/values.yaml b/some/path/values.yaml
+++ b/some/path/values.yaml
@@ -1,0 +1,1 @@
+key: value
EOF
)

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.modified_files[0].is_infra_config == true'
}

@test "detects Chart.yaml as infra-config" {
    diff=$(cat <<'EOF'
diff --git a/charts/my-app/Chart.yaml b/charts/my-app/Chart.yaml
+++ b/charts/my-app/Chart.yaml
@@ -1,0 +1,2 @@
+apiVersion: v2
+name: my-app
EOF
)

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.modified_files[0].is_infra_config == true'
}

@test "detects .tf files as infra-config" {
    diff=$(cat <<'EOF'
diff --git a/terraform/main.tf b/terraform/main.tf
+++ b/terraform/main.tf
@@ -1,0 +1,3 @@
+resource "aws_instance" "web" {
+  ami = "abc-123"
+}
EOF
)

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.modified_files[0].is_infra_config == true'
    echo "$result" | jq -e '.modified_files[0].type == "config"'
}

@test "detects GitHub Actions workflow files as infra-config" {
    diff=$(cat <<'EOF'
diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -1,0 +1,3 @@
+name: CI
+on: push
+jobs: {}
EOF
)

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.modified_files[0].is_infra_config == true'
    echo "$result" | jq -e '.has_infra_config == true'
}

@test "regular config files are NOT infra-config" {
    diff=$(cat <<'EOF'
diff --git a/package.json b/package.json
+++ b/package.json
@@ -1,0 +1,1 @@
+{"name": "test"}
diff --git a/tsconfig.json b/tsconfig.json
+++ b/tsconfig.json
@@ -1,0 +1,1 @@
+{"strict": true}
EOF
)

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.has_config == true'
    echo "$result" | jq -e '.has_infra_config == false'
    echo "$result" | jq -e '[.modified_files[].is_infra_config] | all(. == false)'
}

@test "has_infra_config is false when no infra files" {
    diff=$(cat <<'EOF'
diff --git a/backend/api.py b/backend/api.py
+++ b/backend/api.py
@@ -1,0 +1,1 @@
+print("hello")
EOF
)

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.has_infra_config == false'
}

@test "detects Dockerfile as infra-config" {
    diff=$(cat <<'EOF'
diff --git a/deploy/Dockerfile b/deploy/Dockerfile
+++ b/deploy/Dockerfile
@@ -1,0 +1,1 @@
+FROM python:3.11
EOF
)

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.modified_files[0].is_infra_config == true'
    echo "$result" | jq -e '.modified_files[0].type == "config"'
}

@test "detects .tfvars files as infra-config" {
    diff=$(cat <<'EOF'
diff --git a/terraform/variables.tfvars b/terraform/variables.tfvars
+++ b/terraform/variables.tfvars
@@ -1,0 +1,2 @@
+region = "us-east-1"
+instance_type = "t3.medium"
EOF
)

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.modified_files[0].is_infra_config == true'
    echo "$result" | jq -e '.modified_files[0].type == "config"'
    echo "$result" | jq -e '.has_infra_config == true'
}

@test "detects kustomization.yaml as infra-config" {
    diff=$(cat <<'EOF'
diff --git a/k8s/kustomization.yaml b/k8s/kustomization.yaml
+++ b/k8s/kustomization.yaml
@@ -1,0 +1,2 @@
+resources:
+  - deployment.yaml
EOF
)

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.modified_files[0].is_infra_config == true'
}

@test "strips trailing whitespace from file paths in diff headers" {
    # Diff headers can have trailing tabs/spaces (e.g. from git on some platforms)
    diff=$(printf 'diff --git a/backend/api.py b/backend/api.py\n+++ b/backend/api.py\t\n@@ -1,0 +1,1 @@\n+print("hello")\n')

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.file_count == 1'
    echo "$result" | jq -e '.modified_files[0].path == "backend/api.py"'
}

@test "mixed additions modifications and deletions all receive metadata" {
    diff=$(cat <<'EOF'
diff --git a/backend/old_module.py b/backend/old_module.py
deleted file mode 100644
--- a/backend/old_module.py
+++ /dev/null
@@ -1,3 +0,0 @@
-def old_func():
-    pass
diff --git a/backend/api.py b/backend/api.py
+++ b/backend/api.py
@@ -1,0 +1,1 @@
+print("hello")
diff --git a/backend/new_module.py b/backend/new_module.py
new file mode 100644
--- /dev/null
+++ b/backend/new_module.py
@@ -0,0 +1 @@
+new_value = 1
EOF
)

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.deleted_file_count == 1'
    echo "$result" | jq -e '.file_count == 3 and (.modified_files | length == 3)'
    echo "$result" | jq -e '.modified_files | map({path, deleted}) == [
        {path: "backend/old_module.py", deleted: true},
        {path: "backend/api.py", deleted: false},
        {path: "backend/new_module.py", deleted: false}
    ]'
}

@test "deleted Terraform and Terragrunt files retain infrastructure metadata" {
    diff=$(for path in stacks/main.tf stacks/variables.tfvars stacks/terragrunt.hcl; do
        printf '%s\n' "diff --git a/$path b/$path" 'deleted file mode 100644' \
            "--- a/$path" '+++ /dev/null' '@@ -1 +0,0 @@' '-region = "us-east-1"'
    done)

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.file_count == 3 and .deleted_file_count == 3'
    echo "$result" | jq -e '.has_config == true and .has_infra_config == true'
    echo "$result" | jq -e '.modified_files | length == 3 and all(.deleted == true and .type == "config" and .is_infra_config == true)'
}

@test "Terragrunt configuration is infrastructure when added" {
    diff=$(printf '%s\n' 'diff --git a/stacks/terragrunt.hcl b/stacks/terragrunt.hcl' \
        'new file mode 100644' '--- /dev/null' '+++ b/stacks/terragrunt.hcl' \
        '@@ -0,0 +1 @@' '+include "root" {}')

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.modified_files[0] | .deleted == false and .type == "config" and .is_infra_config == true'
}

@test "deleted source tests migrations and config retain their classifications" {
    diff=$(for path in backend/api.py backend/tests/test_api.py backend/migrations/0001_initial.py package.json; do
        printf '%s\n' "diff --git a/$path b/$path" 'deleted file mode 100644' \
            "--- a/$path" '+++ /dev/null' '@@ -1 +0,0 @@' '-old content'
    done)

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.file_count == 4 and .deleted_file_count == 4'
    echo "$result" | jq -e '.has_tests and .has_migrations and .has_config'
    echo "$result" | jq -e '[.modified_files[].type] == ["source", "test", "migration", "config"]'
    echo "$result" | jq -e '.modified_files[0] | .language == "python" and (.likely_test_path | endswith("test_api.py"))'
    echo "$result" | jq -e '.modified_files[1].is_test == true'
}

@test "empty and binary deletions count without text diff headers" {
    diff=$(cat <<'EOF'
diff --git a/stacks/empty.tf b/stacks/empty.tf
deleted file mode 100644
index e69de29..0000000
diff --git a/assets/logo.png b/assets/logo.png
deleted file mode 100644
index abcdef1..0000000
Binary files a/assets/logo.png and /dev/null differ
EOF
)

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.file_count == 2 and .deleted_file_count == 2'
    echo "$result" | jq -e '.modified_files | map({path, deleted}) == [
        {path: "stacks/empty.tf", deleted: true},
        {path: "assets/logo.png", deleted: true}
    ]'
    echo "$result" | jq -e '.modified_files[0].is_infra_config == true'
}

@test "mode changes and pure renames count once without text diff headers" {
    diff=$(cat <<'EOF'
diff --git a/bin/run.sh b/bin/run.sh
old mode 100644
new mode 100755
diff --git a/old.tf b/stacks/new.tf
similarity index 100%
rename from old.tf
rename to stacks/new.tf
EOF
)

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.file_count == 2 and .deleted_file_count == 0'
    echo "$result" | jq -e '.modified_files | map({path, deleted}) == [
        {path: "bin/run.sh", deleted: false},
        {path: "stacks/new.tf", deleted: false}
    ]'
}

@test "diff header text inside a hunk does not create file metadata" {
    diff=$(cat <<'EOF'
diff --git a/docs/example.patch b/docs/example.patch
--- a/docs/example.patch
+++ b/docs/example.patch
@@ -1,2 +1,4 @@
 existing example
+++ b/not-a-real-file.tf
+++ /dev/null
 final line
EOF
)

    result=$(echo "$diff" | "$SCRIPT")
    echo "$result" | jq -e '.file_count == 1 and .deleted_file_count == 0'
    echo "$result" | jq -e '.modified_files[0].path == "docs/example.patch"'
}

@test "quoted empty deletion decodes the Git path without text headers" {
    local repo="$BATS_TEST_TMPDIR/repo"
    git init -q "$repo"
    touch "$repo/café.tf"
    git -C "$repo" add .
    rm "$repo/café.tf"

    result=$(git -C "$repo" -c core.quotePath=true diff --no-ext-diff --no-renames --src-prefix=a/ --dst-prefix=b/ | "$SCRIPT")

    echo "$result" | jq -e '.file_count == 1 and .deleted_file_count == 1'
    echo "$result" | jq -e '.modified_files[0] | .path == "café.tf" and .deleted == true and .is_infra_config == true'
}

assert_control_path_metadata() {
    local deleted_path="$1"
    local repo="$BATS_TEST_TMPDIR/repo"
    local patch="$BATS_TEST_TMPDIR/diff.patch"
    git init -q "$repo"
    printf '%s\n' 'retired = True' > "$repo/$deleted_path"
    printf '%s\n' 'value = 1' > "$repo/stable.py"
    git -C "$repo" add .
    rm "$repo/$deleted_path"
    printf '%s\n' 'value = 2' > "$repo/stable.py"
    git -C "$repo" -c core.quotePath=true diff --no-ext-diff --no-renames --src-prefix=a/ --dst-prefix=b/ > "$patch"

    run "$SCRIPT" < "$patch"

    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | jq -e '.file_count == 2 and .deleted_file_count == 1'
    printf '%s\n' "$output" | jq -e --arg deleted_path "$deleted_path" '
        (.modified_files | map({path, deleted}) | sort_by(.path)) == ([
            {path: $deleted_path, deleted: true},
            {path: "stable.py", deleted: false}
        ] | sort_by(.path))'
}

@test "quoted tab filename produces valid metadata beside a modified file" {
    assert_control_path_metadata $'a\tretired.py'
}

@test "quoted carriage return filename produces valid metadata beside a modified file" {
    assert_control_path_metadata $'a\rretired.tf'
}

@test "quoted newline filename preserves one metadata record beside a modified file" {
    assert_control_path_metadata $'a\nretired.py'
}
