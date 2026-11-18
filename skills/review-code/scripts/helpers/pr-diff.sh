#!/usr/bin/env bash
# Fetch a PR's unified diff, including PRs too large for GitHub's diff endpoint.
#
# The diff endpoint behind `gh pr diff` refuses a PR it considers too large,
# such as one that changes more than 300 files, with HTTP 406 and the error
# code `too_large`. The PR files API lists up to 3000 files along with each
# file's hunks, so fetch_pr_diff rebuilds the diff from that list instead.
#
# Callers source this after gh-wrapper.sh and error-helpers.sh.

# Print the diff of a PR.
# Args: $1 = pr_number, $2 = repo_spec (owner/repo)
fetch_pr_diff() {
    local pr_number="$1"
    local repo_spec="$2"

    local output
    if output=$(gh pr diff "${pr_number}" --repo "${repo_spec}" 2>&1); then
        printf '%s\n' "${output}"
        return 0
    fi

    if [[ "${output}" != *too_large* ]]; then
        printf '%s\n' "${output}" >&2
        return 1
    fi

    warning "GitHub's diff endpoint refused ${repo_spec}#${pr_number} as too large; building the diff from the PR files API"
    fetch_pr_diff_from_files "${pr_number}" "${repo_spec}"
}

# Print a PR's diff rebuilt from the PR files API.
# Args: $1 = pr_number, $2 = repo_spec (owner/repo)
fetch_pr_diff_from_files() {
    local pr_number="$1"
    local repo_spec="$2"

    local expected files
    expected=$(gh api "repos/${repo_spec}/pulls/${pr_number}" --jq '.changed_files') || return 1
    files=$(gh api --paginate "repos/${repo_spec}/pulls/${pr_number}/files?per_page=100" | jq -s 'add // []') || return 1

    local fetched
    fetched=$(jq 'length' <<< "${files}")
    if [[ "${fetched}" -lt "${expected}" ]]; then
        error "The PR files API returned ${fetched} of the ${expected} files ${repo_spec}#${pr_number} changes. It returns at most 3000 files, so a review would miss the rest. Review the PR from a local checkout instead."
        return 1
    fi

    # GitHub leaves out `patch` for a binary file and for a text file whose
    # diff is too large to show. Only the second kind drops changed lines.
    local omitted
    omitted=$(jq -r '.[] | select(.patch == null and (.additions + .deletions) > 0) | "  " + .filename' <<< "${files}")
    if [[ -n "${omitted}" ]]; then
        warning "GitHub omitted the diff for these files because each one is too large to show, so the review cannot see their changes:"
        printf '%s\n' "${omitted}" >&2
    fi

    files_json_to_diff <<< "${files}"
}

# Convert a PR files API array on stdin into a git-style unified diff.
# Paths are quoted the way git quotes them, so the diff-path parsers in
# git-diff-paths.sh read them unchanged. The API does not report file modes or
# blob ids, so the diff has no index lines. A removed file still gets a
# `deleted file mode` line with a placeholder mode, because git_diff_paths
# detects a deletion from that line when GitHub omits the file's hunks.
files_json_to_diff() {
    jq -r '
        def git_path($prefix):
            ($prefix + .) as $path
            | if $path | test("[\"\\\\\u0001-\u001f\u007f]") then
                {"7": "a", "8": "b", "9": "t", "10": "n", "11": "v", "12": "f", "13": "r", "34": "\"", "92": "\\"} as $named
                | "\"" + ($path | explode | map(
                    if $named[tostring] then "\\" + $named[tostring]
                    elif . < 32 or . == 127 then "\\" + ((. / 64 | floor) | tostring) + (((. % 64) / 8 | floor) | tostring) + ((. % 8) | tostring)
                    else [.] | implode
                    end
                ) | join("")) + "\""
              else
                $path
              end;

        .[]
        | (.previous_filename // .filename) as $old
        | .filename as $new
        | (
            ["diff --git " + ($old | git_path("a/")) + " " + ($new | git_path("b/"))]
            + (if .status == "renamed" then
                ["rename from " + ($old | git_path("")), "rename to " + ($new | git_path(""))]
              elif .status == "copied" then
                ["copy from " + ($old | git_path("")), "copy to " + ($new | git_path(""))]
              else [] end)
            + (if .status == "removed" then ["deleted file mode 100644"] else [] end)
            + (if .patch == null then [] else
                [
                    (if .status == "added" then "--- /dev/null" else "--- " + ($old | git_path("a/")) end),
                    (if .status == "removed" then "+++ /dev/null" else "+++ " + ($new | git_path("b/")) end),
                    (.patch | rtrimstr("\n"))
                ]
              end)
          )
        | join("\n")
    '
}
