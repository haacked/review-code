#!/usr/bin/env bash
# install.sh - One-liner installer for review-code
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/haacked/review-code/main/install.sh | bash
#
# Or with custom branch:
#   curl -fsSL https://raw.githubusercontent.com/haacked/review-code/main/install.sh | BRANCH=develop bash

set -euo pipefail

# Configuration
REPO_URL="https://github.com/haacked/review-code"
BRANCH="${BRANCH:-main}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() {
    echo -e "${GREEN}✓${NC} $1"
}

warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

error() {
    echo -e "${RED}✗${NC} $1"
}

main() {
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Review-Code Installer"
    echo "═══════════════════════════════════════════════════════"
    echo ""

    # Create temporary directory
    TEMP_DIR=$(mktemp -d)

    # Ensure cleanup on exit
    # shellcheck disable=SC2064
    trap "rm -rf '${TEMP_DIR}'" EXIT

    # Clone repository to temp directory
    info "Downloading review-code (branch: ${BRANCH})…"
    if ! git clone --depth 1 --branch "${BRANCH}" "${REPO_URL}" "${TEMP_DIR}" &> /dev/null; then
        error "Failed to clone repository"
        exit 1
    fi

    # Run installer from temp directory
    info "Running installer…"
    cd "${TEMP_DIR}"
    # Redirect stdin from terminal so bin/setup can prompt for user input
    if ! bin/setup < /dev/tty; then
        error "Installation failed"
        exit 1
    fi

    # Cleanup happens automatically via trap
    info "Cleaned up temporary files"

    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo ""
    info "Installation complete!"
    echo ""
    echo "Review-code is now ready to use:"
    echo "  - Run: /review-code"
    echo "  - Review PR: /review-code <pr-number>"
    echo "  - Specific review: /review-code security"
    echo ""
    echo "To update: Re-run this installer"
    echo "To uninstall: Run ~/.claude/bin/uninstall-review-code.sh"
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo ""
}

main "$@"
