#!/usr/bin/env python3
"""Read and rewrite the finding blocks a review file posted as PR comments.

A pending review comment cannot be found again from the review document alone:
the document holds a path, a line and a body, and none of those survive as a
stable key once the author edits the comment on GitHub or the PR takes new
commits. Recording the comment's id in the document at post time is what lets a
later session reconcile the two and reword one comment instead of re-running
the whole review.

The id rides on the finding's heading, inside an HTML comment:

    #### `posthog/feature_flags.py:784` <!-- pc:3846146537 PRRC_kwDO…lP4np b:3f9a2c1e -->

The third token is a digest of the body as of the last sync. Without it, notes
and GitHub give two values that can only say *that* they differ, never which
side moved, so a reword pushed over someone's hand edit would be
indistinguishable from a clean push. With it, the three-way comparison names
the side that changed and `--push` can refuse when GitHub is the one that did.

That position is deliberate. parse-review-findings.sh never lets a heading line
reach a finding's `description` and its header pattern is unanchored on the
right, so the annotation changes nothing it parses; the annotation still sits
inside the finding's span, so carry-forward-findings.sh cuts it along with the
finding rather than leaving it orphaned; and both linters skip the Suggested
Comments section entirely.

Subcommands:

  annotate   Record ids after a draft post. Reads the posted comments as JSON on
             stdin (as GET /pulls/{n}/reviews/{id}/comments returns them).
             Fails open: the review is already posted by the time this runs, so
             an internal failure is reported and exits 0 rather than turning a
             successful post into a script error.

  read       Emit the recorded blocks as JSON. Nothing in the pipeline calls
             this; it is the way to inspect what a review file has recorded,
             by hand or from a test. Fails loud so an unreadable file is not
             mistaken for a file with nothing recorded in it.

  set-body   Replace the fenced body of the blocks named on stdin, as
             [{"id": N, "body": "..."}]. Fails loud, for the same reason.

  withdraw   Mark blocks as withdrawn, from [{"id": N, "reason": "..."}] on
             stdin. The block stays where it is so the argument that retired it
             stays on the record; it simply stops counting as a live finding.

  status     Classify each recorded block against the live pending review, read
             as JSON on stdin. Comparison lives here rather than in the calling
             shell so there is one normalizer: a second one would drift, and
             drift invents "changed" states the push guard exists to catch.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path

FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")

# Mirrors finding_header_re in parse-review-findings.sh, plus a trailing group
# so an annotation already present is replaced instead of doubled.
HEADING = re.compile(
    r"^(?P<open>#{3,4}[ \t]+(?:\d+\.[ \t]+)?`?)"
    r"(?P<path>[^:`]+):(?P<line>\d+)"
    r"(?P<close>`?)"
    r"(?P<rest>.*)$"
)

ANNOTATION = re.compile(r"\s*<!--\s*pc:(?P<ids>.*?)-->")

BODY_HASH_PREFIX = "b:"
WITHDRAWN_PREFIX = "withdrawn:"

METADATA_OPEN = re.compile(r"^<!--\s*review-metadata\b")


def normalize(text: str) -> str:
    """Compare bodies ignoring differences GitHub does not preserve."""
    return "\n".join(line.rstrip() for line in text.strip().splitlines()).strip()


def body_hash(text: str) -> str:
    """Digest a body so a later run can tell which side of a sync moved."""
    return hashlib.sha256(normalize(text).encode("utf-8")).hexdigest()[:8]


def parse_annotation(rest: str) -> dict:
    """Pull the comment id, node id, last-synced digest and withdrawal off a heading."""
    match = ANNOTATION.search(rest)
    parsed: dict = {
        "id": None,
        "node_id": None,
        "body_hash": None,
        "withdrawn": None,
    }
    if not match:
        return parsed
    for token in match.group("ids").split():
        if token.startswith(BODY_HASH_PREFIX):
            parsed["body_hash"] = token[len(BODY_HASH_PREFIX) :]
        elif token.startswith(WITHDRAWN_PREFIX):
            parsed["withdrawn"] = token[len(WITHDRAWN_PREFIX) :]
        elif token.isdigit():
            parsed["id"] = int(token)
        else:
            parsed["node_id"] = token
    return parsed


def find_blocks(lines: list[str]) -> list[dict]:
    """Locate every finding heading and the fenced body beneath it.

    The fence walk matters: a finding body can quote markdown that contains
    something heading-shaped, and treating that as a new finding would attach
    the wrong comment id to it.
    """
    blocks: list[dict] = []
    fence = ""
    for index, line in enumerate(lines):
        marker = FENCE.match(line)
        token = marker.group(1) if marker else ""
        if fence:
            if marker and token.startswith(fence) and not line[marker.end() :].strip():
                fence = ""
            continue
        if token:
            fence = token
            continue
        match = HEADING.match(line)
        if match:
            body_start, body_end = body_span(lines, index + 1)
            annotation = parse_annotation(match.group("rest"))
            annotation["withdrawn"] = annotation["withdrawn"] or prose_withdrawal(
                lines, body_end if body_end is not None else index
            )
            blocks.append(
                {
                    "index": index,
                    "path": match.group("path").strip().strip("`"),
                    "line": int(match.group("line")),
                    **annotation,
                    "body_start": body_start,
                    "body_end": body_end,
                    "body": (
                        "\n".join(lines[body_start:body_end])
                        if body_start is not None
                        else ""
                    ),
                }
            )
    return blocks


def body_span(lines: list[str], start: int) -> tuple[int | None, int | None]:
    """Return the line range of the first fenced block after a heading.

    That fence is the comment text. A heading or thematic break reached before
    any fence means the finding has no comment body.
    """
    fence = ""
    open_at = None
    for offset, line in enumerate(lines[start:], start=start):
        marker = FENCE.match(line)
        token = marker.group(1) if marker else ""
        if not fence:
            if token:
                fence = token
                open_at = offset + 1
                continue
            if line.startswith("#") or line.strip().startswith("---"):
                return None, None
            continue
        if marker and token.startswith(fence) and not line[marker.end() :].strip():
            return open_at, offset
    return None, None


def prose_withdrawal(lines: list[str], start: int) -> str | None:
    """Find a `*Withdrawn ...*` line in the block's tail, if there is one.

    parse-review-findings.sh accepts this marker as well as the heading token,
    so a review that was never posted as a draft can still retire a finding.
    Reading only the token here would leave such a block looking live, and the
    annotate filter would then let a new finding at the same path and line
    claim it. Bounded by the next heading or thematic break so it cannot reach
    into the following finding.
    """
    for line in lines[start + 1 :]:
        if line.startswith("#") or line.strip().startswith("---"):
            return None
        if line.startswith("*Withdrawn"):
            return line.strip().strip("*") or "yes"
    return None


def match_comments(blocks: list[dict], comments: list[dict]) -> tuple[dict, list]:
    """Pair each posted comment with the block that produced it.

    Body is the primary key, not path:line. Drift remapping can move a comment
    to a different line than the heading records, and two findings can share a
    line, so the text is the only thing that reliably identifies the block.
    """
    taken: set[int] = set()
    pairs: dict[int, dict] = {}
    unmatched: list[dict] = []

    for comment in comments:
        path = (comment.get("path") or "").strip()
        body = normalize(comment.get("body") or "")
        chosen = None
        for block in blocks:
            if block["index"] in taken or block["path"] != path:
                continue
            if body and normalize(block["body"]) == body:
                chosen = block
                break
        if chosen is None:
            for block in blocks:
                if block["index"] in taken or block["path"] != path:
                    continue
                if block["line"] == comment.get("line"):
                    chosen = block
                    break
        if chosen is None:
            unmatched.append({"id": comment.get("id"), "path": path})
            continue
        taken.add(chosen["index"])
        pairs[chosen["index"]] = comment
    return pairs, unmatched


def annotate_heading(line: str, comment: dict) -> str:
    match = HEADING.match(line)
    if not match:
        return line
    rest = ANNOTATION.sub("", match.group("rest")).rstrip()
    ids = " ".join(
        str(v)
        for v in (
            comment.get("id"),
            comment.get("node_id"),
            BODY_HASH_PREFIX + body_hash(comment.get("body") or ""),
        )
        if v
    )
    return (
        f"{match.group('open')}{match.group('path')}:{match.group('line')}"
        f"{match.group('close')}{rest} <!-- pc:{ids} -->"
    )


def stamp_withdrawn(line: str, date: str) -> str:
    """Add the withdrawal to the heading annotation, keeping the ids.

    The ids stay so the record shows which comment was retired. Readers filter
    on the withdrawal rather than on a missing id, which keeps "never posted"
    and "posted then withdrawn" distinguishable.
    """
    match = HEADING.match(line)
    if not match:
        return line
    annotation = ANNOTATION.search(match.group("rest"))
    tokens = annotation.group("ids").split() if annotation else []
    tokens = [t for t in tokens if not t.startswith(WITHDRAWN_PREFIX)]
    tokens.append(f"{WITHDRAWN_PREFIX}{date}")
    rest = ANNOTATION.sub("", match.group("rest")).rstrip()
    return (
        f"{match.group('open')}{match.group('path')}:{match.group('line')}"
        f"{match.group('close')}{rest} <!-- pc:{' '.join(tokens)} -->"
    )


def header_span(lines: list[str]) -> tuple[int | None, int | None]:
    """Locate the first review-metadata block.

    Only the first: review files on disk sometimes carry a second one from an
    earlier append, and the first is the one every other reader takes.
    """
    start = next((i for i, line in enumerate(lines) if METADATA_OPEN.match(line)), None)
    if start is None:
        return None, None
    end = next(
        (i for i in range(start + 1, len(lines)) if lines[i].strip().startswith("-->")),
        None,
    )
    return (start, end) if end is not None else (None, None)


def header_field(lines: list[str], key: str) -> str | None:
    start, end = header_span(lines)
    if start is None:
        return None
    for line in lines[start + 1 : end]:
        head, _, value = line.partition(":")
        if head.strip() == key:
            return value.strip()
    return None


def update_header(lines: list[str], review_id, posted_at) -> bool:
    if review_id is None:
        return False
    start, end = header_span(lines)
    if start is None:
        return False

    fields = {"review_id": str(review_id)}
    if posted_at:
        fields["posted_at"] = posted_at

    kept = [
        line
        for line in lines[start + 1 : end]
        if line.split(":", 1)[0].strip() not in fields
    ]
    # Sit above the nested blocks so the scalars stay together and nothing
    # reads as if it belonged to scope: or token_usage:.
    insert = next(
        (i for i, line in enumerate(kept) if line.rstrip().endswith(":")), len(kept)
    )
    added = [f"{key}: {value}" for key, value in fields.items()]
    lines[start + 1 : end] = kept[:insert] + added + kept[insert:]
    return True


def write_atomic(path: Path, lines: list[str], suffix: str) -> None:
    """Replace the file in one step.

    write_text truncates first, so a write that failed part-way would leave the
    review a partial file, and a fail-open caller would report that as a clean
    skip.
    """
    tmp = path.with_name(f".{path.name}.{suffix}")
    try:
        tmp.write_text("\n".join(lines) + "\n", encoding="utf-8")
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def cmd_annotate(args, lines: list[str], path: Path) -> dict:
    comments = load_stdin_list()
    # A withdrawn block is never a candidate. Its finding was retired and its
    # text was not reposted, so body matching cannot reach it, but the
    # path-and-line fallback would: a new finding at the same location would
    # take the retired block's annotation, wiping the withdrawal and bringing
    # the finding back to life while the real new block got nothing.
    live = [b for b in find_blocks(lines) if not b["withdrawn"]]
    pairs, unmatched = match_comments(live, comments)
    for index, comment in pairs.items():
        lines[index] = annotate_heading(lines[index], comment)
    header_updated = update_header(lines, args.review_id, args.posted_at)
    if pairs or header_updated:
        write_atomic(path, lines, "pc-ids")
    return {
        "annotated": len(pairs),
        "unmatched": unmatched,
        "header_updated": header_updated,
    }


# What the three bodies say about who moved. `recorded` is the digest written
# at the last sync, so it is the only thing that distinguishes an edit made on
# GitHub from one made in the notes.
def classify(notes: str, live: str, recorded: str | None) -> str:
    # Settle the agreeing case before consulting the digest. A digest that went
    # stale (a dropped network call during a refresh, say) would otherwise read
    # as `diverged` on two identical bodies, which accuses someone of a UI edit
    # they did not make and leaves --push refusing with nothing to reconcile.
    if normalize(notes) == normalize(live):
        return "in_sync"
    if recorded is None:
        # Annotated before digests existed, or hand-edited. Two differing
        # values can report disagreement but never attribute it.
        return "unknown_baseline"
    notes_moved = body_hash(notes) != recorded
    live_moved = body_hash(live) != recorded
    if notes_moved and live_moved:
        return "diverged"
    if live_moved:
        return "changed_on_github"
    if notes_moved:
        return "changed_in_notes"
    return "in_sync"


def cmd_status(args, lines: list[str], path: Path) -> dict:
    live_by_id = {int(c["id"]): c for c in load_stdin_list() if c.get("id") is not None}
    blocks = [
        b for b in find_blocks(lines) if b["id"] is not None and not b["withdrawn"]
    ]

    comments = []
    for block in blocks:
        live = live_by_id.pop(block["id"], None)
        if live is None:
            state, live_body = "missing_on_github", None
        else:
            live_body = live.get("body") or ""
            state = classify(block["body"], live_body, block["body_hash"])
        comments.append(
            {
                "id": block["id"],
                # GitHub's node id wins over the one on the heading. The numeric
                # id is checked against the pending review, but the node id is
                # what the reword mutation actually addresses, and it is read
                # from a file anyone can edit; taking the live one keeps the
                # header's claim that every comment touched is the caller's own.
                # The recorded one still covers a live comment with none.
                "node_id": (live or {}).get("node_id") or block["node_id"],
                "path": block["path"],
                "line": block["line"],
                "position": (live or {}).get("position"),
                "state": state,
                "notes_body": block["body"],
                "live_body": live_body,
            }
        )

    counts: dict[str, int] = {}
    for comment in comments:
        counts[comment["state"]] = counts.get(comment["state"], 0) + 1

    return {
        "review_id": header_field(lines, "review_id"),
        "comments": comments,
        "counts": counts,
        # Live comments with no block: posted by hand, or by a review whose
        # notes were overwritten. Never acted on, only reported.
        "unrecorded": [
            {"id": c.get("id"), "path": c.get("path")} for c in live_by_id.values()
        ],
    }


def cmd_withdraw(args, lines: list[str], path: Path) -> dict:
    wanted = {int(item["id"]): (item.get("reason") or "") for item in load_stdin_list()}
    date = args.date or "unknown date"
    blocks = [b for b in find_blocks(lines) if b["id"] in wanted and not b["withdrawn"]]

    # Bottom-up, so inserting a line never shifts a span still to be edited.
    for block in sorted(blocks, key=lambda b: b["index"], reverse=True):
        reason = wanted[block["id"]]
        note = f"*Withdrawn {date}{': ' + reason if reason else ''}*"
        # Under the fenced body, or straight under the heading when there is no
        # fence to sit below. A block with no body reaches here: annotate's
        # path-and-line fallback matches one even though body matching cannot,
        # and stamping the heading while skipping the note would retire the
        # finding with the reason written down nowhere.
        anchor = block["index"] if block["body_end"] is None else block["body_end"]
        lines.insert(anchor + 1, "")
        lines.insert(anchor + 2, note)
        lines[block["index"]] = stamp_withdrawn(lines[block["index"]], date)

    if blocks:
        write_atomic(path, lines, "pc-withdraw")
    return {
        "withdrawn": len(blocks),
        "missing": sorted(set(wanted) - {b["id"] for b in blocks}),
    }


def cmd_read(args, lines: list[str], path: Path) -> dict:
    blocks = [
        b for b in find_blocks(lines) if b["id"] is not None and not b["withdrawn"]
    ]
    return {
        "review_id": header_field(lines, "review_id"),
        "posted_at": header_field(lines, "posted_at"),
        "comments": [
            {
                "id": b["id"],
                "node_id": b["node_id"],
                "path": b["path"],
                "line": b["line"],
                "body": b["body"],
                "body_hash": b["body_hash"],
            }
            for b in blocks
        ],
    }


def cmd_set_body(args, lines: list[str], path: Path) -> dict:
    wanted = {int(item["id"]): item["body"] for item in load_stdin_list()}
    # Rewriting a retired finding's body is never right; it is kept as the
    # record of what was argued, not as something still in play.
    blocks = [b for b in find_blocks(lines) if b["id"] in wanted and not b["withdrawn"]]
    found = {b["id"] for b in blocks}

    # Rewrite from the bottom so earlier spans keep their indices.
    updated = 0
    for block in sorted(blocks, key=lambda b: b["index"], reverse=True):
        if block["body_start"] is None:
            continue
        body = wanted[block["id"]].splitlines() or [""]
        lines[block["body_start"] : block["body_end"]] = body
        updated += 1
    if updated:
        write_atomic(path, lines, "pc-body")
    return {
        "updated": updated,
        "missing": sorted(set(wanted) - found),
    }


def load_stdin_list() -> list[dict]:
    payload = json.load(sys.stdin)
    if not isinstance(payload, list):
        raise ValueError("expected a JSON array")
    return payload


COMMANDS = {
    "annotate": cmd_annotate,
    "read": cmd_read,
    "set-body": cmd_set_body,
    "status": cmd_status,
    "withdraw": cmd_withdraw,
}

# annotate runs after the review is already on GitHub, where a hard failure
# would misreport a successful post. read and set-body drive an amend, where a
# silent empty result would let the caller act on the wrong thing.
FAIL_OPEN = {"annotate"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=sorted(COMMANDS))
    parser.add_argument("--review-file", required=True)
    parser.add_argument("--review-id")
    parser.add_argument("--posted-at")
    parser.add_argument("--date")
    args = parser.parse_args()

    result: dict = {"error": None}
    try:
        path = Path(args.review_file)
        lines = path.read_text(encoding="utf-8").splitlines()
        result.update(COMMANDS[args.command](args, lines, path))
    except Exception as exc:  # noqa: BLE001 - see FAIL_OPEN
        result["error"] = str(exc)

    print(json.dumps(result))
    return 1 if result["error"] and args.command not in FAIL_OPEN else 0


if __name__ == "__main__":
    sys.exit(main())
