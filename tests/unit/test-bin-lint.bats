#!/usr/bin/env bats

setup() {
    local project_root
    project_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    local fixture="$BATS_TEST_TMPDIR/repo"
    local mock_bin="$BATS_TEST_TMPDIR/mock-bin"
    mkdir -p "$fixture/bin/helpers" "$mock_bin"
    cp "$project_root/bin/lint" "$fixture/bin/lint"
    cp "$project_root/bin/helpers/_utils.sh" "$fixture/bin/helpers/_utils.sh"
    echo 'print("clean")' > "$fixture/bin/example.py"

    cat > "$mock_bin/shellcheck" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == --version ]]; then
    echo 'ShellCheck - shell script analysis tool'
    echo "version: $TEST_SHELLCHECK_VERSION"
    exit 0
fi
echo 'shellcheck checked files'
exit "${TEST_SHELLCHECK_STATUS:-0}"
EOF
    cat > "$mock_bin/ruff" <<'EOF'
#!/usr/bin/env bash
echo 'ruff checked files'
exit "${TEST_RUFF_STATUS:-0}"
EOF
    chmod +x "$mock_bin/shellcheck" "$mock_bin/ruff"
    export PATH="$mock_bin:$PATH"
    export TEST_SHELLCHECK_VERSION=0.11.0
    export TEST_SHELLCHECK_STATUS=0
    export TEST_RUFF_STATUS=0
    cd "$fixture"
}

assert_linters_ran() {
    [[ "$output" == *'shellcheck checked files'* ]]
    [[ "$output" == *'ruff checked files'* ]]
}

assert_version_warning() {
    [[ "$output" == *'Warning:'* ]]
    [[ "$output" == *"$TEST_SHELLCHECK_VERSION"* ]]
    [[ "$output" == *'0.11.0'* ]]
    [[ "$output" == *'CI'* ]]
}

@test "bin/lint: matching ShellCheck version has no warning" {
    run bash bin/lint
    [ "$status" -eq 0 ]
    [[ "$output" != *'Warning:'* ]]
    assert_linters_ran
}

@test "bin/lint: older ShellCheck warns but successful lint still passes" {
    export TEST_SHELLCHECK_VERSION=0.9.0
    run bash bin/lint
    [ "$status" -eq 0 ]
    assert_linters_ran
    assert_version_warning
}

@test "bin/lint: newer ShellCheck warns but successful lint still passes" {
    export TEST_SHELLCHECK_VERSION=0.12.0
    run bash bin/lint
    [ "$status" -eq 0 ]
    assert_linters_ran
    assert_version_warning
}

@test "bin/lint: ShellCheck failure still fails with version skew" {
    export TEST_SHELLCHECK_VERSION=0.9.0
    export TEST_SHELLCHECK_STATUS=1
    run bash bin/lint
    [ "$status" -ne 0 ]
    assert_linters_ran
    assert_version_warning
}

@test "bin/lint: ruff failure still fails with version skew" {
    export TEST_SHELLCHECK_VERSION=0.9.0
    export TEST_RUFF_STATUS=1
    run bash bin/lint
    [ "$status" -ne 0 ]
    assert_linters_ran
    assert_version_warning
}
