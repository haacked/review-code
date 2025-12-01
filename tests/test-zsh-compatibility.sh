#!/usr/bin/env bash
# Test script to verify zsh compatibility fixes for review-code

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

echo "Testing zsh compatibility fixes..."
echo ""

# Test 1: code-language-detect.sh with empty diff
echo "Test 1: code-language-detect.sh with empty diff"
result=$(echo "" | "$LIB_DIR/code-language-detect.sh")
if echo "$result" | jq -e '.languages == []' >/dev/null; then
    echo "✓ PASS: Empty arrays returned for empty diff"
else
    echo "✗ FAIL: Expected empty arrays, got: $result"
    exit 1
fi
echo ""

# Test 2: code-language-detect.sh with valid diff
echo "Test 2: code-language-detect.sh with valid diff"
result=$(
    cat <<'EOF' | "$LIB_DIR/code-language-detect.sh"
diff --git a/test.py b/test.py
--- a/test.py
+++ b/test.py
@@ -1,3 +1,4 @@
+import flask
EOF
)
if echo "$result" | jq -e '.languages | contains(["python"])' >/dev/null &&
    echo "$result" | jq -e '.frameworks | contains(["flask"])' >/dev/null; then
    echo "✓ PASS: Languages and frameworks detected correctly"
else
    echo "✗ FAIL: Expected python and flask, got: $result"
    exit 1
fi
echo ""

# Test 3: Validate JSON output from code-language-detect.sh
echo "Test 3: Validate JSON output is valid"
result=$(echo "" | "$LIB_DIR/code-language-detect.sh")
if echo "$result" | jq empty 2>/dev/null; then
    echo "✓ PASS: JSON output is valid"
else
    echo "✗ FAIL: Invalid JSON output: $result"
    exit 1
fi
echo ""

# Test 4: Test has_frontend field extraction
echo "Test 4: Test has_frontend field extraction with null handling"
mock_data='{"languages":null}'
result=$(echo "$mock_data" | jq -r ".languages.has_frontend // false")
if [ "$result" = "false" ]; then
    echo "✓ PASS: Null languages field handled gracefully"
else
    echo "✗ FAIL: Expected 'false', got: $result"
    exit 1
fi
echo ""

# Test 5: Test has_frontend with valid data
echo "Test 5: Test has_frontend with valid languages data"
result=$(echo "" | "$LIB_DIR/code-language-detect.sh" | jq -r ".has_frontend")
if [ "$result" = "false" ]; then
    echo "✓ PASS: has_frontend is false for empty diff"
else
    echo "✗ FAIL: Expected 'false', got: $result"
    exit 1
fi
echo ""

# Test 6: Test pre-review-context with empty diff
echo "Test 6: pre-review-context.sh with empty diff"
result=$(echo "" | "$LIB_DIR/pre-review-context.sh")
if echo "$result" | jq -e '.modified_files == []' >/dev/null; then
    echo "✓ PASS: Empty file list returned for empty diff"
else
    echo "✗ FAIL: Expected empty file list, got: $result"
    exit 1
fi
echo ""

echo "========================================"
echo "All tests passed! ✓"
echo "========================================"
