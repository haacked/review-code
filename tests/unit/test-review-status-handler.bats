#!/usr/bin/env bats
# Tests for skills/review-code/scripts/review-status-handler.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    HANDLER_SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/review-status-handler.sh"
    export HANDLER_SCRIPT
}

# =============================================================================
# Script structure tests
# =============================================================================

@test "review-status-handler: has correct shebang" {
    run bash -c "head -1 '$HANDLER_SCRIPT' | grep -q '^#!/usr/bin/env bash'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: uses set -euo pipefail" {
    run bash -c "head -5 '$HANDLER_SCRIPT' | grep -q 'set -euo pipefail'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: sources session-manager.sh" {
    run bash -c "grep -q 'source.*session-manager.sh' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Action handling tests
# =============================================================================

@test "review-status-handler: supports init action" {
    run bash -c "grep -q '\"init\")' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: supports get-status action" {
    run bash -c "grep -q '\"get-status\")' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: supports get-ready-data action" {
    run bash -c "grep -q '\"get-ready-data\")' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: supports get-error-data action" {
    run bash -c "grep -q '\"get-error-data\")' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: supports get-ambiguous-data action" {
    run bash -c "grep -q '\"get-ambiguous-data\")' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: supports get-prompt-data action" {
    run bash -c "grep -q '\"get-prompt-data\")' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: supports get-prompt-pull-data action" {
    run bash -c "grep -q '\"get-prompt-pull-data\")' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: supports get-find-data action" {
    run bash -c "grep -q '\"get-find-data\")' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: supports get-session-file action" {
    run bash -c "grep -q '\"get-session-file\")' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: supports cleanup action" {
    run bash -c "grep -q '\"cleanup\")' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: supports cleanup-old action" {
    run bash -c "grep -q '\"cleanup-old\")' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: has unknown action handler" {
    run bash -c "grep -q 'Unknown action' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Session ID validation tests
# =============================================================================

@test "review-status-handler: get-status requires session ID" {
    run bash -c "grep -A10 '\"get-status\")' '$HANDLER_SCRIPT' | grep -q 'Session ID required'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: get-ready-data requires session ID" {
    run bash -c "grep -A10 '\"get-ready-data\")' '$HANDLER_SCRIPT' | grep -q 'Session ID required'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: get-error-data requires session ID" {
    run bash -c "grep -A10 '\"get-error-data\")' '$HANDLER_SCRIPT' | grep -q 'Session ID required'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: get-session-file requires session ID" {
    run bash -c "grep -A10 '\"get-session-file\")' '$HANDLER_SCRIPT' | grep -q 'Session ID required'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: cleanup requires session ID" {
    run bash -c "grep -A10 '\"cleanup\")' '$HANDLER_SCRIPT' | grep -q 'Session ID required'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Status validation tests
# =============================================================================

@test "review-status-handler: get-error-data validates status is error" {
    run bash -c "grep -A15 '\"get-error-data\")' '$HANDLER_SCRIPT' | grep -q 'Status is not.*error'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: get-ready-data validates status is ready" {
    run bash -c "grep -A15 '\"get-ready-data\")' '$HANDLER_SCRIPT' | grep -q 'Status is not.*ready'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: get-ambiguous-data validates status is ambiguous" {
    run bash -c "grep -A15 '\"get-ambiguous-data\")' '$HANDLER_SCRIPT' | grep -q 'Status is not.*ambiguous'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: get-prompt-data validates status is prompt" {
    run bash -c "grep -A15 '\"get-prompt-data\")' '$HANDLER_SCRIPT' | grep -q 'Status is not.*prompt'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: get-find-data validates status is find" {
    run bash -c "grep -A15 '\"get-find-data\")' '$HANDLER_SCRIPT' | grep -q 'Status is not.*find'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Session manager integration tests
# =============================================================================

@test "review-status-handler: init uses session_init" {
    run bash -c "grep -A10 '\"init\")' '$HANDLER_SCRIPT' | grep -q 'session_init'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: get-status uses session_get" {
    run bash -c "grep -A10 '\"get-status\")' '$HANDLER_SCRIPT' | grep -q 'session_get'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: cleanup uses session_cleanup" {
    run bash -c "grep -A10 '\"cleanup\")' '$HANDLER_SCRIPT' | grep -q 'session_cleanup'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: cleanup-old uses session_cleanup_old" {
    run bash -c "grep -A5 '\"cleanup-old\")' '$HANDLER_SCRIPT' | grep -q 'session_cleanup_old'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: get-session-file uses session_file" {
    run bash -c "grep -A10 '\"get-session-file\")' '$HANDLER_SCRIPT' | grep -q 'session_file'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Orchestrator discovery tests
# =============================================================================

@test "review-status-handler: has find_orchestrator function" {
    run bash -c "grep -q '^find_orchestrator()' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: find_orchestrator checks multiple locations" {
    run bash -c "grep -A15 '^find_orchestrator()' '$HANDLER_SCRIPT' | grep -c 'review-orchestrator.sh'"
    [ "$output" -ge 3 ]
}

@test "review-status-handler: find_orchestrator errors if not found" {
    run bash -c "grep -A15 '^find_orchestrator()' '$HANDLER_SCRIPT' | grep -q 'Cannot find review-orchestrator.sh'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Output format tests
# =============================================================================

@test "review-status-handler: get-ambiguous-data outputs JSON" {
    run bash -c "grep -A20 '\"get-ambiguous-data\")' '$HANDLER_SCRIPT' | grep -q 'jq'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: get-prompt-data outputs JSON" {
    run bash -c "grep -A20 '\"get-prompt-data\")' '$HANDLER_SCRIPT' | grep -q 'jq'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: cleanup outputs confirmation message" {
    run bash -c "grep -A10 '\"cleanup\")' '$HANDLER_SCRIPT' | grep -q 'Session cleaned up'"
    [ "$status" -eq 0 ]
}
