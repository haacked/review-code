#!/usr/bin/env bats
# Unit tests for pre-review-context.sh

setup() {
    # Get the directory containing this test file
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    SCRIPT="$PROJECT_ROOT/lib/pre-review-context.sh"
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
