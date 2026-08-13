#!/usr/bin/env bats
# Tests for lib/helpers/cli-timeout-helpers.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    source "$PROJECT_ROOT/skills/review-code/scripts/helpers/cli-timeout-helpers.sh"

    MOCK_DIR=$(mktemp -d)
    LOG_DIR=$(mktemp -d)
    export PATH="$MOCK_DIR:$PATH"
}

teardown() {
    rm -rf "$MOCK_DIR" "$LOG_DIR"
}

# =============================================================================
# cli_cleanup_old_logs
# =============================================================================

@test "cli_cleanup_old_logs: no-op when log dir does not exist" {
    run cli_cleanup_old_logs "$LOG_DIR/does-not-exist" 'mock-*.log'
    [ "$status" -eq 0 ]
}

@test "cli_cleanup_old_logs: deletes files older than 7 days matching the glob" {
    touch -t "$(date -v-8d +%Y%m%d%H%M 2>/dev/null || date -d '8 days ago' +%Y%m%d%H%M)" "$LOG_DIR/mock-old.log"
    cli_cleanup_old_logs "$LOG_DIR" 'mock-*.log'
    [ ! -f "$LOG_DIR/mock-old.log" ]
}

@test "cli_cleanup_old_logs: keeps files newer than 7 days" {
    touch "$LOG_DIR/mock-fresh.log"
    cli_cleanup_old_logs "$LOG_DIR" 'mock-*.log'
    [ -f "$LOG_DIR/mock-fresh.log" ]
}

@test "cli_cleanup_old_logs: ignores files that do not match the glob" {
    touch -t "$(date -v-8d +%Y%m%d%H%M 2>/dev/null || date -d '8 days ago' +%Y%m%d%H%M)" "$LOG_DIR/other-old.log"
    cli_cleanup_old_logs "$LOG_DIR" 'mock-*.log'
    [ -f "$LOG_DIR/other-old.log" ]
}

@test "cli_cleanup_old_logs: refuses to clean shallow directories" {
    touch -t "$(date -v-8d +%Y%m%d%H%M 2>/dev/null || date -d '8 days ago' +%Y%m%d%H%M)" "/tmp/mock-old.log"
    run cli_cleanup_old_logs "/tmp" 'mock-*.log'
    [ "$status" -eq 0 ]
    [ -f "/tmp/mock-old.log" ]
    rm -f "/tmp/mock-old.log"
}

# =============================================================================
# run_with_timeout
# =============================================================================

@test "run_with_timeout: passes through stdout and exits 0 on success" {
    cat > "$MOCK_DIR/mockcli" << 'EOF'
#!/bin/bash
echo "hello from mockcli"
EOF
    chmod +x "$MOCK_DIR/mockcli"

    run run_with_timeout 5 mockcli
    [ "$status" -eq 0 ]
    [ "$output" = "hello from mockcli" ]
}

@test "run_with_timeout: propagates a nonzero exit code from the command" {
    cat > "$MOCK_DIR/mockcli" << 'EOF'
#!/bin/bash
exit 3
EOF
    chmod +x "$MOCK_DIR/mockcli"

    run run_with_timeout 5 mockcli
    [ "$status" -eq 3 ]
}

@test "run_with_timeout: kills a command exceeding the timeout with status 124" {
    if ! command -v gtimeout > /dev/null 2>&1 && ! command -v timeout > /dev/null 2>&1; then
        skip "neither gtimeout nor timeout is installed"
    fi

    cat > "$MOCK_DIR/mockcli" << 'EOF'
#!/bin/bash
sleep 10
EOF
    chmod +x "$MOCK_DIR/mockcli"

    run run_with_timeout 1 mockcli
    [ "$status" -eq 124 ]
}

@test "run_with_timeout: runs the command directly when no timeout binary exists" {
    # Constrain PATH to a directory containing only bash and the mock, so
    # `command -v gtimeout` and `command -v timeout` both fail while the mock
    # (and the bash shebang it needs) still resolve.
    NO_TIMEOUT_DIR=$(mktemp -d)
    ln -s "$(command -v bash)" "$NO_TIMEOUT_DIR/bash"
    cat > "$NO_TIMEOUT_DIR/mockcli" << 'EOF'
#!/bin/bash
echo "ran without a timeout binary"
EOF
    chmod +x "$NO_TIMEOUT_DIR/mockcli"

    PATH="$NO_TIMEOUT_DIR" run run_with_timeout 5 mockcli
    [ "$status" -eq 0 ]
    [ "$output" = "ran without a timeout binary" ]

    rm -rf "$NO_TIMEOUT_DIR"
}

# =============================================================================
# run_cli_with_timeout
# =============================================================================

@test "run_cli_with_timeout: captures stdout via nameref on success" {
    cat > "$MOCK_DIR/mockcli" << 'EOF'
#!/bin/bash
echo "hello from mockcli"
EOF
    chmod +x "$MOCK_DIR/mockcli"

    local out dur logf
    run_cli_with_timeout mockcli "$LOG_DIR" mockcli 5 out dur logf
    local result=$?

    [ "$result" -eq 0 ]
    [ "$out" = "hello from mockcli" ]
    [[ "$dur" =~ ^[0-9]+$ ]]
    [ -f "$logf" ]
}

@test "run_cli_with_timeout: forwards CLI arguments" {
    cat > "$MOCK_DIR/mockcli" << 'EOF'
#!/bin/bash
echo "args: $*"
EOF
    chmod +x "$MOCK_DIR/mockcli"

    local out dur logf
    run_cli_with_timeout mockcli "$LOG_DIR" mockcli 5 out dur logf --flag "value with spaces"
    [ "$out" = "args: --flag value with spaces" ]
}

@test "run_cli_with_timeout: log file records invocation header and result" {
    cat > "$MOCK_DIR/mockcli" << 'EOF'
#!/bin/bash
echo "ok"
EOF
    chmod +x "$MOCK_DIR/mockcli"

    local out dur logf
    run_cli_with_timeout mockcli "$LOG_DIR" mockcli 5 out dur logf
    grep -q "=== mockcli invocation ===" "$logf"
    grep -q "=== result ===" "$logf"
    grep -q "Exit code: 0" "$logf"
}

@test "run_cli_with_timeout: returns 1 on timeout" {
    cat > "$MOCK_DIR/mockcli" << 'EOF'
#!/bin/bash
exit 124
EOF
    chmod +x "$MOCK_DIR/mockcli"

    local out dur logf result=0
    run_cli_with_timeout mockcli "$LOG_DIR" mockcli 1 out dur logf || result=$?
    [ "$result" -eq 1 ]
}

@test "run_cli_with_timeout: returns 2 on generic CLI error" {
    cat > "$MOCK_DIR/mockcli" << 'EOF'
#!/bin/bash
echo "boom" >&2
exit 3
EOF
    chmod +x "$MOCK_DIR/mockcli"

    local out dur logf result=0
    run_cli_with_timeout mockcli "$LOG_DIR" mockcli 5 out dur logf || result=$?
    [ "$result" -eq 2 ]

    run cli_read_stderr "$logf"
    [[ "$output" == *"boom"* ]]
}

@test "run_cli_with_timeout: log file name is scoped by the given prefix" {
    cat > "$MOCK_DIR/mockcli" << 'EOF'
#!/bin/bash
echo "ok"
EOF
    chmod +x "$MOCK_DIR/mockcli"

    local out dur logf
    run_cli_with_timeout mockcli "$LOG_DIR" myengine 5 out dur logf
    [[ "$(basename "$logf")" == myengine-* ]]
}

# =============================================================================
# cli_read_stderr
# =============================================================================

@test "cli_read_stderr: returns empty for a nonexistent log file" {
    run cli_read_stderr "$LOG_DIR/does-not-exist.log"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "cli_read_stderr: extracts lines between the stderr and result markers" {
    cat > "$LOG_DIR/sample.log" << 'EOF'
=== mockcli invocation ===
Timestamp: 2026-01-01T00:00:00Z
Timeout: 5s
Args: [0 arguments, prompt omitted]
=== stderr ===
line one
line two
=== result ===
Exit code: 1
Duration: 42ms
EOF
    run cli_read_stderr "$LOG_DIR/sample.log"
    [ "$status" -eq 0 ]
    [ "$output" = "line one
line two" ]
}

@test "cli_read_stderr: respects max_lines" {
    {
        echo "=== stderr ==="
        for i in 1 2 3 4 5; do echo "line $i"; done
        echo "=== result ==="
    } > "$LOG_DIR/sample.log"

    run cli_read_stderr "$LOG_DIR/sample.log" 2
    [ "$output" = "line 4
line 5" ]
}
