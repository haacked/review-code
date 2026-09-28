#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    GATE="$PROJECT_ROOT/skills/review-code/scripts/gate-voice-preservation.py"
    ORIGINAL="$BATS_TEST_TMPDIR/original.json"
    RESPONSES="$BATS_TEST_TMPDIR/responses.json"
    PRESERVATION="$BATS_TEST_TMPDIR/preservation.json"
    RESULT="$BATS_TEST_TMPDIR/result.json"

    jq -n '{
        findings: [
            {
                id: 1,
                severity: "suggestion",
                file: "cache.py",
                line: 12,
                location: "cache.py:12",
                description: "`suggestion`: `invalidate()` fails to clear every replica. Consider updating `cache.py:12`.",
                proposed_fix: "Consider calling `invalidate()` for every replica.",
                facts: {problem: "Replicas keep stale values.", requested_change: "Clear every replica."},
                comment_style: "concise",
                publishable: false,
                quality_state: "preflight_passed",
                confidence: 93,
                reviewer: "code-reviewer-correctness"
            },
            {
                id: 2,
                severity: "nit",
                file: "cache.py",
                line: 20,
                location: "cache.py:20",
                description: "`nit`: `cache.py:20` fails to name the timeout. Consider naming it.",
                proposed_fix: null,
                facts: {requested_change: "Name the timeout."},
                comment_style: "concise",
                quality_state: "preflight_passed"
            }
        ],
        withheld: [{id: 8, description: "Needs evidence.", reasons: ["Missing facts."], publishable: false}],
        rewrites_needed: [{id: 9, quality_state: "rewrite_required"}],
        review_metadata: {head_sha: "abc123", arbitrary: ["keep", "me"]}
    }' > "$ORIGINAL"
    jq '[.findings[] | {
        id,
        description: (.description | sub("fails to"; "does not")),
        proposed_fix: (if .proposed_fix == null then null else (.proposed_fix | sub("for every"; "on every")) end),
        unchanged: false
    }]' "$ORIGINAL" > "$RESPONSES"
    jq '[.findings[] | {id, preserved: true, notes: "The original claims remain."}]' "$ORIGINAL" > "$PRESERVATION"
}

update_json() {
    local path="$1"
    local filter="$2"
    jq "$filter" "$path" > "$BATS_TEST_TMPDIR/updated.json"
    mv "$BATS_TEST_TMPDIR/updated.json" "$path"
}

run_gate() {
    run "$GATE" "$ORIGINAL" "$RESPONSES" "$PRESERVATION"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$RESULT"
    jq -e 'type == "object"' "$RESULT" > /dev/null
}

assert_restored() {
    local id="$1"
    jq -e --argjson id "$id" --slurpfile original "$ORIGINAL" '
        (.findings[] | select(.id == $id)) == ($original[0].findings[] | select(.id == $id))
        and any(.voice_preservation.reverted[]; .id == $id and (.reasons | length > 0))
    ' "$RESULT"
}

assert_accepted() {
    local id="$1"
    jq -e --argjson id "$id" --slurpfile responses "$RESPONSES" '
        (.findings[] | select(.id == $id) | {description, proposed_fix})
        == ($responses[0][] | select(.id == $id) | {description, proposed_fix})
        and (.voice_preservation.accepted_ids | index($id)) != null
    ' "$RESULT"
}

assert_batch_restored() {
    jq -e --slurpfile original "$ORIGINAL" '
        del(.voice_preservation) == $original[0]
        and .voice_preservation.accepted_ids == []
        and (.voice_preservation.error | type == "string" and length > 0)
    ' "$RESULT"
}

@test "voice preservation: accepts faithful edits and retains all quality metadata" {
    update_json "$RESPONSES" '.[0] += {severity: "blocking", facts: {problem: "Invented claim."}, publishable: true}'
    run_gate

    assert_accepted 1
    assert_accepted 2
    jq -e --slurpfile original "$ORIGINAL" '
        (del(.voice_preservation, .findings) == ($original[0] | del(.findings)))
        and ([.findings[] | del(.description, .proposed_fix)]
            == [$original[0].findings[] | del(.description, .proposed_fix)])
        and .voice_preservation == {
            accepted_ids: [1, 2], reverted: [], unchanged_ids: [], anomalies: [], error: null
        }
    ' "$RESULT"
}

@test "voice preservation: accepts one exact four-backtick JSON array fence" {
    update_json "$ORIGINAL" '.findings[0].description += "\n```python\nflush(batch)\n```" | .findings[0].proposed_fix += "\n```suggestion\ninvalidate_all()\n```"'
    update_json "$RESPONSES" '.[0].description += "\n```python\nflush(batch)\n```" | .[0].proposed_fix += "\n```suggestion\ninvalidate_all()\n```"'
    python3 - "$RESPONSES" << 'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
path.write_text("````json\n" + path.read_text() + "````\n")
PY

    run_gate

    jq -e '.voice_preservation.accepted_ids == [1, 2] and .voice_preservation.error == null' "$RESULT"
}

@test "voice preservation: semantic rejection restores reported lost claims even when tokens survive" {
    local fixture="$PROJECT_ROOT/tests/fixtures/finding-comments/voice-preservation-regressions.json"
    jq '{findings: [.cases[] | {id, severity: "blocking", description, proposed_fix: null}], withheld: []}' "$fixture" > "$ORIGINAL"
    jq '[.cases[] | {id, description: .rewrite, proposed_fix: null, unchanged: false}]' "$fixture" > "$RESPONSES"
    jq '[.cases[] | {id, preserved: false, notes}]' "$fixture" > "$PRESERVATION"

    run_gate

    assert_restored 1
    assert_restored 3
    jq -e '.voice_preservation.accepted_ids == [] and .voice_preservation.error == null' "$RESULT"
}

@test "voice preservation: ten dropped full-path citations do not discard two faithful edits" {
    jq -n '{findings: [range(1; 13) | {
        id: .,
        severity: "suggestion",
        description: "`suggestion`: This fails to match `openspec/specs/feature-flag-cache/spec.md:79`. Consider updating the test.",
        proposed_fix: null
    }], withheld: []}' > "$ORIGINAL"
    jq '[.findings[] | {id, description: (.description | sub("fails to"; "does not")), proposed_fix, unchanged: false}
        | if .id <= 10 then .description |= sub("`openspec/specs/feature-flag-cache/spec.md:79`"; "the cache spec at line 79") else . end]' "$ORIGINAL" > "$RESPONSES"
    jq '[.findings[] | {id, preserved: true, notes: "Same claim."}]' "$ORIGINAL" > "$PRESERVATION"

    run_gate

    for id in {1..10}; do assert_restored "$id"; done
    assert_accepted 11
    assert_accepted 12
    jq -e '.voice_preservation.accepted_ids == [11, 12] and (.voice_preservation.reverted | length == 10)' "$RESULT"
}

@test "voice preservation: moving a quoted token into proposed_fix does not preserve the body" {
    update_json "$RESPONSES" '.[0].description |= sub("`cache.py:12`"; "the cache helper") | .[0].proposed_fix += " See `cache.py:12`."'

    run_gate

    assert_restored 1
    assert_accepted 2
}

@test "voice preservation: all inline code spans retain their original delimiters and contents" {
    update_json "$ORIGINAL" '.findings[0].description += " Preserve ``name`with`ticks`` and `TimeoutError`."'
    update_json "$RESPONSES" '.[0].description += " Preserve `namewithticks` and the timeout error."'

    run_gate

    assert_restored 1
    assert_accepted 2
}

@test "voice preservation: an existing severity prefix keeps its exact form" {
    update_json "$ORIGINAL" '.findings[0].description |= sub("`suggestion`:"; "**suggestion**:")'

    run_gate

    assert_restored 1
    assert_accepted 2
}

@test "voice preservation: code fences remain byte-for-byte unchanged in each field" {
    cp "$ORIGINAL" "$BATS_TEST_TMPDIR/before-code-original.json"
    cp "$RESPONSES" "$BATS_TEST_TMPDIR/before-code-responses.json"
    for field in description proposed_fix; do
        cp "$BATS_TEST_TMPDIR/before-code-original.json" "$ORIGINAL"
        cp "$BATS_TEST_TMPDIR/before-code-responses.json" "$RESPONSES"
        update_json "$ORIGINAL" ".findings[0].$field += \"\n\n\`\`\`python\nflush(batch)\n\`\`\`\""
        update_json "$RESPONSES" ".[0].$field += \"\n\n\`\`\`python\nflush(other)\n\`\`\`\""

        run_gate

        assert_restored 1
        assert_accepted 2
    done
}

@test "voice preservation: code fence closing line endings remain unchanged" {
    cp "$ORIGINAL" "$BATS_TEST_TMPDIR/before-line-ending-original.json"
    cp "$RESPONSES" "$BATS_TEST_TMPDIR/before-line-ending-responses.json"
    update_json "$ORIGINAL" '.findings[0].description += "\n```python\nflush(batch)\n```\n"'
    update_json "$RESPONSES" '.[0].description += "\n```python\nflush(batch)\n```"'

    run_gate

    assert_restored 1
    assert_accepted 2

    cp "$BATS_TEST_TMPDIR/before-line-ending-original.json" "$ORIGINAL"
    cp "$BATS_TEST_TMPDIR/before-line-ending-responses.json" "$RESPONSES"
    update_json "$ORIGINAL" '.findings[0].description += "\n```python\nflush(batch)\n```"'
    update_json "$RESPONSES" '.[0].description += "\n```python\nflush(batch)\n```\n"'

    run_gate

    assert_restored 1
    assert_accepted 2
}

@test "voice preservation: whitespace growth is free but each field has a two-times text limit" {
    update_json "$RESPONSES" '.[0].description += ("\n" * 1000)'
    run_gate
    assert_accepted 1

    cp "$RESPONSES" "$BATS_TEST_TMPDIR/before-growth.json"
    for field in description proposed_fix; do
        cp "$BATS_TEST_TMPDIR/before-growth.json" "$RESPONSES"
        update_json "$RESPONSES" ".[0].$field += (\" again\" * 50)"
        run_gate
        assert_restored 1
        assert_accepted 2
    done
}

@test "voice preservation: null proposed_fix cannot become a new fix" {
    update_json "$RESPONSES" '.[1].proposed_fix = "Use a shared timeout constant."'

    run_gate

    assert_accepted 1
    assert_restored 2
}

@test "voice preservation: unchanged findings need no semantic verdict and ignore contradictory edits" {
    update_json "$RESPONSES" '.[0] |= (.unchanged = true | .description = "`blocking`: Invented claim." | .proposed_fix = null)'
    update_json "$PRESERVATION" 'map(select(.id != 1))'

    run_gate

    jq -e --slurpfile original "$ORIGINAL" '
        .findings[0] == $original[0].findings[0]
        and .voice_preservation.unchanged_ids == [1]
        and (.voice_preservation.accepted_ids | index(1)) == null
    ' "$RESULT"
    assert_accepted 2
}

@test "voice preservation: missing candidates restore only their own finding" {
    update_json "$RESPONSES" 'map(select(.id != 1))'

    run_gate

    assert_restored 1
    assert_accepted 2
}

@test "voice preservation: duplicate candidates restore only their own finding" {
    update_json "$RESPONSES" '. + [.[0]]'

    run_gate

    assert_restored 1
    assert_accepted 2
}

@test "voice preservation: unknown candidate IDs cannot add findings" {
    update_json "$RESPONSES" '. + [.[0] | .id = 99]'
    update_json "$PRESERVATION" '. + [.[0] | .id = 99]'

    run_gate

    assert_accepted 1
    assert_accepted 2
    jq -e '[.findings[].id] == [1, 2] and (.voice_preservation.anomalies | length > 0)' "$RESULT"
}

@test "voice preservation: missing or malformed semantic verdicts cannot authorize an edit" {
    for filter in 'map(select(.id != 1))' '.[0].preserved = false' '.[0].preserved = "true"' '.[0].preserved = 1' '.[0].notes = null' '.[0] |= del(.notes)' '. + [.[0]]'; do
        jq '[.findings[] | {id, preserved: true, notes: "Same claim."}]' "$ORIGINAL" > "$PRESERVATION"
        update_json "$PRESERVATION" "$filter"

        run_gate

        assert_restored 1
        assert_accepted 2
    done
}

@test "voice preservation: malformed candidates cannot replace original bodies" {
    cp "$RESPONSES" "$BATS_TEST_TMPDIR/valid-responses.json"
    for filter in '.[0] |= del(.unchanged)' '.[0].unchanged = "false"' '.[0].description = null' '.[0] |= del(.proposed_fix)' '.[0].proposed_fix = {}' '.[0].error = "Could not rewrite safely."'; do
        cp "$BATS_TEST_TMPDIR/valid-responses.json" "$RESPONSES"
        update_json "$RESPONSES" "$filter"

        run_gate

        assert_restored 1
        assert_accepted 2
    done
}

@test "voice preservation: object prose malformed JSON and extra fenced text restore the batch" {
    cp "$RESPONSES" "$BATS_TEST_TMPDIR/valid-responses.json"
    for shape in object prose malformed prefaced_fence triple_fence; do
        python3 - "$BATS_TEST_TMPDIR/valid-responses.json" "$RESPONSES" "$shape" << 'PY'
import json
from pathlib import Path
import sys
source, destination, shape = sys.argv[1:]
raw = Path(source).read_text()
values = {
    "object": json.dumps(json.loads(raw)[0]),
    "prose": "I updated the wording and preserved every claim.",
    "malformed": '[{"id": 1,',
    "prefaced_fence": "Here are the edits:\n````json\n" + raw + "````\n",
    "triple_fence": "```json\n" + raw + "```\n",
}
Path(destination).write_text(values[shape])
PY
        run_gate
        assert_batch_restored
    done
}

@test "voice preservation: unreadable responses or malformed verdict batches restore originals" {
    mv "$RESPONSES" "$BATS_TEST_TMPDIR/saved-responses.json"
    run_gate
    assert_batch_restored

    mv "$BATS_TEST_TMPDIR/saved-responses.json" "$RESPONSES"
    printf '%s\n' '{"id": 1, "preserved": true}' > "$PRESERVATION"
    run_gate
    assert_batch_restored

    rm "$PRESERVATION"
    run_gate
    assert_batch_restored
}

@test "voice preservation: an invalid original quality object exits nonzero" {
    printf '%s\n' '{"findings": "not an array"}' > "$ORIGINAL"

    run "$GATE" "$ORIGINAL" "$RESPONSES" "$PRESERVATION"

    [ "$status" -ne 0 ]
}

@test "voice preservation: every four-backtick agent example follows the response array schema" {
    run python3 - "$PROJECT_ROOT/agents/code-reviewer-voice.md" << 'PY'
import json
from pathlib import Path
import re
import sys

examples = re.findall(r"^````json\n(.*?)\n````[ \t]*$", Path(sys.argv[1]).read_text(), re.M | re.S)
assert examples, "No four-backtick response examples found"
for index, example in enumerate(examples, 1):
    items = json.loads(example)
    assert isinstance(items, list), f"Response example {index} must be an array, got {type(items).__name__}"
    for item in items:
        assert set(item) == {"id", "description", "proposed_fix", "unchanged"}
        assert isinstance(item["description"], str)
        assert item["proposed_fix"] is None or isinstance(item["proposed_fix"], str)
        assert isinstance(item["unchanged"], bool)
PY
    [ "$status" -eq 0 ]
}

@test "voice preservation: repeated backtick citations retain their occurrence count" {
    update_json "$ORIGINAL" '.findings[0].description += " See `cache.py:12`."'

    run_gate

    assert_restored 1
    assert_accepted 2
}
