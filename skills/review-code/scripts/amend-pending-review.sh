#!/usr/bin/env bash
# amend-pending-review.sh - Reword or drop single comments in your pending review
#
# Correcting one comment used to cost a whole re-review: create-draft-review.sh
# replaces a pending review wholesale, and --draft only runs at the end of a
# review, so changing a sentence meant re-running every agent, renumbering every
# comment, and discarding anything edited by hand on GitHub. This amends the
# review that is already there.
#
# Usage: amend-pending-review.sh [PR] [OPTIONS]
#
# PR can be:
#   (none)              Infer from the current branch
#   NUMBER              PR number in the current repo
#   GITHUB_PR_URL       Full PR URL
#
# Options:
#   --review-file PATH   Review notes to compare against (default: resolved from the PR)
#   --pull               Copy changed bodies from GitHub into the notes
#   --push               Send changed bodies from the notes to GitHub
#   --drop               Delete the named comments from the pending review
#   --comment-id ID      Restrict --push or --drop to this comment (repeatable)
#   --reason TEXT        Why a dropped finding was withdrawn, recorded in the notes
#   --reviewer LOGIN     Whose pending review to amend (default: gh api user)
#   --dry-run            Show what would change without calling the API
#   --json               Output as JSON
#   -h, --help           Show this help message
#
# With no --pull/--push/--drop, reports each recorded comment as in sync,
# changed on GitHub, changed in the notes, diverged, or missing.
#
# Rewording goes through the GraphQL updatePullRequestReviewComment mutation.
# The REST endpoint cannot do it: GET and PATCH on /pulls/comments/{id} both
# 404 for a comment that is still pending, though DELETE on that same path
# works, which is why dropping is REST and rewording is GraphQL.
#
# This script cannot submit a review. It never calls POST .../reviews or
# .../events, and every comment it touches must already belong to the caller's
# own pending review.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/gh-wrapper.sh
source "${SCRIPT_DIR}/helpers/gh-wrapper.sh"
# shellcheck source=helpers/gh-review-helpers.sh
source "${SCRIPT_DIR}/helpers/gh-review-helpers.sh"

# ── Logging ──────────────────────────────────────────────────────────────────
# Log to stderr so stdout stays clean for JSON consumers.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

usage() {
    sed -n '2,39p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ── PR target resolution ─────────────────────────────────────────────────────
# Vendored from resolve-review-threads.sh, which vendors it in turn. Keep the
# three copies in step.

parse_pr_url() {
    local url="$1"
    if [[ "$url" =~ ^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
        OWNER="${BASH_REMATCH[1]}"
        REPO_NAME="${BASH_REMATCH[2]}"
        REPO="${OWNER}/${REPO_NAME}"
        PR_NUMBER="${BASH_REMATCH[3]}"
        return 0
    fi
    return 1
}

get_current_repo() {
    gh repo view --json nameWithOwner -q '.nameWithOwner' 2> /dev/null || {
        log_error "Could not determine repository. Run from inside a repo or pass a full PR URL."
        exit 1
    }
}

resolve_pr_target() {
    local pr_arg="${1:-}"
    if [[ -z "$pr_arg" ]]; then
        local pr_url
        pr_url=$(gh pr view --json url -q '.url' 2> /dev/null) || {
            log_error "No PR found for the current branch. Specify a PR number or URL."
            exit 1
        }
        if ! parse_pr_url "$pr_url"; then
            log_error "Could not parse PR URL from current branch: ${pr_url}"
            exit 1
        fi
    elif parse_pr_url "$pr_arg"; then
        :
    elif [[ "$pr_arg" =~ ^[0-9]+$ ]]; then
        PR_NUMBER="$pr_arg"
        REPO=$(get_current_repo)
        OWNER="${REPO%%/*}"
        REPO_NAME="${REPO##*/}"
    else
        log_error "Invalid PR argument: ${pr_arg}"
        log_error "Expected a PR number or URL (https://github.com/owner/repo/pull/123)."
        exit 1
    fi
}

resolve_reviewer() {
    if [[ -n "${REVIEWER}" ]]; then
        return
    fi
    REVIEWER=$(gh api user --jq '.login' 2> /dev/null || true)
    if [[ -z "${REVIEWER}" ]]; then
        log_error "Could not determine your GitHub login. Pass --reviewer LOGIN."
        exit 1
    fi
}

resolve_review_file() {
    if [[ -n "${REVIEW_FILE}" ]]; then
        return
    fi
    REVIEW_FILE=$("${SCRIPT_DIR}/review-file-path.sh" --org "${OWNER}" --repo "${REPO_NAME}" \
        "pr-${PR_NUMBER}" 2> /dev/null | jq -r '.file_path // ""')
    if [[ -z "${REVIEW_FILE}" ]]; then
        log_error "Could not resolve a review file for ${REPO}#${PR_NUMBER}. Pass --review-file PATH."
        exit 1
    fi
}

# ── Rendering ────────────────────────────────────────────────────────────────

# Show a comment in full before changing or deleting it. Pending comments carry
# no line number of their own (the API returns line and original_line null and
# only sets position), so the line shown is the one the notes recorded.
echo_comment() {
    local label="$1" comment="$2"
    local id path line position
    read -r id path line position < <(
        echo "${comment}" | jq -r '[.id, .path, (.line // "-"), (.position // "-")] | @tsv'
    )
    {
        echo
        echo "${label} ${id}: ${path}:${line} (diff position ${position})"
        echo "────────────────────────────────────────────────────────────────────────"
        echo "${comment}" | jq -r '.notes_body // .live_body // ""'
        echo "────────────────────────────────────────────────────────────────────────"
    } >&2
}

display_status() {
    local status_json="$1"
    local total
    total=$(echo "${status_json}" | jq '.comments | length')
    log_info "${REPO}#${PR_NUMBER}: ${total} recorded comment(s) in ${REVIEW_FILE}"
    echo "${status_json}" | jq -r '
        .comments[]
        | "  \(.id)  \(.state)  \(.path):\(.line)"
    ' >&2
    local unrecorded
    unrecorded=$(echo "${status_json}" | jq '.unrecorded | length')
    if [[ "${unrecorded}" -gt 0 ]]; then
        log_warn "${unrecorded} comment(s) on GitHub are not recorded in the notes; they are left alone."
    fi
}

# ── Safety ───────────────────────────────────────────────────────────────────

# The membership check is the whole safety argument, not a nicety. DELETE on
# /pulls/comments/{id} will happily remove a published comment, including a
# teammate's, given permissions. Scoping every id to the caller's own pending
# review is the only thing standing between a reword and someone else's review.
# Refuse the entire run rather than mutating a prefix of it.
validate_ids() {
    local pending="$1"
    shift
    local bad=()
    local id
    for id in "$@"; do
        if [[ "$(echo "${pending}" | jq --argjson id "${id}" '[.comments[] | select(.id == $id)] | length')" -eq 0 ]]; then
            bad+=("${id}")
        fi
    done
    if [[ ${#bad[@]} -gt 0 ]]; then
        log_error "Not in your pending review on ${REPO}#${PR_NUMBER}: ${bad[*]}"
        log_error "Run without --push/--drop to list the comments you can amend."
        exit 1
    fi
}

# ── Mutations ────────────────────────────────────────────────────────────────

reword_comment() {
    local node_id="$1" body="$2"
    # shellcheck disable=SC2016  # GraphQL document; $id and $body are GraphQL
    # variables bound by --f, not shell expansions.
    gh api graphql \
        -f query='mutation($id: ID!, $body: String!) {
            updatePullRequestReviewComment(input: {pullRequestReviewCommentId: $id, body: $body}) {
                pullRequestReviewComment { databaseId }
            }
        }' \
        -f id="${node_id}" -f body="${body}" > /dev/null
}

drop_comment() {
    local id="$1"
    gh api --method DELETE "repos/${OWNER}/${REPO_NAME}/pulls/comments/${id}" > /dev/null
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    local pr_arg=""
    REVIEW_FILE=""
    REVIEWER=""
    REASON=""
    local mode="status"
    local dry_run=false
    local json_output=false
    local -a comment_ids=()

    while (("$#")); do
        case "$1" in
            --review-file)
                [[ -n "${2:-}" ]] || {
                    log_error "--review-file requires a path"
                    exit 1
                }
                REVIEW_FILE="$2"
                shift 2
                ;;
            --reason)
                [[ -n "${2:-}" ]] || {
                    log_error "--reason requires text"
                    exit 1
                }
                REASON="$2"
                shift 2
                ;;
            --reviewer)
                [[ -n "${2:-}" ]] || {
                    log_error "--reviewer requires a login"
                    exit 1
                }
                REVIEWER="$2"
                shift 2
                ;;
            --comment-id)
                [[ "${2:-}" =~ ^[0-9]+$ ]] || {
                    log_error "--comment-id requires a numeric REST API comment ID, got: ${2:-}"
                    exit 1
                }
                comment_ids+=("$2")
                shift 2
                ;;
            --pull | --push | --drop)
                if [[ "${mode}" != "status" ]]; then
                    log_error "Choose one of --pull, --push, or --drop; they are separate runs."
                    exit 1
                fi
                mode="${1#--}"
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --json)
                json_output=true
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                usage >&2
                exit 1
                ;;
            *)
                if [[ -n "${pr_arg}" ]]; then
                    log_error "Unexpected argument: $1"
                    usage >&2
                    exit 1
                fi
                pr_arg="$1"
                shift
                ;;
        esac
    done

    if [[ "${mode}" == "drop" && ${#comment_ids[@]} -eq 0 ]]; then
        log_error "--drop requires at least one --comment-id. Refusing to drop every comment."
        exit 1
    fi
    if [[ -n "${REASON}" && "${mode}" != "drop" ]]; then
        log_error "--reason only applies to --drop."
        exit 1
    fi
    if [[ "${mode}" == "pull" && ${#comment_ids[@]} -gt 0 ]]; then
        log_error "--comment-id does not apply to --pull, which reconciles the whole review."
        exit 1
    fi

    resolve_pr_target "${pr_arg}"
    resolve_reviewer
    resolve_review_file

    if [[ ! -f "${REVIEW_FILE}" ]]; then
        log_error "Review file not found: ${REVIEW_FILE}"
        exit 1
    fi

    local pending
    pending=$(get_existing_pending_review "${OWNER}" "${REPO_NAME}" "${PR_NUMBER}" "${REVIEWER}")
    if [[ "${pending}" == "null" ]]; then
        if [[ "${mode}" == "status" ]]; then
            log_info "No pending review by ${REVIEWER} on ${REPO}#${PR_NUMBER}."
            [[ "${json_output}" == "true" ]] && jq -n '{comments: [], counts: {}, unrecorded: []}'
            exit 0
        fi
        log_error "No pending review by ${REVIEWER} on ${REPO}#${PR_NUMBER}. Nothing to amend."
        exit 1
    fi

    # One normalizer, in Python, so the shell never invents a second notion of
    # "changed" that disagrees with the one that wrote the digests.
    local status_json
    status_json=$(echo "${pending}" | jq -c '.comments' \
        | "${SCRIPT_DIR}/review-comment-blocks.py" status --review-file "${REVIEW_FILE}")

    case "${mode}" in
        status) do_status "${status_json}" "${json_output}" ;;
        pull) do_pull "${status_json}" "${dry_run}" "${json_output}" ;;
        push) do_push "${status_json}" "${dry_run}" "${json_output}" "${comment_ids[@]+"${comment_ids[@]}"}" ;;
        drop) do_drop "${pending}" "${status_json}" "${dry_run}" "${json_output}" "${comment_ids[@]}" ;;
        *)
            log_error "Unhandled mode '${mode}'."
            exit 1
            ;;
    esac
}

do_status() {
    local status_json="$1" json_output="$2"
    if [[ "${json_output}" == "true" ]]; then
        echo "${status_json}" | jq '{review_id, counts, unrecorded,
            comments: [.comments[] | {id, node_id, path, line, position, state}]}'
    else
        display_status "${status_json}"
    fi
}

do_pull() {
    local status_json="$1" dry_run="$2" json_output="$3"
    local targets
    targets=$(echo "${status_json}" | jq -c '[.comments[]
        | select(.state == "changed_on_github" or .state == "diverged" or .state == "unknown_baseline")]')
    local count
    count=$(echo "${targets}" | jq 'length')

    if [[ "${count}" -eq 0 ]]; then
        log_info "Notes already match GitHub; nothing to pull."
        [[ "${json_output}" == "true" ]] && echo "${status_json}" | jq '{pulled: 0, dryRun: false}'
        return 0
    fi

    local comment
    while IFS= read -r comment; do
        echo_comment "Replacing notes body for comment" "${comment}"
    done < <(echo "${targets}" | jq -c '.[]')

    if [[ "${dry_run}" == "true" ]]; then
        log_info "Dry run: would update ${count} block(s) in ${REVIEW_FILE}."
        [[ "${json_output}" == "true" ]] && echo "${targets}" | jq '{pulled: 0, dryRun: true, comments: [.[] | {id, state}]}'
        return 0
    fi

    echo "${targets}" | jq -c '[.[] | {id, body: .live_body}]' \
        | "${SCRIPT_DIR}/review-comment-blocks.py" set-body --review-file "${REVIEW_FILE}" > /dev/null
    refresh_digests
    log_success "Pulled ${count} comment(s) from GitHub into ${REVIEW_FILE}."
    [[ "${json_output}" == "true" ]] && echo "${targets}" | jq '{pulled: length, dryRun: false, comments: [.[] | {id, state}]}'
    return 0
}

do_push() {
    local status_json="$1" dry_run="$2" json_output="$3"
    shift 3
    local -a wanted=("$@")

    local targets
    targets=$(echo "${status_json}" | jq -c '[.comments[] | select(.state == "changed_in_notes")]')
    if [[ ${#wanted[@]} -gt 0 ]]; then
        local ids_json
        ids_json=$(printf '%s\n' "${wanted[@]}" | jq -s 'map(tonumber)')
        targets=$(echo "${targets}" | jq -c --argjson ids "${ids_json}" '[.[] | select(.id as $i | $ids | index($i) != null)]')
    fi

    # Refuse rather than clobber. A body that moved on GitHub is someone's hand
    # edit, and overwriting it silently is the failure this tool exists to stop.
    local blocked
    blocked=$(echo "${status_json}" | jq -c '[.comments[]
        | select(.state == "changed_on_github" or .state == "diverged")]')
    if [[ "$(echo "${blocked}" | jq 'length')" -gt 0 ]]; then
        log_error "These comments changed on GitHub since the notes were written:"
        echo "${blocked}" | jq -r '.[] | "  \(.id)  \(.path):\(.line)  (\(.state))"' >&2
        log_error "Run --pull first to bring those edits into the notes, then reword and push."
        exit 1
    fi

    local count
    count=$(echo "${targets}" | jq 'length')
    if [[ "${count}" -eq 0 ]]; then
        log_info "No reworded comments to push."
        [[ "${json_output}" == "true" ]] && jq -n '{pushed: 0, failed: 0, dryRun: false}'
        return 0
    fi

    local comment
    while IFS= read -r comment; do
        echo_comment "Rewording comment" "${comment}"
    done < <(echo "${targets}" | jq -c '.[]')

    if [[ "${dry_run}" == "true" ]]; then
        log_info "Dry run: would reword ${count} comment(s) on ${REPO}#${PR_NUMBER}."
        [[ "${json_output}" == "true" ]] && echo "${targets}" | jq '{pushed: 0, failed: 0, dryRun: true, comments: [.[] | {id}]}'
        return 0
    fi

    local pushed=0 failed=0 id node_id body
    while IFS=$'\t' read -r id node_id; do
        body=$(echo "${targets}" | jq -r --argjson id "${id}" '.[] | select(.id == $id) | .notes_body')
        if reword_comment "${node_id}" "${body}"; then
            log_success "Reworded ${id}"
            pushed=$((pushed + 1))
        else
            log_warn "Failed to reword ${id}"
            failed=$((failed + 1))
        fi
    done < <(echo "${targets}" | jq -r '.[] | [.id, .node_id] | @tsv')

    refresh_digests
    [[ "${json_output}" == "true" ]] && jq -n --argjson pushed "${pushed}" --argjson failed "${failed}" \
        '{pushed: $pushed, failed: $failed, dryRun: false}'
    if [[ "${failed}" -gt 0 ]]; then
        log_error "${failed} comment(s) failed to reword."
        return 1
    fi
    return 0
}

do_drop() {
    local pending="$1" status_json="$2" dry_run="$3" json_output="$4"
    shift 4
    local -a wanted=("$@")

    validate_ids "${pending}" "${wanted[@]}"

    local ids_json targets
    ids_json=$(printf '%s\n' "${wanted[@]}" | jq -s 'map(tonumber)')
    targets=$(echo "${status_json}" | jq -c --argjson ids "${ids_json}" \
        '[.comments[] | select(.id as $i | $ids | index($i) != null)]')

    # An id can be in the pending review but absent from the notes, so fall
    # back to the live comment rather than skipping it.
    if [[ "$(echo "${targets}" | jq 'length')" -lt ${#wanted[@]} ]]; then
        targets=$(echo "${pending}" | jq -c --argjson ids "${ids_json}" \
            '[.comments[] | select(.id as $i | $ids | index($i) != null)
              | {id, node_id, path, line, position, live_body: .body}]')
    fi

    local comment
    while IFS= read -r comment; do
        echo_comment "Dropping comment" "${comment}"
    done < <(echo "${targets}" | jq -c '.[]')

    if [[ "${dry_run}" == "true" ]]; then
        log_info "Dry run: would drop ${#wanted[@]} comment(s) from ${REPO}#${PR_NUMBER}."
        [[ "${json_output}" == "true" ]] && echo "${targets}" | jq '{dropped: 0, failed: 0, dryRun: true, comments: [.[] | {id, path}]}'
        return 0
    fi

    local dropped=0 failed=0 id
    for id in "${wanted[@]}"; do
        if drop_comment "${id}"; then
            log_success "Dropped ${id}"
            dropped=$((dropped + 1))
        else
            log_warn "Failed to drop ${id}"
            failed=$((failed + 1))
        fi
    done

    # Retire the finding in the notes, so carry-forward does not re-propose it
    # and a later --draft does not repost it. Only the ids that actually went.
    if [[ "${dropped}" -gt 0 ]]; then
        printf '%s\n' "${wanted[@]}" \
            | jq -R --arg reason "${REASON}" -s 'split("\n") | map(select(length > 0))
                | map({id: tonumber, reason: $reason})' \
            | "${SCRIPT_DIR}/review-comment-blocks.py" withdraw \
                --review-file "${REVIEW_FILE}" \
                --date "$(date -u +%Y-%m-%d)" > /dev/null || {
            log_warn "Dropped on GitHub, but could not mark the finding withdrawn in ${REVIEW_FILE}."
            log_warn "Mark it by hand, or a later re-review may re-propose it."
        }
    fi

    local remaining
    remaining=$(gh api "repos/${OWNER}/${REPO_NAME}/pulls/${PR_NUMBER}/reviews/$(echo "${pending}" | jq -r '.review_id')/comments" \
        --paginate 2> /dev/null | jq 'length' 2> /dev/null || echo "?")
    log_info "${remaining} comment(s) remain in the pending review."
    if [[ "${remaining}" == "0" ]]; then
        log_warn "That was the last inline comment. The pending review still exists with its summary body."
    fi

    [[ "${json_output}" == "true" ]] && jq -n --argjson dropped "${dropped}" --argjson failed "${failed}" \
        --arg remaining "${remaining}" '{dropped: $dropped, failed: $failed, remaining: $remaining, dryRun: false}'
    if [[ "${failed}" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Re-stamp the last-synced digests so the next run can still tell which side
# moved. Best effort: a stale digest makes the next push refuse and --pull
# re-syncs, which is the safe direction to fail in.
refresh_digests() {
    local live
    live=$(gh api "repos/${OWNER}/${REPO_NAME}/pulls/${PR_NUMBER}/reviews/$(
        get_existing_pending_review "${OWNER}" "${REPO_NAME}" "${PR_NUMBER}" "${REVIEWER}" | jq -r '.review_id'
    )/comments" --paginate 2> /dev/null || echo "[]")
    echo "${live}" | "${SCRIPT_DIR}/review-comment-blocks.py" annotate \
        --review-file "${REVIEW_FILE}" > /dev/null 2>&1 || true
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
