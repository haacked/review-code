#!/usr/bin/env bash
# chunk-diff.sh - Split large diffs into logical chunks for focused review
#
# Usage:
#   echo '{"diff": "...", "config": {...}}' | chunk-diff.sh
#
# Input (stdin): JSON object with:
#   - diff: unified diff text (required)
#   - file_metadata: object with modified_files array of {path, type, language, is_test,
#                   likely_test_path} (optional, from pre-review-context.sh)
#   - config: {max_chunk_size_kb, max_files_per_chunk, min_chunk_threshold_kb,
#              min_chunk_threshold_files} (optional, all have defaults)
#
# Output (stdout): JSON object:
#   - chunked: boolean
#   - reason: string
#   - chunk_count: number (only when chunked)
#   - chunks: array of {id, label, files, diff, size_kb} (only when chunked)
#
# When below threshold, outputs: {"chunked": false, "reason": "..."}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/error-helpers.sh
source "${SCRIPT_DIR}/helpers/error-helpers.sh"
# shellcheck source=helpers/json-helpers.sh
source "${SCRIPT_DIR}/helpers/json-helpers.sh"

set -euo pipefail

# Default configuration
DEFAULT_MAX_CHUNK_SIZE_KB=200
DEFAULT_MAX_FILES_PER_CHUNK=30
DEFAULT_MIN_CHUNK_THRESHOLD_KB=400
DEFAULT_MIN_CHUNK_THRESHOLD_FILES=50

# Parse the diff text into per-file segments.
# Reads the diff from the file at path $1 and writes a JSON array to stdout where
# each element is {"path": "...", "diff": "...", "size_bytes": N}.
parse_diff_segments() {
    local diff_file="$1"

    # Use awk to split on "diff --git" boundaries and emit NDJSON.
    # Each record captures the file path (from the "diff --git a/... b/..." line)
    # and the full diff text for that file.
    awk '
    function emit() {
        sz = length(buf)
        gsub(/\\/, "\\\\", buf)
        gsub(/"/, "\\\"", buf)
        gsub(/\n/, "\\n", buf)
        gsub(/\t/, "\\t", buf)
        gsub(/\r/, "\\r", buf)
        gsub(/\\/, "\\\\", path)
        gsub(/"/, "\\\"", path)
        printf "{\"path\":\"%s\",\"diff\":\"%s\",\"size_bytes\":%d}\n", path, buf, sz
    }

    BEGIN { path = ""; buf = "" }

    /^diff --git / {
        if (path != "") emit()

        # Extract path from "diff --git a/X b/X" - take the b/ side.
        # Match on " b/" (with leading space) to avoid false matches on directory
        # names containing "b" (e.g., lib/, web/, pub/, sub/, contrib/, db/).
        match($0, / b\/(.+)$/)
        if (RSTART > 0) {
            path = substr($0, RSTART + 3)
        } else {
            path = "unknown"
        }
        buf = $0 "\n"
        next
    }

    { buf = buf $0 "\n" }

    END {
        if (path != "") emit()
    }
    ' "${diff_file}"
}

main() {
    # Read input from stdin
    local input
    input=$(cat)

    # Validate JSON
    if ! echo "${input}" | jq empty 2> /dev/null; then
        error "Invalid JSON input"
        exit 1
    fi

    # Extract diff to a temp file to avoid argument length limits
    # Use a global for the trap so cleanup works even after the function returns
    _CHUNK_DIFF_TMPFILE=$(mktemp)
    local diff_file="${_CHUNK_DIFF_TMPFILE}"
    trap 'rm -f "${_CHUNK_DIFF_TMPFILE}"' EXIT

    # Use jq -j (no trailing newline) so an empty diff produces a truly empty file
    echo "${input}" | jq -j '.diff // ""' > "${diff_file}"

    # Check for empty diff using the file that was already written
    if [[ ! -s "${diff_file}" ]]; then
        jq -n '{"chunked": false, "reason": "empty diff"}'
        return
    fi

    # Extract config with defaults (single jq call instead of four)
    local config_values max_chunk_size_kb max_files_per_chunk min_threshold_kb min_threshold_files
    config_values=$(jq -r "[
        .config.max_chunk_size_kb // ${DEFAULT_MAX_CHUNK_SIZE_KB},
        .config.max_files_per_chunk // ${DEFAULT_MAX_FILES_PER_CHUNK},
        .config.min_chunk_threshold_kb // ${DEFAULT_MIN_CHUNK_THRESHOLD_KB},
        .config.min_chunk_threshold_files // ${DEFAULT_MIN_CHUNK_THRESHOLD_FILES}
    ] | @tsv" <<< "${input}")
    read -r max_chunk_size_kb max_files_per_chunk min_threshold_kb min_threshold_files <<< "${config_values}"

    local max_chunk_size_bytes=$((max_chunk_size_kb * 1024))

    # Calculate diff size and file count
    local diff_size_bytes
    diff_size_bytes=$(wc -c < "${diff_file}")
    diff_size_bytes="${diff_size_bytes// /}" # Strip whitespace (macOS wc pads with spaces)
    local diff_size_kb=$((diff_size_bytes / 1024))

    # Parse diff into per-file segments
    local segments_ndjson
    segments_ndjson=$(parse_diff_segments "${diff_file}")

    # Count files. grep -c returns 1 on no match, so use a default.
    local file_count
    file_count=$(printf '%s\n' "${segments_ndjson}" | grep -c '^{' || true)
    file_count="${file_count:-0}"

    # Check if below threshold
    local threshold_kb_bytes=$((min_threshold_kb * 1024))
    if [[ "${diff_size_bytes}" -lt "${threshold_kb_bytes}" ]] && [[ "${file_count}" -lt "${min_threshold_files}" ]]; then
        jq -n \
            --arg reason "below threshold (${diff_size_kb}KB, ${file_count} files)" \
            '{"chunked": false, "reason": $reason}'
        return
    fi

    # Build the segments array as JSON
    local segments_json
    segments_json=$(echo "${segments_ndjson}" | jq -s '.')

    # Step 1: Pair test files with their implementation files.
    # Build a mapping of impl_path -> [test_paths] and track which files are paired.
    # When file_metadata is available (passed from the orchestrator via pre-review-context.sh),
    # use its likely_test_path for forward mapping and is_test to skip known non-test files.
    # Fall back to filename pattern matching when metadata is absent.
    local file_metadata_json
    file_metadata_json=$(jq -c '.file_metadata // null' <<< "${input}")

    local paired_groups
    paired_groups=$(echo "${segments_json}" | jq -r --argjson meta "${file_metadata_json}" '
        # Derive the implementation file path from a test file name.
        # Returns null if the file does not match any known test pattern.
        def impl_path_for_test($basename; $dirpart):
            if ($basename | test("^test_")) then
                ($dirpart + "/" + ($basename | sub("^test_"; "")))
            elif ($basename | test("_test\\.go$")) then
                ($dirpart + "/" + ($basename | sub("_test\\.go$"; ".go")))
            elif ($basename | test("_test\\.")) then
                ($dirpart + "/" + ($basename | sub("_test\\."; ".")))
            elif ($basename | test("_spec\\.")) then
                ($dirpart + "/" + ($basename | sub("_spec\\."; ".")))
            elif ($basename | test("\\.test\\.")) then
                ($basename | split(".test.")) as $parts |
                ($dirpart + "/" + $parts[0] + "." + $parts[1])
            elif ($basename | test("\\.spec\\.")) then
                ($basename | split(".spec.")) as $parts |
                ($dirpart + "/" + $parts[0] + "." + $parts[1])
            elif ($dirpart | test("/__tests__$")) then
                (($dirpart | split("/")[:-1] | join("/")) + "/" + $basename)
            elif ($dirpart | test("/tests?$")) then
                (($dirpart | split("/")[:-1] | join("/")) + "/" + $basename)
            elif ($dirpart | test("/specs?$")) then
                (($dirpart | split("/")[:-1] | join("/")) + "/" + $basename)
            else
                null
            end;

        # Build a list of all file paths
        [.[].path] as $all_paths |

        # Build a lookup from path to metadata (when available).
        # file_metadata is an object with a modified_files array of
        # {path, type, language, is_test, likely_test_path} entries.
        (if $meta != null and ($meta | has("modified_files")) then
            reduce $meta.modified_files[] as $m ({}; . + {($m.path): $m})
        else {} end) as $meta_lookup |

        # Step 1a: Use likely_test_path forward mapping when metadata is available.
        # For each non-test file with a likely_test_path, check if that test file
        # is in the diff and pair them.
        (if ($meta_lookup | length) > 0 then
            reduce ($meta_lookup | to_entries[]) as $entry (
                {"pairs": {}, "paired_set": {}};
                $entry.key as $file_path |
                $entry.value as $m |
                if $m.is_test != true and
                   ($m.likely_test_path // "") != "" and
                   ($all_paths | index($m.likely_test_path) != null) then
                    .pairs[$file_path] = ((.pairs[$file_path] // []) + [$m.likely_test_path]) |
                    .paired_set[$file_path] = true |
                    .paired_set[$m.likely_test_path] = true
                else . end
            )
        else null end) as $meta_pairs |

        # Step 1b: Fall back to pattern matching for files not paired by metadata.
        reduce .[] as $seg (
            ($meta_pairs // {"pairs": {}, "paired_set": {}});

            # Skip files already paired via metadata
            if .paired_set[$seg.path] == true then .
            else
                ($seg.path | split("/") | last) as $basename |
                ($seg.path | split("/")[:-1] | join("/")) as $dirpart |

                # Use metadata to skip pattern matching for known non-test files.
                (if ($meta_lookup | has($seg.path)) and $meta_lookup[$seg.path].is_test != true then
                    null
                else
                    impl_path_for_test($basename; $dirpart)
                end) as $impl_path |

                if $impl_path != null and ($all_paths | index($impl_path) != null) then
                    .pairs[$impl_path] = ((.pairs[$impl_path] // []) + [$seg.path]) |
                    .paired_set[$seg.path] = true |
                    .paired_set[$impl_path] = true
                else
                    .
                end
            end
        )
    ')

    # Step 2: Build grouping units (paired groups + unpaired files), sorted by directory
    local grouping_units
    grouping_units=$(echo "${segments_json}" | jq --argjson pairs "${paired_groups}" '
        # Get all paired files
        ($pairs.paired_set | keys) as $paired_files |

        # Build paired groups: each group is [impl_file, test_files...]
        [($pairs.pairs | to_entries[] | [.key] + .value)] as $pair_groups |

        # Build unpaired singles: each group is [file]
        [.[] | select(.path as $p | $paired_files | index($p) | not) | [.path]] as $single_groups |

        # Combine and sort by first file path (directory proximity)
        ($pair_groups + $single_groups) | sort_by(.[0])
    ')

    # Steps 3+4: Bin-pack groups into chunks, then build final output with diffs and labels.
    # Combined into a single jq invocation to avoid rebuilding the segment lookup twice.
    local final_output
    final_output=$(echo "${segments_json}" | jq --argjson groups "${grouping_units}" \
        --argjson max_size "${max_chunk_size_bytes}" \
        --argjson max_files "${max_files_per_chunk}" '
        # Build a lookup from path to segment
        (reduce .[] as $seg ({}; . + {($seg.path): $seg})) as $seg_lookup |

        # Bin-pack groups into chunks
        (reduce $groups[] as $group (
            {"chunks": [], "current": {"files": [], "size": 0}};

            # Calculate group size and file count
            (reduce $group[] as $f (0; . + ($seg_lookup[$f].size_bytes // 0))) as $group_size |
            ($group | length) as $group_file_count |

            # Check if adding this group would exceed limits
            if (.current.files | length) > 0 and
               ((.current.size + $group_size > $max_size) or
                ((.current.files | length) + $group_file_count > $max_files))
            then
                # Start a new chunk
                .chunks += [.current] |
                .current = {"files": $group, "size": $group_size}
            else
                # Add to current chunk
                .current.files += $group |
                .current.size += $group_size
            end
        ) |
        # Flush the last chunk
        if (.current.files | length) > 0 then
            .chunks += [.current]
        else
            .
        end |
        .chunks) as $chunks |

        # If only one chunk, no point in chunking
        if ($chunks | length) <= 1 then
            {"chunked": false, "reason":
                ("all files fit in a single chunk (" +
                 (reduce .[] as $s (0; . + $s.size_bytes) | . / 1024 | floor | tostring) +
                 "KB, " + (length | tostring) + " files)")}
        else
            {
                "chunked": true,
                "reason": ("diff exceeds threshold (" +
                    (reduce .[] as $s (0; . + $s.size_bytes) | . / 1024 | floor | tostring) +
                    "KB, " + (length | tostring) + " files)"),
                "chunk_count": ($chunks | length),
                "chunks": [
                    $chunks | to_entries[] |
                    .key as $idx |
                    .value as $chunk |

                    # Concatenate diffs for files in this chunk
                    (reduce $chunk.files[] as $f ("";
                        . + ($seg_lookup[$f].diff // "")
                    )) as $chunk_diff |

                    # Calculate chunk size
                    ($chunk_diff | length / 1024 | floor) as $size_kb |

                    # Generate label from most common top-level directory
                    ([$chunk.files[] | split("/")[0]] | group_by(.) | sort_by(-length) | .[0][0] // "root") as $top_dir |

                    {
                        "id": ($idx + 1),
                        "label": ($top_dir + " (" + ($chunk.files | length | tostring) + " files)"),
                        "files": $chunk.files,
                        "diff": $chunk_diff,
                        "size_kb": $size_kb
                    }
                ]
            }
        end
    ')

    echo "${final_output}"
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
