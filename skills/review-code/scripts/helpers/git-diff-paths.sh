#!/usr/bin/env bash

git_diff_path_functions() {
    cat << 'AWK'
    function decode_git_path(path, result, i, char, octal) {
        if (substr(path, 1, 1) != "\"") return path
        path = substr(path, 2, length(path) - 2)
        result = ""
        for (i = 1; i <= length(path); i++) {
            char = substr(path, i, 1)
            if (char == "\\") {
                char = substr(path, ++i, 1)
                if (char ~ /[0-7]/) {
                    octal = char * 64 + substr(path, i + 1, 1) * 8 + substr(path, i + 2, 1)
                    char = sprintf("%c", octal)
                    i += 2
                } else if (char == "a") char = sprintf("%c", 7)
                else if (char == "b") char = sprintf("%c", 8)
                else if (char == "t") char = "\t"
                else if (char == "n") char = "\n"
                else if (char == "v") char = sprintf("%c", 11)
                else if (char == "f") char = "\f"
                else if (char == "r") char = "\r"
            }
            result = result char
        }
        return result
    }

    function json_quote(value, result, i, char, code) {
        result = "\""
        for (i = 1; i <= length(value); i++) {
            char = substr(value, i, 1)
            if (char == "\\") char = "\\\\"
            else if (char == "\"") char = "\\\""
            else if (char == sprintf("%c", 8)) char = "\\b"
            else if (char == "\t") char = "\\t"
            else if (char == "\n") char = "\\n"
            else if (char == "\f") char = "\\f"
            else if (char == "\r") char = "\\r"
            else {
                for (code = 1; code < 32; code++) {
                    if (char == sprintf("%c", code)) {
                        char = sprintf("\\u%04x", code)
                        break
                    }
                }
            }
            result = result char
        }
        return result "\""
    }

    function diff_header_path(line, content, search_from, separator, first_separator, source, destination) {
        line = substr(line, 12)
        if (substr(line, 1, 1) == "\"") {
            if (!match(line, /^"([^"\\]|\\.)*" /)) return ""
            line = substr(line, RLENGTH + 1)
        } else {
            content = line
            search_from = 1
            while (match(substr(content, search_from), / "?b\//)) {
                separator = search_from + RSTART - 1
                if (first_separator == 0) first_separator = separator
                source = substr(content, 3, separator - 3)
                destination = decode_git_path(substr(content, separator + 1))
                if (source == substr(destination, 3)) return substr(destination, 3)
                search_from = separator + 3
            }
            if (first_separator == 0) return ""
            line = substr(content, first_separator + 1)
        }
        return substr(decode_git_path(line), 3)
    }

    function diff_marker_path(line) {
        line = substr(line, 5)
        sub(/[[:space:]]*$/, "", line)
        return substr(decode_git_path(line), 3)
    }

    function diff_rename_path(line) {
        return decode_git_path(substr(line, 11))
    }
AWK
}

git_diff_paths() {
    LC_ALL=C awk "$(git_diff_path_functions)"'
        function emit_file() {
            if (path != "") printf "%s%c%s%c", deleted ? "true" : "false", 0, path, 0
        }
        /^diff --git / {
            emit_file()
            old_path = ""
            deleted = in_hunk = 0
            path = diff_header_path($0)
            next
        }
        /^@@/ { in_hunk = 1 }
        in_hunk { next }
        /^deleted file mode / { deleted = 1 }
        /^rename to / { path = diff_rename_path($0) }
        /^--- "?a\// { old_path = diff_marker_path($0) }
        /^\+\+\+ / {
            if ($0 ~ /^\+\+\+ \/dev\/null([[:space:]]|$)/) {
                path = old_path
                deleted = 1
            } else if ($0 ~ /^\+\+\+ "?b\//) {
                path = diff_marker_path($0)
            }
        }
        END { emit_file() }
    '
}
