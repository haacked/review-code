#!/usr/bin/env bash
set -euo pipefail

# carry-forward-findings.sh - Update a review document in place after a delta review.
#
# A delta re-review looks only at the files that changed since the last pass, so
# the earlier review's findings on untouched files are still good and its
# findings on touched files have just been re-derived. Merging those two by hand
# means the orchestrator reads the old document (median 11.7KB, p90 29.7KB) and
# writes it back out, on the run that is supposed to be the cheap one. This does
# the merge on disk instead: the old bodies never enter a conversation.
#
# The work is: cut the findings whose file the delta touched, append whatever the
# run composed, and move the metadata header forward to the SHA just reviewed.
#
# Usage:
#   carry-forward-findings.sh --review-file <path> --delta-diff <path> [options]
#
# Options:
#   --append-file <path>  Markdown to append after the carried-forward content
#   --head-sha <sha>      New review_commit for the metadata header
#   --delta-from <sha>    Recorded as delta_from in the metadata header
#   --reviewed-at <iso>   Header timestamp (default: now, UTC)
#   --dry-run             Report what would happen; change nothing
#
# Output: a JSON object on stdout. It carries finding identity (agent, file,
# line) and never a description, which is the whole point: identity is small,
# bodies are not.
#   {"review_file": "...", "carried": 7, "dropped": 3, "kept_unattributed": 1,
#    "kept_undeletable": 0, "delta_files": 2, "pruned": true, "appended": true,
#    "header_updated": true, "dropped_files": ["a.py"],
#    "carried_findings": [{"agent": "security", "file": "b.py", "line": 45}]}
#
# Safety: after cutting, the pruned document is re-parsed and its findings must
# match the set that was meant to survive. On any mismatch the cut is abandoned
# and the original content is kept ("pruned": false, with a reason). A review
# that still lists a stale finding is a nuisance; one whose bodies got spliced
# together is a liability.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=helpers/error-helpers.sh
source "${SCRIPT_DIR}/helpers/error-helpers.sh"

REVIEW_FILE=""
DELTA_DIFF=""
APPEND_FILE=""
HEAD_SHA=""
DELTA_FROM=""
REVIEWED_AT=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --review-file)
            REVIEW_FILE="${2:-}"
            shift 2
            ;;
        --delta-diff)
            DELTA_DIFF="${2:-}"
            shift 2
            ;;
        --append-file)
            APPEND_FILE="${2:-}"
            shift 2
            ;;
        --head-sha)
            HEAD_SHA="${2:-}"
            shift 2
            ;;
        --delta-from)
            DELTA_FROM="${2:-}"
            shift 2
            ;;
        --reviewed-at)
            REVIEWED_AT="${2:-}"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            error "Unknown argument: $1"
            exit 1
            ;;
    esac
done

if [[ -z "${REVIEW_FILE}" ]]; then
    error "--review-file is required"
    exit 1
fi
if [[ ! -f "${REVIEW_FILE}" ]]; then
    error "Review file not found: ${REVIEW_FILE}"
    exit 1
fi
if [[ -z "${DELTA_DIFF}" ]]; then
    error "--delta-diff is required"
    exit 1
fi
if [[ ! -f "${DELTA_DIFF}" ]]; then
    error "Delta diff not found: ${DELTA_DIFF}"
    exit 1
fi
if [[ -n "${APPEND_FILE}" && ! -f "${APPEND_FILE}" ]]; then
    error "Append file not found: ${APPEND_FILE}"
    exit 1
fi

REVIEWED_AT="${REVIEWED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

# ------------------------------------------------------------- the delta's files
# Both sides of each header are taken: a rename or a delete names the old path.
extract_delta_files() {
    sed -n -e 's/^--- a\///p' -e 's/^+++ b\///p' "${DELTA_DIFF}" \
        | grep -v '^/dev/null$' \
        | sed 's/[[:space:]]*$//' \
        | grep -v '^$' \
        | sort -u
}

DELTA_FILES_TXT="${WORK_DIR}/delta-files.txt"
extract_delta_files > "${DELTA_FILES_TXT}"
DELTA_FILES_JSON=$(jq -R -s 'split("\n") | map(select(length > 0))' < "${DELTA_FILES_TXT}")
DELTA_FILE_COUNT=$(jq 'length' <<< "${DELTA_FILES_JSON}")

# ------------------------------------------------------------------- classify
FINDINGS=$("${SCRIPT_DIR}/parse-review-findings.sh" --with-spans "${REVIEW_FILE}")

# A finding belongs to the delta when the paths match outright, or when the
# review cited a bare filename that matches a delta file's basename. Nothing
# looser: a fuzzy match drops a finding no agent will re-derive.
CLASSIFIED=$(jq -c --argjson touched "${DELTA_FILES_JSON}" '
    ($touched | map(split("/") | last)) as $bases
    | [ .[] as $f
        | $f + { touched: (
            $f.file != ""
            and (
                ($touched | index($f.file)) != null
                or (($f.file | contains("/") | not) and ($bases | index($f.file)) != null)
            )
        ) } ]
' <<< "${FINDINGS}")

DELETABLE=$(jq -c '[ .[] | select(.touched and .deletable) ]' <<< "${CLASSIFIED}")
KEPT_UNDELETABLE=$(jq -c '[ .[] | select(.touched and (.deletable | not)) ]' <<< "${CLASSIFIED}")
CARRIED=$(jq -c '[ .[] | select(.touched | not) ]' <<< "${CLASSIFIED}")

DROPPED_COUNT=$(jq 'length' <<< "${DELETABLE}")
KEPT_UNDELETABLE_COUNT=$(jq 'length' <<< "${KEPT_UNDELETABLE}")
CARRIED_COUNT=$(jq 'length' <<< "${CARRIED}")
UNATTRIBUTED_COUNT=$(jq '[ .[] | select(.file == "") ] | length' <<< "${CARRIED}")

RANGES=$(jq -r '[ .[] | select(.start_line > 0 and .end_line >= .start_line)
    | "\(.start_line)-\(.end_line)" ] | join(",")' <<< "${DELETABLE}")

# Identity of everything that must still be there once the cut is made.
identity() {
    jq -S -c '[ .[] | {agent, file, line} ] | sort'
}
EXPECTED=$(jq -c -s 'add' <<< "${CARRIED}"$'\n'"${KEPT_UNDELETABLE}" | identity)

# ----------------------------------------------------------------------- prune
PRUNED_FILE="${WORK_DIR}/pruned.md"
PRUNE_REASON=""
PRUNED=false

if [[ -z "${RANGES}" ]]; then
    cp "${REVIEW_FILE}" "${PRUNED_FILE}"
    PRUNE_REASON="no findings on the delta's files"
else
    # Cut each finding's lines, then swallow the blank lines it left behind so
    # exactly one blank separates the neighbours it stood between.
    awk -v ranges="${RANGES}" '
        BEGIN {
            n = split(ranges, parts, ",")
            for (i = 1; i <= n; i++) {
                split(parts[i], se, "-")
                start[i] = se[1] + 0
                end[i] = se[2] + 0
            }
            swallow = 0
        }
        {
            cut = 0
            for (i = 1; i <= n; i++) {
                if (NR >= start[i] && NR <= end[i]) {
                    cut = 1
                    if (NR == end[i]) swallow = 1
                    break
                }
            }
            if (cut) next
            if (swallow) {
                if ($0 ~ /^[[:space:]]*$/) next
                swallow = 0
            }
            print
        }
    ' "${REVIEW_FILE}" > "${PRUNED_FILE}"

    ACTUAL=$("${SCRIPT_DIR}/parse-review-findings.sh" "${PRUNED_FILE}" | identity)
    if [[ "${ACTUAL}" == "${EXPECTED}" ]]; then
        PRUNED=true
    else
        cp "${REVIEW_FILE}" "${PRUNED_FILE}"
        PRUNE_REASON="the pruned document did not re-parse to the expected findings; kept every finding instead"
    fi
fi

# --------------------------------------------------------------- header, append
OUT_FILE="${WORK_DIR}/out.md"
HEADER_UPDATED=false

if grep -q 'review-metadata' "${REVIEW_FILE}"; then
    HEADER_UPDATED=true
fi

awk -v head_sha="${HEAD_SHA}" -v reviewed_at="${REVIEWED_AT}" \
    -v delta_from="${DELTA_FROM}" '
    BEGIN { in_meta = 0; done_meta = 0 }
    {
        if (!done_meta && !in_meta && $0 ~ /review-metadata/) {
            in_meta = 1
            print
            next
        }
        if (in_meta) {
            if ($0 ~ /^[[:space:]]*-->/) {
                if (head_sha != "" && !seen_commit) print "review_commit: " head_sha
                if (!seen_reviewed) print "reviewed_at: " reviewed_at
                if (!seen_mode) print "review_mode: delta"
                if (delta_from != "" && !seen_from) print "delta_from: " delta_from
                in_meta = 0
                done_meta = 1
                print
                next
            }
            if (head_sha != "" && $0 ~ /^review_commit:/) {
                print "review_commit: " head_sha
                seen_commit = 1
                next
            }
            if ($0 ~ /^reviewed_at:/) {
                print "reviewed_at: " reviewed_at
                seen_reviewed = 1
                next
            }
            if ($0 ~ /^review_mode:/) {
                print "review_mode: delta"
                seen_mode = 1
                next
            }
            if (delta_from != "" && $0 ~ /^delta_from:/) {
                print "delta_from: " delta_from
                seen_from = 1
                next
            }
        }
        print
    }
' "${PRUNED_FILE}" > "${OUT_FILE}"

APPENDED=false
if [[ -n "${APPEND_FILE}" ]]; then
    printf '\n---\n\n' >> "${OUT_FILE}"
    cat "${APPEND_FILE}" >> "${OUT_FILE}"
    APPENDED=true
fi

if [[ "${DRY_RUN}" == false ]]; then
    # Same directory, so the rename is atomic: a reader sees the old document or
    # the new one, never a half-written merge.
    TARGET_TMP="${REVIEW_FILE}.carry-forward.$$"
    cp "${OUT_FILE}" "${TARGET_TMP}"
    mv "${TARGET_TMP}" "${REVIEW_FILE}"
fi

jq -nc \
    --arg review_file "${REVIEW_FILE}" \
    --arg prune_reason "${PRUNE_REASON}" \
    --argjson carried "${CARRIED_COUNT}" \
    --argjson dropped "${DROPPED_COUNT}" \
    --argjson kept_unattributed "${UNATTRIBUTED_COUNT}" \
    --argjson kept_undeletable "${KEPT_UNDELETABLE_COUNT}" \
    --argjson delta_files "${DELTA_FILE_COUNT}" \
    --argjson pruned "${PRUNED}" \
    --argjson appended "${APPENDED}" \
    --argjson header_updated "${HEADER_UPDATED}" \
    --argjson dry_run "${DRY_RUN}" \
    --argjson dropped_list "${DELETABLE}" \
    --argjson carried_list "${CARRIED}" \
    '{
        review_file: $review_file,
        carried: $carried,
        dropped: $dropped,
        kept_unattributed: $kept_unattributed,
        kept_undeletable: $kept_undeletable,
        delta_files: $delta_files,
        pruned: $pruned,
        appended: $appended,
        header_updated: $header_updated,
        dry_run: $dry_run,
        dropped_files: ($dropped_list | map(.file) | unique),
        carried_findings: ($carried_list | map({agent, file, line}))
    }
    + (if $prune_reason != "" then {prune_reason: $prune_reason} else {} end)'
