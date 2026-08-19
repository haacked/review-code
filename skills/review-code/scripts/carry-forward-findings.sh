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
#   --dry-run             Report what would happen; change nothing
#
# Output: a JSON object on stdout. Counts and flags only, plus the list of files
# whose findings were cut, which is bounded by the delta. No finding bodies and
# no per-finding array: this output lands in the orchestrator's conversation and
# stays there for the rest of the run.
#   {"review_file": "...", "carried": 7, "dropped": 3, "kept_unattributed": 1,
#    "kept_undeletable": 0, "delta_files": 2, "pruned": true, "appended": true,
#    "header_updated": true, "dropped_files": ["a.py"]}
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

REVIEWED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

# ------------------------------------------------------------- the delta's files
# Read from the "diff --git a/OLD b/NEW" header rather than the ---/+++ lines,
# which git omits for a pure rename and for a mode-only change. Both sides are
# taken: a finding recorded before a rename cites the old path. Matching on
# " b/" with its leading space is the same idiom as chunk-diff.sh and
# split-diff-by-path.sh, and for the same reason: a last-field split would
# truncate any path containing a space.
extract_delta_files() {
    awk '
        /^diff --git / {
            if (match($0, / b\//)) {
                old = substr($0, 14, RSTART - 14)
                new = substr($0, RSTART + 3)
                if (old != "") print old
                if (new != "") print new
            }
        }
    ' "${DELTA_DIFF}" | sort -u
}

DELTA_FILES_TXT="${WORK_DIR}/delta-files.txt"
extract_delta_files > "${DELTA_FILES_TXT}"
DELTA_FILES_JSON=$(jq -R -s 'split("\n") | map(select(length > 0))' < "${DELTA_FILES_TXT}")

# ------------------------------------------------------------------- classify
# A finding belongs to the delta when the paths match outright, or when the
# review cited a bare filename that matches a delta file's basename. Nothing
# looser: a fuzzy match drops a finding no agent will re-derive.
#
# One pass emits the three partitions the rest of the script needs; the counts
# are read off them at output time rather than tallied into variables here.
CLASSIFIED=$("${SCRIPT_DIR}/parse-review-findings.sh" --with-spans "${REVIEW_FILE}" \
    | jq -c --argjson touched "${DELTA_FILES_JSON}" '
        ($touched | map(split("/") | last)) as $bases
        | [ .[] as $f
            | $f + { touched: (
                $f.file != ""
                and (
                    ($touched | index($f.file)) != null
                    or (($f.file | contains("/") | not) and ($bases | index($f.file)) != null)
                )
            ) } ]
        | { dropped: [ .[] | select(.touched and .deletable) ],
            kept_undeletable: [ .[] | select(.touched and (.deletable | not)) ],
            carried: [ .[] | select(.touched | not) ] }')

RANGES=$(jq -r '[ .dropped[] | select(.start_line > 0 and .end_line >= .start_line)
    | "\(.start_line)-\(.end_line)" ] | join(",")' <<< "${CLASSIFIED}")

# What must still be there once the cut is made. The description is part of it:
# comparing {agent, file, line} alone would pass on a cut that left a dropped
# finding's trailing prose behind for a surviving finding to absorb, which is
# the exact failure this check exists to catch.
identity() {
    jq -S -c '[ .[] | {agent, file, line, description} ] | sort'
}

# ----------------------------------------------------------------------- prune
PRUNED_FILE="${WORK_DIR}/pruned.md"
PRUNE_REASON=""
PRUNED=false

if [[ -z "${RANGES}" ]]; then
    # Nothing to cut, so the original stands as the base the append lands on.
    PRUNED_FILE="${REVIEW_FILE}"
    PRUNE_REASON="no findings on the delta's files"
else
    EXPECTED=$(jq -c '.carried + .kept_undeletable' <<< "${CLASSIFIED}" | identity)
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
        PRUNED_FILE="${REVIEW_FILE}"
        PRUNE_REASON="the pruned document did not re-parse to the expected findings; kept every finding instead"
    fi
fi

# --------------------------------------------------------------- header, append
OUT_FILE="${WORK_DIR}/out.md"

# The awk below is the only thing that knows whether a header was actually
# advanced, so it reports that itself rather than having a grep guess at it
# over a different file.
HEADER_UPDATED=true

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
    END { exit(done_meta ? 0 : 1) }
' "${PRUNED_FILE}" > "${OUT_FILE}" || HEADER_UPDATED=false

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
    --argjson classified "${CLASSIFIED}" \
    --argjson delta_files_list "${DELTA_FILES_JSON}" \
    --argjson pruned "${PRUNED}" \
    --argjson appended "${APPENDED}" \
    --argjson header_updated "${HEADER_UPDATED}" \
    --argjson dry_run "${DRY_RUN}" \
    '{
        review_file: $review_file,
        carried: ($classified.carried | length),
        dropped: ($classified.dropped | length),
        kept_unattributed: ([ $classified.carried[] | select(.file == "") ] | length),
        kept_undeletable: ($classified.kept_undeletable | length),
        delta_files: ($delta_files_list | length),
        pruned: $pruned,
        appended: $appended,
        header_updated: $header_updated,
        dry_run: $dry_run,
        dropped_files: ($classified.dropped | map(.file) | unique)
    }
    + (if $prune_reason != "" then {prune_reason: $prune_reason} else {} end)'
