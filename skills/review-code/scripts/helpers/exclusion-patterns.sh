#!/usr/bin/env bash
# Shared git diff exclusion patterns
#
# Usage:
#   source lib/helpers/exclusion-patterns.sh
#   mapfile -t patterns < <(get_exclusion_patterns extended)
#
# Modes:
#   common   - Minimal exclusions (lock files, minified code, build outputs)
#   extended - Comprehensive exclusions (includes snapshots, generated files, IDE files)

# Source error helpers (use local variable to avoid overwriting caller's SCRIPT_DIR)
_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers/error-helpers.sh
source "${_HELPER_DIR}/error-helpers.sh"

get_exclusion_patterns() {
    local mode="${1:-default}"

    # Common patterns - noise files that add no review value
    local common=(
        # Lock files
        ':!package-lock.json'
        ':!pnpm-lock.yaml'
        ':!yarn.lock'
        ':!Cargo.lock'

        # Minified code
        ':!*.min.js'
        ':!*.min.css'

        # Build outputs
        ':!dist/'
        ':!build/'
        ':!.generated/'
    )

    # Extended patterns - comprehensive noise filtering
    local extended=(
        # Snapshot files (testing artifacts)
        ':!*.ambr'
        ':!*.snap'
        ':!**/__snapshots__/**'

        # Additional lock files
        ':!uv.lock'
        ':!poetry.lock'
        ':!Gemfile.lock'
        ':!Pipfile.lock'
        ':!composer.lock'
        ':!go.sum'

        # Generated/compiled files
        ':!*.pyc'
        ':!**/__pycache__/**'
        ':!*.map'
        ':!*.js.map'
        ':!*.css.map'
        ':!*.wasm'

        # Additional build artifacts
        ':!target/**'
        ':!*.tsbuildinfo'
        ':!.next/**'
        ':!out/**'

        # IDE and editor files
        ':!.DS_Store'
        ':!*.swp'
        ':!*.swo'
        ':!*~'
    )

    case "${mode}" in
        extended)
            printf '%s\n' "${common[@]}" "${extended[@]}"
            ;;
        common | default)
            printf '%s\n' "${common[@]}"
            ;;
        *)
            error "Unknown exclusion mode: ${mode}"
            echo "Valid modes: common, extended" >&2
            return 1
            ;;
    esac
}
