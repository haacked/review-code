#!/usr/bin/env bash
# Test helper: a PATH-based `gh` stub executable.
#
# Production code invokes `gh` through a timeout wrapper (gtimeout/timeout/env),
# which execs the binary named on PATH. A bash *function* named `gh` would not
# be seen by those exec calls, so the stub must be a real executable file that
# a prepended PATH entry resolves ahead of the real `gh`.
#
# Usage (in a bats setup()):
#   load '../helpers/gh-stub.bash'   # or source the full path
#   install_default_gh_stub
#   ...
#   stub_gh_pr_list '[{"number":7,"baseRefName":"parent-branch"}]'
# Usage (in teardown()):
#   remove_gh_stub_dir

# Install a stub `gh` executable ahead of the real one on PATH.
# `gh pr list ...` prints "[]" (exit 0); every other subcommand exits 1.
# Every invocation is logged as one line ("$*") to $GH_STUB_CALLS.
install_default_gh_stub() {
    GH_STUB_DIR="$(mktemp -d)"
    export GH_STUB_DIR
    GH_STUB_CALLS="${GH_STUB_DIR}/calls.log"
    export GH_STUB_CALLS
    : > "${GH_STUB_CALLS}"

    GH_STUB_PR_LIST_PAYLOAD_FILE="${GH_STUB_DIR}/pr-list-payload.json"
    export GH_STUB_PR_LIST_PAYLOAD_FILE
    echo "[]" > "${GH_STUB_PR_LIST_PAYLOAD_FILE}"

    GH_STUB_PR_LIST_EXIT_FILE="${GH_STUB_DIR}/pr-list-exit.txt"
    export GH_STUB_PR_LIST_EXIT_FILE
    echo "0" > "${GH_STUB_PR_LIST_EXIT_FILE}"

    cat > "${GH_STUB_DIR}/gh" << 'STUB_EOF'
#!/usr/bin/env bash
# Generated stub gh executable; see tests/helpers/gh-stub.bash.
echo "$*" >> "${GH_STUB_CALLS}"

if [[ "$1" == "pr" && "$2" == "list" ]]; then
    exit_code="$(cat "${GH_STUB_PR_LIST_EXIT_FILE}" 2>/dev/null || echo 0)"
    cat "${GH_STUB_PR_LIST_PAYLOAD_FILE}" 2>/dev/null || echo "[]"
    exit "${exit_code}"
fi

exit 1
STUB_EOF
    chmod +x "${GH_STUB_DIR}/gh"

    PATH="${GH_STUB_DIR}:${PATH}"
    export PATH
}

# Make `gh pr list` print the given JSON payload and exit 0.
# Usage: stub_gh_pr_list '[{"number":7,"baseRefName":"parent-branch"}]'
#
# Make `gh pr list` exit 1 instead (models an auth/network failure).
# Usage: stub_gh_pr_list --fail
stub_gh_pr_list() {
    if [[ "${1:-}" == "--fail" ]]; then
        echo "1" > "${GH_STUB_PR_LIST_EXIT_FILE}"
        echo "" > "${GH_STUB_PR_LIST_PAYLOAD_FILE}"
        return 0
    fi

    # Write via a file rather than inlining the payload in the stub script:
    # payloads are caller-supplied JSON and may contain quoting that would be
    # unsafe to splice directly into a heredoc or single-quoted string.
    printf '%s' "$1" > "${GH_STUB_PR_LIST_PAYLOAD_FILE}"
    echo "0" > "${GH_STUB_PR_LIST_EXIT_FILE}"
}

# Remove the stub directory and drop it from PATH. Call from teardown().
remove_gh_stub_dir() {
    if [[ -n "${GH_STUB_DIR:-}" && -d "${GH_STUB_DIR}" ]]; then
        PATH="${PATH//${GH_STUB_DIR}:/}"
        export PATH
        rm -rf "${GH_STUB_DIR}"
    fi
    unset GH_STUB_DIR GH_STUB_CALLS GH_STUB_PR_LIST_PAYLOAD_FILE GH_STUB_PR_LIST_EXIT_FILE
}
