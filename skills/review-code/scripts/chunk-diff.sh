#!/usr/bin/env bash
# chunk-diff.sh - Split large diffs into logical chunks for focused review
#
# Usage:
#   echo '{"diff": "...", "config": {...}}' | chunk-diff.sh
#
# Input (stdin): JSON object with:
#   - diff: unified diff text (required)
#   - file_metadata: array of {path, type, language, is_test, likely_test_path} (optional)
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
DEFAULT_MIN_CHUNK_THRESHOLD_KB=200
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
    BEGIN { path = ""; buf = "" }

    /^diff --git / {
        # Emit previous segment if we have one
        if (path != "") {
            # JSON-escape the buffer: backslashes, quotes, newlines, tabs, carriage returns
            gsub(/\\/, "\\\\", buf)
            gsub(/"/, "\\\"", buf)
            gsub(/\n/, "\\n", buf)
            gsub(/\t/, "\\t", buf)
            gsub(/\r/, "\\r", buf)
            printf "{\"path\":\"%s\",\"diff\":\"%s\",\"size_bytes\":%d}\n", path, buf, length(buf)
        }

        # Extract path from "diff --git a/X b/X" - take the b/ side
        match($0, /b\/(.+)$/)
        if (RSTART > 0) {
            path = substr($0, RSTART + 2)
        } else {
            path = "unknown"
        }
        buf = $0 "\n"
        next
    }

    { buf = buf $0 "\n" }

    END {
        if (path != "") {
            gsub(/\\/, "\\\\", buf)
            gsub(/"/, "\\\"", buf)
            gsub(/\n/, "\\n", buf)
            gsub(/\t/, "\\t", buf)
            gsub(/\r/, "\\r", buf)
            printf "{\"path\":\"%s\",\"diff\":\"%s\",\"size_bytes\":%d}\n", path, buf, length(buf)
        }
    }
    ' "${diff_file}"
}

# Determine the implementation file that a test file corresponds to.
# Returns the likely implementation path, or empty string if not a test file.
get_impl_for_test() {
    local file_path="$1"
    local basename
    basename=$(basename "${file_path}")
    local dirname
    dirname=$(dirname "${file_path}")

    # Python: test_foo.py -> foo.py
    if [[ "${basename}" =~ ^test_ ]]; then
        echo "${dirname}/${basename#test_}"
        return
    fi

    # Go: foo_test.go -> foo.go
    if [[ "${basename}" =~ _test\.go$ ]]; then
        echo "${dirname}/${basename%_test.go}.go"
        return
    fi

    # Generic: foo_test.ext -> foo.ext
    if [[ "${basename}" =~ _test\. ]]; then
        echo "${dirname}/${basename/_test./\.}"
        return
    fi

    # JS/TS: foo.test.ext or foo.spec.ext -> foo.ext
    if [[ "${basename}" =~ \.test\. ]]; then
        local name="${basename%.test.*}"
        local ext="${basename##*.}"
        echo "${dirname}/${name}.${ext}"
        return
    fi
    if [[ "${basename}" =~ \.spec\. ]]; then
        local name="${basename%.spec.*}"
        local ext="${basename##*.}"
        echo "${dirname}/${name}.${ext}"
        return
    fi

    # __tests__/foo.ext -> ../foo.ext
    if [[ "${dirname}" =~ /__tests__$ ]]; then
        local parent
        parent=$(dirname "${dirname}")
        echo "${parent}/${basename}"
        return
    fi

    echo ""
}

# Check whether a file path looks like a test file.
is_test_file() {
    local file_path="$1"
    local basename
    basename=$(basename "${file_path}")
    local dirname
    dirname=$(dirname "${file_path}")

    [[ "${basename}" =~ ^test_ ]] \
        || [[ "${basename}" =~ _test\. ]] \
        || [[ "${basename}" =~ \.test\. ]] \
        || [[ "${basename}" =~ \.spec\. ]] \
        || [[ "${basename}" =~ _spec\. ]] \
        || [[ "${dirname}" =~ /__tests__$ ]] \
        || [[ "${dirname}" =~ /tests?$ ]] \
        || [[ "${dirname}" =~ /specs?$ ]]
}

# Generate a human-readable label for a chunk by finding the most common
# directory prefix among the chunk's files.
generate_chunk_label() {
    local files_json="$1"
    local file_count
    file_count=$(echo "${files_json}" | jq -r 'length')

    if [[ "${file_count}" -eq 0 ]]; then
        echo "empty"
        return
    fi

    if [[ "${file_count}" -eq 1 ]]; then
        echo "${files_json}" | jq -r '.[0]'
        return
    fi

    # Find the most common top-level directory
    local top_dir
    top_dir=$(echo "${files_json}" | jq -r '.[]' | while IFS= read -r f; do
        dirname "${f}" | cut -d'/' -f1
    done | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')

    echo "${top_dir} (${file_count} files)"
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

    echo "${input}" | jq -r '.diff // ""' > "${diff_file}"

    # Check for empty diff (the file will have at least a trailing newline from echo)
    local diff_content_check
    diff_content_check=$(jq -r '.diff // ""' <<< "${input}")
    if [[ -z "${diff_content_check}" ]]; then
        jq -n '{"chunked": false, "reason": "empty diff"}'
        return
    fi

    # Extract config with defaults
    local max_chunk_size_kb max_files_per_chunk min_threshold_kb min_threshold_files
    max_chunk_size_kb=$(echo "${input}" | jq -r ".config.max_chunk_size_kb // ${DEFAULT_MAX_CHUNK_SIZE_KB}")
    max_files_per_chunk=$(echo "${input}" | jq -r ".config.max_files_per_chunk // ${DEFAULT_MAX_FILES_PER_CHUNK}")
    min_threshold_kb=$(echo "${input}" | jq -r ".config.min_chunk_threshold_kb // ${DEFAULT_MIN_CHUNK_THRESHOLD_KB}")
    min_threshold_files=$(echo "${input}" | jq -r ".config.min_chunk_threshold_files // ${DEFAULT_MIN_CHUNK_THRESHOLD_FILES}")

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
    local paired_groups
    paired_groups=$(echo "${segments_json}" | jq -r '
        # Build a list of all file paths
        [.[].path] as $all_paths |

        # For each file, check if it is a test file
        reduce .[] as $seg (
            {"pairs": {}, "paired_set": {}};

            # Check test file patterns
            ($seg.path | split("/") | last) as $basename |
            ($seg.path | split("/")[:-1] | join("/")) as $dirpart |
            (
                if ($basename | test("^test_")) then
                    # Python-style: test_foo.py -> foo.py
                    ($dirpart + "/" + ($basename | sub("^test_"; "")))
                elif ($basename | test("_test\\.go$")) then
                    # Go-style: foo_test.go -> foo.go
                    ($dirpart + "/" + ($basename | sub("_test\\.go$"; ".go")))
                elif ($basename | test("_test\\.")) then
                    # Generic: foo_test.ext -> foo.ext
                    ($dirpart + "/" + ($basename | sub("_test\\."; ".")))
                elif ($basename | test("\\.test\\.")) then
                    # JS/TS: foo.test.ext -> foo.ext
                    ($basename | split(".test.")) as $parts |
                    ($dirpart + "/" + $parts[0] + "." + $parts[1])
                elif ($basename | test("\\.spec\\.")) then
                    # JS/TS: foo.spec.ext -> foo.ext
                    ($basename | split(".spec.")) as $parts |
                    ($dirpart + "/" + $parts[0] + "." + $parts[1])
                elif ($dirpart | test("/__tests__$")) then
                    # __tests__/foo.ext -> ../foo.ext
                    (($dirpart | split("/")[:-1] | join("/")) + "/" + $basename)
                else
                    null
                end
            ) as $impl_path |

            if $impl_path != null and ($all_paths | index($impl_path) != null) then
                .pairs[$impl_path] = ((.pairs[$impl_path] // []) + [$seg.path]) |
                .paired_set[$seg.path] = true |
                .paired_set[$impl_path] = true
            else
                .
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

    # Step 3: Bin-pack groups into chunks respecting size and file count limits
    local chunks_json
    chunks_json=$(echo "${segments_json}" | jq --argjson groups "${grouping_units}" \
        --argjson max_size "${max_chunk_size_bytes}" \
        --argjson max_files "${max_files_per_chunk}" '
        # Build a lookup from path to segment
        (reduce .[] as $seg ({}; . + {($seg.path): $seg})) as $seg_lookup |

        # Bin-pack groups into chunks
        reduce $groups[] as $group (
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
        .chunks
    ')

    local chunk_count
    chunk_count=$(echo "${chunks_json}" | jq 'length')

    # If only one chunk, no point in chunking
    if [[ "${chunk_count}" -le 1 ]]; then
        jq -n \
            --arg reason "all files fit in a single chunk (${diff_size_kb}KB, ${file_count} files)" \
            '{"chunked": false, "reason": $reason}'
        return
    fi

    # Step 4: Build final output with chunk diffs and labels
    local final_output
    final_output=$(echo "${segments_json}" | jq --argjson chunks "${chunks_json}" '
        # Build path -> segment lookup
        (reduce .[] as $seg ({}; . + {($seg.path): $seg})) as $seg_lookup |

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
    ')

    echo "${final_output}"
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
