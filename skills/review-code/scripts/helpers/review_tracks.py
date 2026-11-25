"""Decide which files are spec content and when a review takes the spec track.

The tables at the top are the one place routing names file types and
security terms. The classifier imports this module, and
build-agent-briefing.sh calls its CLI, so no other script repeats them.
"""

import json
import re
import sys

# The first matching row decides a path's kind. A path that no row matches is code.
PATH_RULES = (
    (
        "code",
        r"(^|/)(\.claude|\.agents|\.codex|\.cursor|\.github|agents|skills|commands|prompts|handlers)/",
        "agent prompts and repo automation are executed",
    ),
    ("code", r"(^|/)(SKILL|CLAUDE|AGENTS|GEMINI)\.md$", "agent instruction file"),
    ("spec", r"\.(md|mdx|markdown|rst)$", "prose"),
    ("spec", r"\.feature$", "Gherkin acceptance scenarios"),
    ("spec", r"\.(schema|examples)\.(json|ya?ml)$", "schema or example payloads"),
    (
        "spec",
        r"(^|/)openspec/changes/.+/\.openspec\.ya?ml$",
        "OpenSpec change metadata",
    ),
)

# Areas that run on the spec track. Security joins them under the rules in
# apply_spec_track in classify-review-scope.py. The classifier skips every other area.
SPEC_TRACK_AREAS = ("correctness", "spec", "compatibility", "maintainability")

# Underscores, hyphens, and case changes separate words here, so `user_auth`
# and `requiresAuth` match `auth`, and `SSOConfig` matches `sso`.
_CAMEL_BOUNDARY = re.compile(r"(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])")
_EDGE_BEFORE = r"(?<![a-z0-9])"
_EDGE_AFTER = r"(?![a-z0-9])"
_SEP = r"[\s_-]?"
SECURITY_TERMS = re.compile(
    _EDGE_BEFORE
    + r"(auth[nz]?|authenticat\w*|authori[sz]\w*|oauth\w*|sso|saml|jwts?|bearer"
    + r"|credentials?|passwords?|passphrases?|secrets?"
    + r"|api"
    + _SEP
    + r"keys?"
    + r"|(?:access|refresh|session|id|auth|bearer|api)"
    + _SEP
    + r"tokens?"
    + r"|pii|personal(?:ly)?"
    + _SEP
    + r"(?:data|information|identifiable)"
    + r"|e-?mail"
    + _SEP
    + r"address(?:es)?|ip"
    + _SEP
    + r"address(?:es)?"
    + r"|gdpr|ccpa|hipaa|redact\w*|anonymi[sz]\w*|encrypt\w*|decrypt\w*"
    + r"|cookies?|consent\w*|permissions?)"
    + _EDGE_AFTER,
    re.IGNORECASE,
)
# A bare "token" does not count in Gherkin files, because every sdk-specs
# scenario initializes the SDK with a project token.
BARE_TOKEN = re.compile(_EDGE_BEFORE + r"tokens?" + _EDGE_AFTER, re.IGNORECASE)
BARE_TOKEN_EXEMPT = re.compile(r"\.feature$", re.IGNORECASE)

_RULES = tuple(
    (kind, re.compile(pattern, re.IGNORECASE), reason)
    for kind, pattern, reason in PATH_RULES
)
# Every header line that carries a file mode. Only 100644 is a regular, non-executable file.
_MODE_LINE = re.compile(
    r"^(?:old mode|new mode|new file mode|deleted file mode|index \S+) (\d{6})$"
)
_HEADER_PATH = re.compile(r"^(?:rename from|rename to|copy from|copy to) (.*)$")


def path_kind(path):
    for kind, pattern, reason in _RULES:
        if pattern.search(path):
            return kind, reason
    return "code", "no spec rule matches this path"


def spec_paths(paths):
    return [path for path in paths if path_kind(path)[0] == "spec"]


def _header_path(line):
    """Return the path a file header names, or None for /dev/null."""
    match = _HEADER_PATH.match(line)
    if match:
        return match.group(1)
    if line.startswith(("--- ", "+++ ")):
        # Git appends a tab to a path that contains a space.
        path = line[4:].removesuffix("\t")
        if path == "/dev/null":
            return None
        return path[2:] if path.startswith(("a/", "b/")) else path
    return None


def parse_patch(text):
    """Split a unified git patch into header paths, blockers, and changed lines.

    Blockers are the shapes whose paths cannot prove the change is prose:
    quoted paths, mode changes, symlinks, submodules, binaries, renames or
    copies from a path that is not spec content, and pure renames or copies,
    whose headers do not show the file mode.
    """
    paths = []
    blockers = []
    changed = []
    header_paths = []
    current = None
    in_hunk = False
    moved = None
    mode_seen = False
    for line in [*text.splitlines(), "diff --git "]:
        if line.startswith("diff --git "):
            if moved is not None and not mode_seen:
                blockers.append(f"the file mode of {moved} is not shown")
            in_hunk = False
            current = None
            moved = None
            mode_seen = False
            if '"' in line:
                blockers.append(f"quoted path in {line!r}")
                continue
            # An empty new file has no ---/+++ lines, so its header is the only place its path appears.
            parts = line.split(" ")
            if len(parts) == 4:
                header_paths.extend(
                    part[2:] if part.startswith(("a/", "b/")) else part
                    for part in parts[2:]
                )
            continue
        if in_hunk:
            if line.startswith(("+", "-")):
                changed.append((current, line[1:]))
            continue
        if line.startswith("@@"):
            in_hunk = True
            continue
        mode = _MODE_LINE.match(line)
        mode_seen = mode_seen or mode is not None
        if mode and mode.group(1) != "100644":
            blockers.append(f"executable, symlink, or submodule: {line}")
        elif line.startswith(("Binary files", "GIT binary patch")):
            blockers.append(f"binary content: {line}")
        path = _header_path(line)
        if path is None:
            continue
        if path.startswith('"'):
            blockers.append(f"quoted path: {line}")
            continue
        paths.append(path)
        if line.startswith(("rename from", "copy from")):
            moved = path
        if line.startswith(("+++ ", "rename to", "copy to")):
            current = path
        elif current is None:
            current = path
    for path in dict.fromkeys([*header_paths, *paths]):
        kind, reason = path_kind(path)
        if kind != "spec":
            blockers.append(f"{path} is code: {reason}")
    return {"paths": paths, "blockers": blockers, "changed": changed}


def security_hits(parsed, paths):
    """Return the security terms in changed lines and paths, deduplicated."""
    hits = {}
    texts = [(path, path) for path in dict.fromkeys([*paths, *parsed["paths"]])]
    for path, text in [*texts, *parsed["changed"]]:
        text = _CAMEL_BOUNDARY.sub(" ", text)
        patterns = [SECURITY_TERMS]
        if path is None or not BARE_TOKEN_EXEMPT.search(path):
            patterns.append(BARE_TOKEN)
        for pattern in patterns:
            for match in pattern.finditer(text):
                hits.setdefault(match.group(0).lower(), None)
    return list(hits)


def main():
    if sys.argv[1:] != ["spec-paths"]:
        sys.exit("usage: review_tracks.py spec-paths < pre-review-context.json")
    metadata = json.load(sys.stdin)
    paths = [item["path"] for item in metadata.get("modified_files") or []]
    for path in spec_paths(paths):
        print(json.dumps(path, ensure_ascii=False))


if __name__ == "__main__":
    main()
