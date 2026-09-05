#!/usr/bin/env bats
# Tests for format-existing-comments.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/format-existing-comments.sh"
}

run_script() {
    run bash -c "echo '$1' | '$SCRIPT'"
}

@test "format-existing-comments: renders a conversation comment" {
    run_script '{"conversation":[{"author":"alice","body":"Looks good"}]}'
    [ "$status" -eq 0 ]
    [[ "$output" == "- [conversation] @alice: Looks good" ]]
}

@test "format-existing-comments: renders a review with its state" {
    run_script '{"reviews":[{"author":"bob","state":"APPROVED","body":"LGTM"}]}'
    [ "$status" -eq 0 ]
    [[ "$output" == "- [review/APPROVED] @bob: LGTM" ]]
}

@test "format-existing-comments: review with no state defaults to comment" {
    run_script '{"reviews":[{"author":"bob","body":"just a note"}]}'
    [[ "$output" == "- [review/comment] @bob: just a note" ]]
}

@test "format-existing-comments: a null review body renders as empty" {
    run_script '{"reviews":[{"author":"bob","body":null}]}'
    [ "$status" -eq 0 ]
    [[ "$output" == "- [review/comment] @bob: " ]]
}

@test "format-existing-comments: renders a solo open inline comment with no reply line" {
    run_script '{"inline":[{"id":1,"author":"eve","body":"a note","path":"foo.py","line":10,"in_reply_to_id":null,"resolved":false,"outdated":false}]}'
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l | tr -d " ")" -eq 1 ]
    [[ "$output" == "- [inline] @eve foo.py:10: a note" ]]
}

@test "format-existing-comments: an inline comment with no line renders a question mark" {
    run_script '{"inline":[{"id":1,"author":"eve","body":"a note","path":"foo.py","line":null,"in_reply_to_id":null,"resolved":false,"outdated":false}]}'
    [[ "$output" == "- [inline] @eve foo.py:?: a note" ]]
}

@test "format-existing-comments: collapses an open thread's replies to a count and the last reply" {
    run_script '{"inline":[
        {"id":1,"author":"eve","body":"root","path":"foo.py","line":10,"in_reply_to_id":null,"resolved":false,"outdated":false},
        {"id":2,"author":"frank","body":"first reply","path":"foo.py","line":10,"in_reply_to_id":1,"resolved":false,"outdated":false},
        {"id":3,"author":"grace","body":"last reply","path":"foo.py","line":10,"in_reply_to_id":1,"resolved":false,"outdated":false}
    ]}'
    [ "$status" -eq 0 ]
    lines=$(echo "$output")
    [[ "$lines" == *"- [inline] @eve foo.py:10: root"* ]]
    [[ "$lines" == *"(2 replies, last by @grace: last reply)"* ]]
    [[ "$lines" != *"first reply"* ]]
}

@test "format-existing-comments: a single reply uses singular wording" {
    run_script '{"inline":[
        {"id":1,"author":"eve","body":"root","path":"foo.py","line":10,"in_reply_to_id":null,"resolved":false,"outdated":false},
        {"id":2,"author":"frank","body":"only reply","path":"foo.py","line":10,"in_reply_to_id":1,"resolved":false,"outdated":false}
    ]}'
    [[ "$output" == *"(1 reply, last by @frank: only reply)"* ]]
}

@test "format-existing-comments: a resolved thread collapses to one index line" {
    run_script '{"inline":[{"id":1,"author":"eve","body":"settled point","path":"foo.py","line":10,"in_reply_to_id":null,"resolved":true,"outdated":false}]}'
    [ "$(echo "$output" | wc -l | tr -d " ")" -eq 1 ]
    [[ "$output" == "- [inline, resolved] @eve foo.py:10: settled point" ]]
}

@test "format-existing-comments: an outdated but unresolved thread keeps its full body" {
    # isOutdated only means the anchor line moved, not that the issue was
    # addressed; collapsing it the way a resolved thread collapses would lose
    # a still-open concern.
    run_script '{"inline":[{"id":1,"author":"eve","body":"still an open concern","path":"foo.py","line":10,"in_reply_to_id":null,"resolved":false,"outdated":true}]}'
    [[ "$output" == "- [inline, outdated] @eve foo.py:10: still an open concern" ]]
}

@test "format-existing-comments: an outdated and resolved thread collapses like any resolved thread" {
    run_script '{"inline":[{"id":1,"author":"eve","body":"code moved and was fixed","path":"foo.py","line":10,"in_reply_to_id":null,"resolved":true,"outdated":true}]}'
    [[ "$output" == "- [inline, resolved] @eve foo.py:10: code moved and was fixed" ]]
}

@test "format-existing-comments: a resolved thread's replies do not appear" {
    run_script '{"inline":[
        {"id":1,"author":"eve","body":"root","path":"foo.py","line":10,"in_reply_to_id":null,"resolved":true,"outdated":false},
        {"id":2,"author":"frank","body":"a reply after resolution","path":"foo.py","line":10,"in_reply_to_id":1,"resolved":true,"outdated":false}
    ]}'
    [ "$(echo "$output" | wc -l | tr -d " ")" -eq 1 ]
    [[ "$output" != *"after resolution"* ]]
}

@test "format-existing-comments: a comment missing resolved/outdated fields renders as open" {
    run_script '{"inline":[{"id":1,"author":"eve","body":"a note","path":"foo.py","line":10,"in_reply_to_id":null}]}'
    [[ "$output" == "- [inline] @eve foo.py:10: a note" ]]
}

@test "format-existing-comments: caps a long body and appends an ellipsis" {
    long=$(python3 -c "print('x' * 900)")
    run_script "{\"conversation\":[{\"author\":\"alice\",\"body\":\"$long\"}]}"
    [ "$status" -eq 0 ]
    body="${output#*: }"
    [[ "$body" == *"…" ]]
    kept="${body%…}"
    [ "${#kept}" -eq 800 ]
}

@test "format-existing-comments: caps a resolved thread's index line at 100 characters" {
    long=$(python3 -c "print('y' * 200)")
    run_script "{\"inline\":[{\"id\":1,\"author\":\"eve\",\"body\":\"$long\",\"path\":\"foo.py\",\"line\":10,\"in_reply_to_id\":null,\"resolved\":true,\"outdated\":false}]}"
    [ "$status" -eq 0 ]
    body="${output#*: }"
    [[ "$body" == *"…" ]]
    kept="${body%…}"
    [ "${#kept}" -eq 100 ]
}

@test "format-existing-comments: caps a reply preview at 150 characters" {
    long=$(python3 -c "print('z' * 300)")
    run_script "{\"inline\":[
        {\"id\":1,\"author\":\"eve\",\"body\":\"root\",\"path\":\"foo.py\",\"line\":10,\"in_reply_to_id\":null,\"resolved\":false,\"outdated\":false},
        {\"id\":2,\"author\":\"frank\",\"body\":\"$long\",\"path\":\"foo.py\",\"line\":10,\"in_reply_to_id\":1,\"resolved\":false,\"outdated\":false}
    ]}"
    [ "$status" -eq 0 ]
    reply_line=$(echo "$output" | tail -1)
    body="${reply_line#*last by @frank: }"
    body="${body%)}"
    [[ "$body" == *"…" ]]
    kept="${body%…}"
    [ "${#kept}" -eq 150 ]
}

@test "format-existing-comments: a resolved thread's index line uses only the first line of the body" {
    run_script '{"inline":[{"id":1,"author":"eve","body":"first line\nsecond line","path":"foo.py","line":10,"in_reply_to_id":null,"resolved":true,"outdated":false}]}'
    [[ "$output" == "- [inline, resolved] @eve foo.py:10: first line" ]]
    [[ "$output" != *"second line"* ]]
}

@test "format-existing-comments: an empty comments object produces no output" {
    run_script '{}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "format-existing-comments: strips a trailing carriage return from a CRLF body's first line" {
    # GitHub review comment bodies use \r\n; splitting on \n alone leaves a
    # stray \r that renders as a control character in the briefing.
    local body=$'first line\r\nsecond line'
    local json
    json=$(jq -n --arg body "$body" '{inline: [{id: 1, author: "eve", body: $body, path: "foo.py", line: 10, in_reply_to_id: null, resolved: true, outdated: false}]}')
    run bash -c 'echo "$1" | "$2"' -- "$json" "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == "- [inline, resolved] @eve foo.py:10: first line" ]]
    [[ "$output" != *$'\r'* ]]
}

@test "format-existing-comments: a null inline comment body does not crash the pipeline" {
    run_script '{"inline":[{"id":1,"author":"eve","body":null,"path":"foo.py","line":10,"in_reply_to_id":null,"resolved":true,"outdated":false}]}'
    [ "$status" -eq 0 ]
    [[ "$output" == "- [inline, resolved] @eve foo.py:10: "* ]]
}

@test "format-existing-comments: a null reply body does not crash the reply summary" {
    run_script '{"inline":[
        {"id":1,"author":"eve","body":"root","path":"foo.py","line":10,"in_reply_to_id":null,"resolved":false,"outdated":false},
        {"id":2,"author":"frank","body":null,"path":"foo.py","line":10,"in_reply_to_id":1,"resolved":false,"outdated":false}
    ]}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"(1 reply, last by @frank: )"* ]]
}
