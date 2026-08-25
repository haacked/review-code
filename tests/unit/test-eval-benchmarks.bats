#!/usr/bin/env bats
# Structural checks on evals/benchmarks: every registry entry resolves to a
# benchmark directory, and each benchmark's metadata agrees with its answer key.
#
# Nothing in evals/scripts reads expected_finding_count or false_positive_trap_count,
# so without these checks the two fields drift from the answer key unnoticed and the
# only way to find a malformed benchmark is to pay for an eval run.

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    BENCHMARKS_DIR="$PROJECT_ROOT/evals/benchmarks"
    export BENCHMARKS_DIR

    REGISTRY="$BENCHMARKS_DIR/registry.json"
    export REGISTRY
}

# Print "<category>/<id>" for every registry entry.
benchmark_paths() {
    jq -r '.benchmarks[] | "\(.category)/\(.id)"' "$REGISTRY"
}

@test "eval benchmarks: registry.json is valid JSON with a benchmarks array" {
    run jq -e '.benchmarks | type == "array" and length > 0' "$REGISTRY"
    [ "$status" -eq 0 ]
}

@test "eval benchmarks: registry ids are unique" {
    local total unique
    total=$(jq '.benchmarks | length' "$REGISTRY")
    unique=$(jq '[.benchmarks[].id] | unique | length' "$REGISTRY")
    [ "$total" -eq "$unique" ]
}

@test "eval benchmarks: every registry entry resolves to a directory with the required files" {
    local problems=""
    while read -r bench; do
        local dir="$BENCHMARKS_DIR/$bench"
        if [[ ! -d "$dir" ]]; then
            problems+="$bench: directory not found"$'\n'
            continue
        fi
        local required
        for required in metadata.json answer-key.json diff.patch; do
            [[ -f "$dir/$required" ]] || problems+="$bench: missing $required"$'\n'
        done
    done < <(benchmark_paths)

    [[ -z "$problems" ]] || echo "$problems" >&2
    [ -z "$problems" ]
}

@test "eval benchmarks: metadata.json and answer-key.json parse" {
    local problems=""
    while read -r bench; do
        local file
        for file in metadata.json answer-key.json; do
            local path="$BENCHMARKS_DIR/$bench/$file"
            [[ -f "$path" ]] || continue
            jq empty "$path" 2> /dev/null || problems+="$bench: $file is not valid JSON"$'\n'
        done
    done < <(benchmark_paths)

    [[ -z "$problems" ]] || echo "$problems" >&2
    [ -z "$problems" ]
}

@test "eval benchmarks: metadata id matches the registry id" {
    local problems=""
    while read -r bench; do
        local path="$BENCHMARKS_DIR/$bench/metadata.json"
        [[ -f "$path" ]] || continue
        local registry_id metadata_id
        registry_id="${bench##*/}"
        metadata_id=$(jq -r '.id // ""' "$path")
        [[ "$metadata_id" == "$registry_id" ]] ||
            problems+="$bench: metadata id is '$metadata_id'"$'\n'
    done < <(benchmark_paths)

    [[ -z "$problems" ]] || echo "$problems" >&2
    [ -z "$problems" ]
}

@test "eval benchmarks: metadata counts match the answer key's list lengths" {
    local problems=""
    while read -r bench; do
        local meta="$BENCHMARKS_DIR/$bench/metadata.json"
        local key="$BENCHMARKS_DIR/$bench/answer-key.json"
        [[ -f "$meta" && -f "$key" ]] || continue

        local declared_findings actual_findings declared_traps actual_traps
        declared_findings=$(jq -r '.expected_finding_count // "unset"' "$meta")
        actual_findings=$(jq '.expected_findings | length' "$key")
        declared_traps=$(jq -r '.false_positive_trap_count // "unset"' "$meta")
        actual_traps=$(jq '.false_positive_traps | length' "$key")

        [[ "$declared_findings" == "$actual_findings" ]] ||
            problems+="$bench: expected_finding_count is $declared_findings, answer key has $actual_findings"$'\n'
        [[ "$declared_traps" == "$actual_traps" ]] ||
            problems+="$bench: false_positive_trap_count is $declared_traps, answer key has $actual_traps"$'\n'
    done < <(benchmark_paths)

    [[ -z "$problems" ]] || echo "$problems" >&2
    [ -z "$problems" ]
}

@test "eval benchmarks: expected findings and traps carry the fields the scorer reads" {
    local problems=""
    while read -r bench; do
        local key="$BENCHMARKS_DIR/$bench/answer-key.json"
        [[ -f "$key" ]] || continue

        local bad
        bad=$(jq -r '
            [ (.expected_findings[]? | select(
                  (.id? // "") == "" or (.file? // "") == "" or
                  (.line_start? | type) != "number" or (.line_end? | type) != "number" or
                  ((.keywords? // []) | length) == 0
              ) | "expected finding \(.id // "<no id>")"),
              (.false_positive_traps[]? | select(
                  (.id? // "") == "" or (.file? // "") == "" or
                  (.line_start? | type) != "number" or (.line_end? | type) != "number" or
                  ((.trap_keywords? // []) | length) == 0
              ) | "trap \(.id // "<no id>")")
            ] | join(", ")
        ' "$key")
        [[ -z "$bad" ]] || problems+="$bench: incomplete entries: $bad"$'\n'
    done < <(benchmark_paths)

    [[ -z "$problems" ]] || echo "$problems" >&2
    [ -z "$problems" ]
}

@test "eval benchmarks: answer key line ranges run forwards" {
    local problems=""
    while read -r bench; do
        local key="$BENCHMARKS_DIR/$bench/answer-key.json"
        [[ -f "$key" ]] || continue

        local bad
        bad=$(jq -r '
            [ (.expected_findings[]?, .false_positive_traps[]?)
              | select((.line_start? | type) == "number" and (.line_end? | type) == "number")
              | select(.line_start > .line_end)
              | "\(.id): \(.line_start)-\(.line_end)"
            ] | join(", ")
        ' "$key")
        [[ -z "$bad" ]] || problems+="$bench: reversed ranges: $bad"$'\n'
    done < <(benchmark_paths)

    [[ -z "$problems" ]] || echo "$problems" >&2
    [ -z "$problems" ]
}

@test "eval benchmarks: no benchmark directory is missing from the registry" {
    local problems=""
    local registered
    registered=$(benchmark_paths)

    local dir
    while read -r dir; do
        local bench="${dir#"$BENCHMARKS_DIR"/}"
        grep -qxF "$bench" <<< "$registered" ||
            problems+="$bench: on disk but not in registry.json"$'\n'
    done < <(find "$BENCHMARKS_DIR" -mindepth 2 -maxdepth 2 -type d | sort)

    [[ -z "$problems" ]] || echo "$problems" >&2
    [ -z "$problems" ]
}

@test "eval benchmarks: the reviewing agent is never told the benchmark id" {
    # run_crafted_benchmark hands the temp branch name to the review prompt and
    # commits on that branch, and the skill reads both the branch name and the
    # commit messages. An id like shadow-diff-duplication or unsafe-api would
    # tell the reviewer what to look for before it reads any code.
    local script="$PROJECT_ROOT/evals/scripts/run-eval.sh"
    local problems=""

    grep -qE 'tmp_branch="eval-tmp-\$\{bench_tag\}"' "$script" ||
        problems+="temp branch name is not derived from the hashed bench_tag"$'\n'

    local leaky
    leaky=$(grep -nE 'commit -m "eval:[^"]*\$\{id\}' "$script" || true)
    [[ -z "$leaky" ]] || problems+="eval commit message carries the id: $leaky"$'\n'

    [[ -z "$problems" ]] || echo "$problems" >&2
    [ -z "$problems" ]
}
