#!/usr/bin/env bash

# Common utility functions for scripts

# Print colored text
print_color() {
    case $1 in
        red) echo -e "\033[31m$2\033[0m" ;;
        green) echo -e "\033[32m$2\033[0m" ;;
        yellow) echo -e "\033[33m$2\033[0m" ;;
        blue) echo -e "\033[34m$2\033[0m" ;;
        *) echo "$2" ;;
    esac
}

# Print error to stderr in red
error() {
    print_color red "Error: $*" >&2
}

# Print error and exit
fatal() {
    error "$*"
    exit 1
}

# Set source and root directories, cd to root
set_source_and_root_dir() {
    { set +x; } 2> /dev/null
    source_dir="$(cd -P "$(dirname "$0")" > /dev/null 2>&1 && pwd)"
    root_dir=$(cd "$source_dir" && cd ../ && pwd)
    cd "$root_dir" || fatal "Could not change to root directory: $root_dir"
}

# Check if command exists
command_exists() {
    command -v "$1" > /dev/null 2>&1
}

# Print warning in yellow
warning() {
    print_color yellow "Warning: $*" >&2
}

# Print success in green
success() {
    print_color green "✓ $*"
}

# Run command with description
run_command() {
    local cmd="$1"
    local desc="${2:-Running command}"
    echo "→ $desc"
    [[ -n "${VERBOSE:-}" ]] && echo "  $cmd"
    if ! eval "$cmd"; then
        error "Command failed: $cmd"
        return 1
    fi
}

# Check required commands exist
require_commands() {
    local missing=()
    for cmd in "$@"; do
        command_exists "$cmd" || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] || fatal "Missing commands: ${missing[*]}"
}

# Show help from script comments
show_help() {
    sed -n 's/^#\/ \?//p' "$0"
}

# Parse common arguments
parse_common_args() {
    while (("$#")); do
        case "$1" in
            -h | --help)
                show_help
                exit 0
                ;;
            -v | --verbose)
                export VERBOSE=1
                shift
                ;;
            *)
                shift
                ;;
        esac
    done
}

# Collect every shell script in the repo into the shell_files array. Tests under
# tests/unit and tests/integration are .bats, a dialect that neither shfmt nor
# our linter parses, so bin/test covers those instead.
# Every Python file bin/fmt and bin/lint act on. Kept beside
# collect_shell_files so the two languages are enumerated the same way and a
# new directory is one edit rather than two.
collect_python_files() {
    local patterns=(
        bin/*
        skills/review-code/scripts/*.py
        skills/review-code/scripts/helpers/*.py
        evals/scripts/*.py
    )

    python_files=()
    local pattern file
    for pattern in "${patterns[@]}"; do
        for file in ${pattern}; do
            [[ -f "${file}" ]] || continue
            # A .py extension is enough; anything else has to declare a python
            # shebang, which is what picks up extensionless tools in bin/.
            if [[ "${file}" == *.py ]] || { [[ -x "${file}" ]] && head -1 "${file}" | grep -q '^#!/.*python'; }; then
                python_files+=("${file}")
            fi
        done
    done
}

collect_shell_files() {
    local patterns=(
        bin/*
        bin/helpers/*.sh
        skills/review-code/scripts/*.sh
        skills/review-code/scripts/helpers/*.sh
        skills/review-code/scripts/session-hooks/*.sh
        evals/scripts/*.sh
        evals/scripts/helpers/*.sh
        tests/helpers/*.bash
        *.sh
    )

    shell_files=()
    local pattern file
    for pattern in "${patterns[@]}"; do
        for file in ${pattern}; do
            [[ -f "${file}" ]] || continue
            # A .sh or .bash extension is enough on its own; the bats helpers
            # under tests/ use .bash and are sourced, so they are never
            # executable. Anything else has to declare a bash shebang, which is
            # what keeps non-shell entries like bin/README.md out.
            if [[ "${file}" == *.sh || "${file}" == *.bash ]] || { [[ -x "${file}" ]] && head -1 "${file}" | grep -q '^#!/.*bash'; }; then
                shell_files+=("${file}")
            fi
        done
    done
}
