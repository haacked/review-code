#!/usr/bin/env bash

# Cross-platform date handling helpers
# Handles differences between BSD (macOS) and GNU (Linux) date commands

# Get file modification time as epoch seconds
# Usage: get_file_mtime <file_path>
# Returns: epoch seconds on stdout, or empty string on error
get_file_mtime() {
    local file_path="$1"

    if [[ "${OSTYPE}" == "darwin"* ]]; then
        stat -f '%m' "${file_path}" 2>/dev/null
    else
        stat -c '%Y' "${file_path}" 2>/dev/null
    fi
}

# Convert ISO 8601 date to epoch seconds
# Handles both "Z" suffix and "+HH:MM" offset formats
# Usage: iso_to_epoch <iso_date>
# Returns: epoch seconds on stdout, or "0" on error
iso_to_epoch() {
    local iso_date="$1"

    if [[ "${OSTYPE}" == "darwin"* ]]; then
        # BSD date requires specific format handling:
        # - "2026-02-02T10:30:00Z" (Zulu time)
        # - "2026-02-02T10:30:00+00:00" (offset format)
        # BSD date's %z expects +HHMM not +HH:MM
        if [[ "${iso_date}" == *Z ]]; then
            date -j -f "%Y-%m-%dT%H:%M:%SZ" "${iso_date}" +%s 2>/dev/null || echo "0"
        else
            # Normalize +HH:MM or -HH:MM to +HHMM/-HHMM for BSD date
            local normalized_date
            normalized_date=$(echo "${iso_date}" | sed -E 's/([+-][0-9]{2}):([0-9]{2})$/\1\2/')
            date -j -f "%Y-%m-%dT%H:%M:%S%z" "${normalized_date}" +%s 2>/dev/null || echo "0"
        fi
    else
        date -d "${iso_date}" +%s 2>/dev/null || echo "0"
    fi
}

# Get ISO 8601 date for N days ago (UTC)
# Usage: days_ago_iso <days>
# Returns: ISO 8601 date string on stdout (e.g., "2026-01-01T00:00:00Z")
days_ago_iso() {
    local days="$1"

    if [[ "${OSTYPE}" == "darwin"* ]]; then
        date -v-"${days}"d -u +"%Y-%m-%dT%H:%M:%SZ"
    else
        date -d "${days} days ago" -u +"%Y-%m-%dT%H:%M:%SZ"
    fi
}
