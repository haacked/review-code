#!/usr/bin/env bats
# Tests for check-findings-addressed.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/check-findings-addressed.sh"
}

# =============================================================================
# Basic functionality tests
# =============================================================================

@test "check-findings-addressed.sh: exists and is executable" {
    [ -x "$SCRIPT" ]
}

@test "check-findings-addressed.sh: returns empty array for empty findings" {
    run bash -c 'echo "{\"findings\": [], \"diff\": \"\"}" | '"$SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '. == []' > /dev/null
}

# =============================================================================
# Auto-status detection tests
# =============================================================================

@test "check-findings-addressed.sh: marks finding as likely_fixed when line is in diff" {
    local input
    input=$(jq -nc '{
        findings: [{
            number: "1", prefix: "blocking", title: "Missing guard",
            file: "src/auth.py", line: 22, conclusion: null,
            agent: "security", confidence: 85, description: "desc"
        }],
        diff: "diff --git a/src/auth.py b/src/auth.py\nindex abc..def 100644\n--- a/src/auth.py\n+++ b/src/auth.py\n@@ -20,6 +20,8 @@ def func():\n     line20\n     line21\n+    if not settings.FLAGS_REDIS_URL:\n+        return None\n     line22_old_becomes_24\n     line25\n     line26\n"
    }')
    run bash -c "echo '$input' | $SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].auto_status == "likely_fixed"' > /dev/null
}

@test "check-findings-addressed.sh: marks finding as still_open when line not in diff" {
    local input
    input=$(jq -nc '{
        findings: [{
            number: "6", prefix: "suggestion", title: "Signal handler split",
            file: "src/handlers.py", line: 100, conclusion: null,
            agent: "maintainability", confidence: 60, description: "desc"
        }],
        diff: "diff --git a/src/other.py b/src/other.py\nindex abc..def 100644\n--- a/src/other.py\n+++ b/src/other.py\n@@ -1,3 +1,4 @@\n line1\n+new line\n line2\n line3\n"
    }')
    run bash -c "echo '$input' | $SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].auto_status == "still_open"' > /dev/null
}

@test "check-findings-addressed.sh: marks finding as still_open when file in diff but line untouched" {
    local input
    input=$(jq -nc '{
        findings: [{
            number: "3", prefix: "suggestion", title: "Some issue",
            file: "src/auth.py", line: 100, conclusion: null,
            agent: "correctness", confidence: 50, description: "desc"
        }],
        diff: "diff --git a/src/auth.py b/src/auth.py\nindex abc..def 100644\n--- a/src/auth.py\n+++ b/src/auth.py\n@@ -1,3 +1,4 @@\n line1\n+new line\n line2\n line3\n"
    }')
    run bash -c "echo '$input' | $SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].auto_status == "still_open"' > /dev/null
}

@test "check-findings-addressed.sh: marks finding as concluded when conclusion exists" {
    local input
    input=$(jq -nc '{
        findings: [{
            number: "1", prefix: "blocking", title: "Guard issue",
            file: "src/auth.py", line: 22, conclusion: {status: "Fixed", reason: null},
            agent: "security", confidence: 85, description: "desc"
        }],
        diff: "diff --git a/src/auth.py b/src/auth.py\nindex abc..def 100644\n--- a/src/auth.py\n+++ b/src/auth.py\n@@ -20,6 +20,8 @@\n line20\n+new\n line22\n"
    }')
    run bash -c "echo '$input' | $SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].auto_status == "concluded"' > /dev/null
}

@test "check-findings-addressed.sh: marks finding as inconclusive when no file reference" {
    local input
    input=$(jq -nc '{
        findings: [{
            number: "7", prefix: "suggestion", title: "General concern",
            file: "", line: 0, conclusion: null,
            agent: "architecture", confidence: 40, description: "desc"
        }],
        diff: "diff --git a/src/auth.py b/src/auth.py\nindex abc..def 100644\n--- a/src/auth.py\n+++ b/src/auth.py\n@@ -1,3 +1,4 @@\n line1\n+new\n line2\n line3\n"
    }')
    run bash -c "echo '$input' | $SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].auto_status == "inconclusive"' > /dev/null
}

# =============================================================================
# Mixed findings tests
# =============================================================================

@test "check-findings-addressed.sh: handles multiple findings with different statuses" {
    local input
    input=$(jq -nc '{
        findings: [
            {number: "1", prefix: "blocking", title: "Fixed issue",
             file: "src/auth.py", line: 22, conclusion: {status: "Fixed", reason: null},
             agent: "security", confidence: 85, description: "desc"},
            {number: "2", prefix: "suggestion", title: "Modified line",
             file: "src/auth.py", line: 5, conclusion: null,
             agent: "performance", confidence: 60, description: "desc"},
            {number: "3", prefix: "suggestion", title: "Untouched",
             file: "src/other.py", line: 50, conclusion: null,
             agent: "correctness", confidence: 50, description: "desc"},
            {number: "4", prefix: "nit", title: "No file ref",
             file: "", line: 0, conclusion: null,
             agent: "maintainability", confidence: 30, description: "desc"}
        ],
        diff: "diff --git a/src/auth.py b/src/auth.py\nindex abc..def 100644\n--- a/src/auth.py\n+++ b/src/auth.py\n@@ -3,6 +3,7 @@\n line3\n line4\n-old line5\n+new line5\n line6\n line7\n line8\n"
    }')
    run bash -c "echo '$input' | $SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].auto_status == "concluded"' > /dev/null
    echo "$output" | jq -e '.[1].auto_status == "likely_fixed"' > /dev/null
    echo "$output" | jq -e '.[2].auto_status == "still_open"' > /dev/null
    echo "$output" | jq -e '.[3].auto_status == "inconclusive"' > /dev/null
}

# =============================================================================
# Preserves original fields
# =============================================================================

@test "check-findings-addressed.sh: preserves all original finding fields" {
    local input
    input=$(jq -nc '{
        findings: [{
            number: "1", prefix: "blocking", title: "Guard issue",
            file: "src/auth.py", line: 22,
            conclusion: {status: "Fixed", reason: "added guard"},
            agent: "security", confidence: 85, description: "desc"
        }],
        diff: ""
    }')
    run bash -c "echo '$input' | $SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].number == "1"' > /dev/null
    echo "$output" | jq -e '.[0].prefix == "blocking"' > /dev/null
    echo "$output" | jq -e '.[0].title == "Guard issue"' > /dev/null
    echo "$output" | jq -e '.[0].agent == "security"' > /dev/null
    echo "$output" | jq -e '.[0].confidence == 85' > /dev/null
    echo "$output" | jq -e '.[0].conclusion.status == "Fixed"' > /dev/null
    echo "$output" | jq -e '.[0].conclusion.reason == "added guard"' > /dev/null
}

# =============================================================================
# Edge cases
# =============================================================================

@test "check-findings-addressed.sh: handles empty diff" {
    local input
    input=$(jq -nc '{
        findings: [{
            number: "1", prefix: "blocking", title: "Issue",
            file: "src/auth.py", line: 22, conclusion: null,
            agent: "security", confidence: 85, description: "desc"
        }],
        diff: ""
    }')
    run bash -c "echo '$input' | $SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].auto_status == "still_open"' > /dev/null
}

@test "check-findings-addressed.sh: can be sourced without executing main" {
    run bash -c "source '$SCRIPT' && echo 'sourced ok'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sourced ok"* ]]
}
