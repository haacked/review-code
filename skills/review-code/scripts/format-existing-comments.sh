#!/usr/bin/env bash
set -euo pipefail

# format-existing-comments.sh - Render a PR's existing review comments as a
# compact markdown block for the reviewer briefing.
#
# Existing Review Comments is briefing.md's largest and only-unbounded
# section: pr-context.sh fetches every conversation comment, review, and
# inline comment (with reply chains) in full. Left verbatim, a busy PR's
# comment history dwarfs the diff it exists to give context for. This script
# collapses each inline thread to its root comment plus a one-line summary of
# its replies, reduces a resolved or outdated thread to a single index line
# (the point was already settled or the code has since moved), and caps every
# surviving body. The session file still holds the untruncated text.
#
# Usage:
#   format-existing-comments.sh < comments.json
#
# Input (stdin): the `.pr.comments` object — {conversation, reviews, inline}.
# An inline comment carries `resolved`/`outdated` booleans when pr-context.sh
# could determine thread state (see merge_thread_state); a comment without
# them is treated as open.
#
# Output: markdown bullet lines, one per conversation comment, one per review,
# and one or two per inline thread (root, plus a reply summary when the
# thread is open and has replies).

BODY_CAP=800
REPLY_PREVIEW_CAP=150
INDEX_PREVIEW_CAP=100

jq -r \
    --argjson body_cap "${BODY_CAP}" \
    --argjson reply_cap "${REPLY_PREVIEW_CAP}" \
    --argjson index_cap "${INDEX_PREVIEW_CAP}" '
def trunc($n):
  if . == null then ""
  elif (length > $n) then (.[0:$n] + "…")
  else . end;

def firstline($n):
  (split("\n")[0]) | trunc($n);

( (.conversation // [])[] | "- [conversation] @\(.author): \(.body | trunc($body_cap))" ),

( (.reviews // [])[] | "- [review/\(.state // "comment")] @\(.author): \((.body // "") | trunc($body_cap))" ),

( (.inline // [])
  | group_by(.in_reply_to_id // .id)
  | map(sort_by(.id))
  | .[]
  | . as $thread
  | (($thread | map(select(.in_reply_to_id == null)) | first) // $thread[0]) as $root
  | ($thread | length) as $n
  | if ($root.resolved == true or $root.outdated == true) then
      "- [inline, \(if $root.resolved then "resolved" else "outdated" end)] @\($root.author) \($root.path):\($root.line // "?"): \($root.body | firstline($index_cap))"
    else
      (
        "- [inline] @\($root.author) \($root.path):\($root.line // "?"): \($root.body | trunc($body_cap))",
        (if $n > 1 then
          ($thread[-1]) as $last
          | "  (\($n - 1) repl\(if ($n - 1) == 1 then "y" else "ies" end), last by @\($last.author): \($last.body | firstline($reply_cap)))"
        else empty end)
      )
    end
)
'
