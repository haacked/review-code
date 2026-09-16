#!/usr/bin/env bats

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PYTHONPATH="$ROOT/skills/review-code/scripts${PYTHONPATH:+:$PYTHONPATH}"
}

@test "walk_fences preserves indices and original lines from a generator" {
    run python3 - <<'PY'
from helpers.markdown_fences import walk_fences

lines = ["Before\r\n", "```python\n", "print(1)\r\n", "```\n", "After"]
assert list(walk_fences(line for line in lines)) == list(zip(
    range(len(lines)), lines, ["prose", "open", "code", "close", "prose"]
))
assert list(walk_fences(iter([]))) == []
PY
    [ "$status" -eq 0 ]
}

@test "walk_fences keeps shorter fences and other markers inside a code example" {
    run python3 - <<'PY'
from helpers.markdown_fences import walk_fences

for marker, other in [("`", "~"), ("~", "`")]:
    lines = [
        marker * 4 + "markdown",
        marker * 3 + "python",
        "example",
        marker * 3,
        other * 5,
        marker * 5 + " trailing text",
        "still code",
        marker * 5 + " \t",
        "prose again",
    ]
    kinds = [kind for _, _, kind in walk_fences(lines)]
    assert kinds == ["open", *(["code"] * 6), "close", "prose"], kinds
PY
    [ "$status" -eq 0 ]
}

@test "walk_fences accepts at most three leading spaces on either fence" {
    run python3 - <<'PY'
from helpers.markdown_fences import FENCE, walk_fences

assert [kind for _, _, kind in walk_fences(["``", "~~"])] == ["prose", "prose"]

for marker in ["`", "~"]:
    for indent in range(4):
        opening = " " * indent + marker * 3 + "text"
        assert FENCE.match(opening).group(1) == marker * 3
        lines = [opening, "    " + marker * 3, "\t" + marker * 3,
                 " " * (3 - indent) + marker * 3]
        assert [kind for _, _, kind in walk_fences(lines)] == ["open", "code", "code", "close"]
    assert [kind for _, _, kind in walk_fences(["    " + marker * 3, "\t" + marker * 3])] == ["prose", "prose"]
PY
    [ "$status" -eq 0 ]
}

@test "walk_fences keeps an unterminated block open through EOF" {
    run python3 - <<'PY'
from helpers.markdown_fences import walk_fences

lines = ["~~~text", "body", "~~~not a closer", "", "#### quoted heading"]
assert list(walk_fences(lines)) == list(zip(
    range(len(lines)), lines, ["open", "code", "code", "code", "code"]
))
PY
    [ "$status" -eq 0 ]
}
