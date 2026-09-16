"""Walk the fenced code blocks used in review Markdown."""

from __future__ import annotations

from collections.abc import Iterable, Iterator
import re
from typing import Literal

FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")


def walk_fences(
    lines: Iterable[str],
) -> Iterator[tuple[int, str, Literal["prose", "open", "code", "close"]]]:
    """Yield each zero-based index, unchanged line, and fence classification.

    A closing fence must use the opener's character, be at least as long, and
    have only whitespace after it. An unterminated fence stays open through EOF.
    """
    fence = ""
    for index, line in enumerate(lines):
        marker = FENCE.match(line)
        token = marker.group(1) if marker else ""
        if fence:
            if marker and token.startswith(fence) and not line[marker.end() :].strip():
                fence = ""
                yield index, line, "close"
            else:
                yield index, line, "code"
        elif token:
            fence = token
            yield index, line, "open"
        else:
            yield index, line, "prose"
