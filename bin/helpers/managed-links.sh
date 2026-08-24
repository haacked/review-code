# shellcheck shell=sh

# Symlink helpers shared by the Codex installer and a future bin/setup rewrite.
#
# Requires `warning` from the caller, so source or define that first.

# install_managed_link SOURCE DESTINATION MANAGED_PREFIX
#
# Point DESTINATION at SOURCE, but never clobber a file this repo does not own.
# A regular file is left alone, and so is a symlink resolving outside
# MANAGED_PREFIX; both warn and skip. MANAGED_PREFIX is matched as a literal
# prefix of the existing link target, which is what lets a moved staging
# directory still count as ours and get relinked in place.
#
# Returns 0 when DESTINATION points at SOURCE and 1 when the link was skipped,
# so callers can report what actually happened instead of announcing success
# either way. Callers under `set -e` must therefore invoke this in an `if` or
# `||` context; a bare call aborts the script on the first destination it
# cannot own.
# POSIX sh has no `local`, and the caller (bin/install-codex.sh) is `#!/bin/sh`,
# so the argument names below are prefixed to stay out of the caller's namespace.
install_managed_link() {
    _managed_source="$1"
    _managed_destination="$2"
    _managed_prefix="$3"
    if [ -e "$_managed_destination" ] && [ ! -L "$_managed_destination" ]; then
        warning "$_managed_destination is not a symlink; skipping"
        return 1
    elif [ -L "$_managed_destination" ]; then
        case "$(readlink "$_managed_destination")" in
            "$_managed_prefix"*) ln -sfn "$_managed_source" "$_managed_destination" ;;
            *)
                warning "$_managed_destination is unmanaged; skipping"
                return 1
                ;;
        esac
    else
        ln -s "$_managed_source" "$_managed_destination"
    fi
}
