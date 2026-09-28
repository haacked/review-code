#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/build-finding-prompt.py"
    INPUT="$BATS_TEST_TMPDIR/findings.json"
    DIFF="$BATS_TEST_TMPDIR/diff.patch"
    BRIEFING="$BATS_TEST_TMPDIR/briefing.md"
    FILE_ACCESS="$BATS_TEST_TMPDIR/file-access.json"
    printf '%s\n' '[{"id": 1, "description": "PAYLOAD_SENTINEL: the response loses its field."}]' > "$INPUT"
    printf '%s\n' 'DIFF_SENTINEL' > "$DIFF"
    printf '%s\n' 'BRIEFING_SENTINEL' > "$BRIEFING"
    printf '%s\n' '{"content":"FILE_ACCESS_SENTINEL"}' > "$FILE_ACCESS"
}

prompt() {
    run python3 "$SCRIPT" --agent "$1" --input "$INPUT" "${@:2}"
}

assert_count() {
    python3 - "$output" "$1" "$2" <<'PY'
import re
import sys

text, count, noun = sys.argv[1:]
assert re.search(rf"(?:\b{count}\s+{noun}\b|\b{noun}\s*[:=]\s*{count}\b)", text, re.I), text
PY
}

assert_bounded_prompt() {
    python3 - "$output" <<'PY'
import sys

assert len(sys.argv[1].encode("utf-8")) < 4096
PY
}

@test "build-finding-prompt: a large gate batch uses a bounded reference without leaking payload" {
    python3 - "$INPUT" <<'PY'
import json
import sys

with open(sys.argv[1], "w") as stream:
    json.dump([{"id": i, "description": "PAYLOAD_SENTINEL_λ" * 1000} for i in range(350)], stream, indent=2)
    stream.write("\n")
PY
    prompt comprehension-gate
    [ "$status" -eq 0 ]
    [[ "$output" == *"$INPUT"* ]]
    [[ "$output" != *PAYLOAD_SENTINEL* ]]
    [[ "$output" == *INPUT_UNAVAILABLE* ]]
    assert_bounded_prompt
    assert_count 350 '(?:items|findings)'
    assert_count "$(awk 'END {print NR}' "$INPUT")" lines
    [[ "$output" =~ [Pp]ag(e|es|ed|ing) ]]
}

@test "build-finding-prompt: voice reads a JSON batch by reference" {
    prompt code-reviewer-voice
    [ "$status" -eq 0 ]
    [[ "$output" == *"$INPUT"* ]]
    [[ "$output" != *PAYLOAD_SENTINEL* ]]
    [[ "$output" != *"$DIFF"* ]]
    [[ "$output" != *"$BRIEFING"* ]]
    [[ "$output" != *"$FILE_ACCESS"* ]]
    [[ "$output" == *INPUT_UNAVAILABLE* ]]
    assert_count 1 '(?:items|findings)'
    assert_bounded_prompt
}

@test "build-finding-prompt: composer receives all source context as file references" {
    prompt code-reviewer-comment --diff "$DIFF" --briefing "$BRIEFING" --file-access "$FILE_ACCESS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$INPUT"* ]]
    [[ "$output" == *"$DIFF"* ]]
    [[ "$output" == *"$BRIEFING"* ]]
    [[ "$output" == *"$FILE_ACCESS"* ]]
    [[ "$output" != *PAYLOAD_SENTINEL* ]]
    [[ "$output" != *DIFF_SENTINEL* ]]
    [[ "$output" != *BRIEFING_SENTINEL* ]]
    [[ "$output" != *FILE_ACCESS_SENTINEL* ]]
    [[ "$output" == *INPUT_UNAVAILABLE* ]]
    assert_bounded_prompt
}

@test "build-finding-prompt: composer requires each source context file" {
    prompt code-reviewer-comment --briefing "$BRIEFING" --file-access "$FILE_ACCESS"
    [ "$status" -ne 0 ]
    prompt code-reviewer-comment --diff "$DIFF" --file-access "$FILE_ACCESS"
    [ "$status" -ne 0 ]
    prompt code-reviewer-comment --diff "$DIFF" --briefing "$BRIEFING"
    [ "$status" -ne 0 ]
}

@test "build-finding-prompt: composer rejects missing or empty context files" {
    local context
    for context in "$DIFF" "$BRIEFING" "$FILE_ACCESS"; do
        cp "$context" "$BATS_TEST_TMPDIR/saved-context"
        rm "$context"
        prompt code-reviewer-comment --diff "$DIFF" --briefing "$BRIEFING" --file-access "$FILE_ACCESS"
        [ "$status" -ne 0 ]
        [[ "$output" == *INPUT_UNAVAILABLE* ]]
        : > "$context"
        prompt code-reviewer-comment --diff "$DIFF" --briefing "$BRIEFING" --file-access "$FILE_ACCESS"
        [ "$status" -ne 0 ]
        [[ "$output" == *INPUT_UNAVAILABLE* ]]
        mv "$BATS_TEST_TMPDIR/saved-context" "$context"
    done
}

@test "build-finding-prompt: gate and voice reject every source context argument" {
    local agent
    for agent in comprehension-gate code-reviewer-voice; do
        prompt "$agent" --diff "$DIFF"
        [ "$status" -ne 0 ]
        prompt "$agent" --briefing "$BRIEFING"
        [ "$status" -ne 0 ]
        prompt "$agent" --file-access "$FILE_ACCESS"
        [ "$status" -ne 0 ]
    done
}

@test "build-finding-prompt: accepts an empty batch" {
    printf '%s\n' '[]' > "$INPUT"
    prompt comprehension-gate
    [ "$status" -eq 0 ]
    [[ "$output" == *"$INPUT"* ]]
    assert_count 0 '(?:items|findings)'
    assert_count 1 lines
}

@test "build-finding-prompt: missing input fails explicitly" {
    rm "$INPUT"
    prompt comprehension-gate
    [ "$status" -ne 0 ]
    [[ "$output" == *INPUT_UNAVAILABLE* ]]
}

@test "build-finding-prompt: empty malformed or non-object-array input fails explicitly" {
    local payload
    for payload in '' '{broken' '{}' 'null' '[1]' '[{"id":1},"bad"]'; do
        printf '%s' "$payload" > "$INPUT"
        prompt comprehension-gate
        [ "$status" -ne 0 ]
        [[ "$output" == *INPUT_UNAVAILABLE* ]]
    done
}

@test "build-finding-prompt: unsupported agents fail" {
    prompt finding-validator
    [ "$status" -ne 0 ]
}

@test "build-finding-prompt: enforces the 4096-byte UTF-8 prompt boundary" {
    local candidate first_error last_success long_dir name output_file seed
    long_dir=$(python3 - "$BATS_TEST_TMPDIR" <<'PY'
from pathlib import Path
import sys

path = sys.argv[1]
remaining = 832 - len(path.encode("utf-8"))
for parts in range(1, 50):
    characters = remaining - parts
    if parts <= characters <= parts * 100:
        sizes = [characters // parts] * parts
        for index in range(characters % parts):
            sizes[index] += 1
        path += "".join("/" + "d" * size for size in sizes)
        break
assert len(path.encode("utf-8")) == 832
Path(path).mkdir(parents=True)
print(path)
PY
)
    seed="$long_dir/seed.json"
    cp "$INPUT" "$seed"
    printf '%s\n' diff > "$long_dir/diff.patch"
    printf '%s\n' briefing > "$long_dir/briefing.md"
    printf '%s\n' access > "$long_dir/file-access.json"
    output_file="$BATS_TEST_TMPDIR/boundary-prompt"

    for length in $(seq 1 200); do
        printf -v name '%*s' "$length" ''
        name=${name// /x}
        candidate="$long_dir/$name.json"
        cp "$seed" "$candidate"
        if python3 "$SCRIPT" --agent code-reviewer-comment --input "$candidate" \
            --diff "$long_dir/diff.patch" --briefing "$long_dir/briefing.md" \
            --file-access "$long_dir/file-access.json" > "$output_file" 2> "$BATS_TEST_TMPDIR/boundary-error"; then
            last_success=$(wc -c < "$output_file" | tr -d ' ')
        else
            first_error=$(<"$BATS_TEST_TMPDIR/boundary-error")
            break
        fi
    done

    [ "$last_success" -eq 4095 ]
    [[ "$first_error" == *"dispatch prompt exceeds the 4096-byte limit"* ]]
}
