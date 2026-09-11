#!/bin/sh

set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

# shellcheck source=/dev/null
. "$REPO_ROOT/bin/helpers/managed-links.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

error() {
    echo "${RED}Error: $1${NC}" >&2
}

warning() {
    echo "${YELLOW}Warning: $1${NC}"
}

success() {
    echo "${GREEN}✓ $1${NC}"
}

info() {
    echo "${BLUE}$1${NC}"
}

UNINSTALL=false

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Install the review-code agents as Codex custom agents."
    echo ""
    echo "  --uninstall   Remove managed Codex agent links"
    echo "  -h, --help    Show this help"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --uninstall) UNINSTALL=true ;;
        -h | --help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
    shift
done

# Must match MANAGED_HEADER in bin/render-codex-agents.py. If the two drift, a
# managed regular file stops being recognized as ours, remove_managed_agents
# leaves it in place, and that agent never updates again.
MANAGED_AGENT_HEADER="# Managed by bin/install-codex.sh from the review-code repo."

CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
CODEX_AGENTS_STAGING="$CODEX_HOME_DIR/.review-code-agents"
CODEX_AGENTS_DIR="$CODEX_HOME_DIR/agents"

remove_managed_agents() {
    [ -d "$CODEX_AGENTS_DIR" ] || return 0
    for agent in "$CODEX_AGENTS_DIR"/*.toml; do
        [ -e "$agent" ] || [ -L "$agent" ] || continue
        if [ -L "$agent" ]; then
            case "$(readlink "$agent")" in
                "$CODEX_AGENTS_STAGING"/*) rm -f "$agent" ;;
                # A link pointing anywhere else is someone else's; leave it.
                *) ;;
            esac
        elif [ "$(head -n 1 "$agent")" = "$MANAGED_AGENT_HEADER" ]; then
            rm -f "$agent"
        fi
    done
}

if [ "$UNINSTALL" = "true" ]; then
    info "Uninstalling review-code Codex agents…"
    remove_managed_agents
    rm -rf "$CODEX_AGENTS_STAGING"
    success "Codex agents uninstalled"
    exit 0
fi

info "Installing review-code Codex agents…"
# Codex scans ~/.codex/agents recursively and does not skip dot-directories,
# so staging the rendered TOML in there would register every agent twice.
mkdir -p "$CODEX_AGENTS_STAGING" "$CODEX_AGENTS_DIR"
# Render before removing, so a renderer failure under `set -e` leaves the
# previously installed agents in place instead of an empty directory. The
# removal still has to precede the relink loop, or a leftover managed regular
# file makes install_managed_link skip its destination.
python3 "$REPO_ROOT/bin/render-codex-agents.py" "$REPO_ROOT/agents" "$CODEX_AGENTS_STAGING"
remove_managed_agents
shadowed_agents=""
for agent in "$CODEX_AGENTS_STAGING"/*.toml; do
    [ -f "$agent" ] || continue
    agent_name=$(basename "$agent")
    destination="$CODEX_AGENTS_DIR/$agent_name"
    if ! install_managed_link "$agent" "$destination" "$CODEX_AGENTS_STAGING/"; then
        shadowed_agents="$shadowed_agents $agent_name"
    fi
done
if [ -n "$shadowed_agents" ]; then
    error "Not linked, a file already occupies the destination:$shadowed_agents"
    info "Move or delete those files under $CODEX_AGENTS_DIR, then re-run."
else
    success "Installed Codex custom agents"
fi
