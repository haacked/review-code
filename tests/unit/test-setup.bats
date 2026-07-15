#!/usr/bin/env bats
# Tests for bin/setup
#
# Note: The setup script no longer uses config files.
# It installs everything to ~/.claude/skills/review-code/ with fixed paths.

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
}

# =============================================================================
# Function existence tests
# =============================================================================

@test "setup: has check_prerequisites function" {
    run bash -c "grep -q '^check_prerequisites()' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -eq 0 ]
}

@test "setup: has verify_repo_structure function" {
    run bash -c "grep -q '^verify_repo_structure()' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -eq 0 ]
}

@test "setup: has install_skill function" {
    run bash -c "grep -q '^install_skill()' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -eq 0 ]
}

@test "setup: has install_agents function" {
    run bash -c "grep -q '^install_agents()' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -eq 0 ]
}

@test "setup: has install_context function" {
    run bash -c "grep -q '^install_context()' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -eq 0 ]
}

@test "setup: has main function" {
    run bash -c "grep -q '^main()' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -eq 0 ]
}

@test "setup: has cleanup_old_config function" {
    run bash -c "grep -q '^cleanup_old_config()' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -eq 0 ]
}

@test "setup: has smart merge functions" {
    run bash -c "grep -q '^merge_markdown_sections()' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Agent installation tests
# =============================================================================

@test "setup: installs security agent" {
    run bash -c "grep -A50 'install_agents()' '$PROJECT_ROOT/bin/setup' | grep -q 'code-reviewer-security'"
    [ "$status" -eq 0 ]
}

@test "setup: installs performance agent" {
    run bash -c "grep -A50 'install_agents()' '$PROJECT_ROOT/bin/setup' | grep -q 'code-reviewer-performance'"
    [ "$status" -eq 0 ]
}

@test "setup: installs maintainability agent" {
    run bash -c "grep -A50 'install_agents()' '$PROJECT_ROOT/bin/setup' | grep -q 'code-reviewer-maintainability'"
    [ "$status" -eq 0 ]
}

@test "setup: installs testing agent" {
    run bash -c "grep -A50 'install_agents()' '$PROJECT_ROOT/bin/setup' | grep -q 'code-reviewer-testing'"
    [ "$status" -eq 0 ]
}

@test "setup: installs compatibility agent" {
    run bash -c "grep -A50 'install_agents()' '$PROJECT_ROOT/bin/setup' | grep -q 'code-reviewer-compatibility'"
    [ "$status" -eq 0 ]
}

@test "setup: installs architecture agent" {
    run bash -c "grep -A50 'install_agents()' '$PROJECT_ROOT/bin/setup' | grep -q 'code-reviewer-architecture'"
    [ "$status" -eq 0 ]
}

@test "setup: installs context explorer agent" {
    run bash -c "grep -A50 'install_agents()' '$PROJECT_ROOT/bin/setup' | grep -q 'code-review-context-explorer'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Prerequisites checking
# =============================================================================

@test "setup: checks for bash 4.0+" {
    run bash -c "grep -A30 'check_prerequisites()' '$PROJECT_ROOT/bin/setup' | grep -q 'BASH_VERSINFO'"
    [ "$status" -eq 0 ]
}

@test "setup: checks for git" {
    run bash -c "grep -A30 'check_prerequisites()' '$PROJECT_ROOT/bin/setup' | grep -q 'git'"
    [ "$status" -eq 0 ]
}

@test "setup: checks for gh CLI" {
    run bash -c "grep -A30 'check_prerequisites()' '$PROJECT_ROOT/bin/setup' | grep -q 'gh'"
    [ "$status" -eq 0 ]
}

@test "setup: checks for jq" {
    run bash -c "grep -A30 'check_prerequisites()' '$PROJECT_ROOT/bin/setup' | grep -q 'jq'"
    [ "$status" -eq 0 ]
}

@test "setup: checks for ~/.claude directory" {
    run bash -c "grep -A30 'check_prerequisites()' '$PROJECT_ROOT/bin/setup' | grep -q 'CLAUDE_DIR'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Script structure tests
# =============================================================================

@test "setup: has correct shebang" {
    run bash -c "head -1 '$PROJECT_ROOT/bin/setup' | grep -q '^#!/usr/bin/env bash'"
    [ "$status" -eq 0 ]
}

@test "setup: uses set -euo pipefail" {
    run bash -c "head -30 '$PROJECT_ROOT/bin/setup' | grep -q 'set -euo pipefail'"
    [ "$status" -eq 0 ]
}

@test "setup: calls main function at end" {
    run bash -c "tail -5 '$PROJECT_ROOT/bin/setup' | grep -q 'main'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Context installation tests
# =============================================================================

@test "setup: install_context creates languages directory" {
    run bash -c "grep -A200 'install_context()' '$PROJECT_ROOT/bin/setup' | grep -q 'languages'"
    [ "$status" -eq 0 ]
}

@test "setup: install_context creates frameworks directory" {
    run bash -c "grep -A200 'install_context()' '$PROJECT_ROOT/bin/setup' | grep -q 'frameworks'"
    [ "$status" -eq 0 ]
}

@test "setup: install_context creates orgs directory" {
    run bash -c "grep -A200 'install_context()' '$PROJECT_ROOT/bin/setup' | grep -q 'orgs'"
    [ "$status" -eq 0 ]
}

@test "setup: install_context uses smart merge via process_context_file" {
    # install_context delegates to process_context_file which uses smart merge
    run bash -c "grep -A200 'install_context()' '$PROJECT_ROOT/bin/setup' | grep -q 'process_context_file'"
    [ "$status" -eq 0 ]
    # Verify process_context_file uses merge_markdown_sections
    run bash -c "grep -A50 'process_context_file()' '$PROJECT_ROOT/bin/setup' | grep -q 'merge_markdown_sections'"
    [ "$status" -eq 0 ]
}

@test "setup: process_context_file compares file checksums" {
    run bash -c "grep -A50 'process_context_file()' '$PROJECT_ROOT/bin/setup' | grep -q 'get_file_checksum'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Skill installation tests
# =============================================================================

@test "setup: install_skill copies SKILL.md" {
    run bash -c "grep -A80 'install_skill()' '$PROJECT_ROOT/bin/setup' | grep -q 'SKILL.md'"
    [ "$status" -eq 0 ]
}

@test "setup: install_skill makes scripts executable" {
    run bash -c "grep -A80 'install_skill()' '$PROJECT_ROOT/bin/setup' | grep -q 'chmod +x'"
    [ "$status" -eq 0 ]
}

@test "setup: install_skill copies uninstall script" {
    run bash -c "awk '/^install_skill\(\)/{f=1} f{print} /^}/{if(f)exit}' '$PROJECT_ROOT/bin/setup' | grep -q 'uninstall.sh'"
    [ "$status" -eq 0 ]
}

@test "setup: install_skill creates scripts directory" {
    run bash -c "grep -A80 'install_skill()' '$PROJECT_ROOT/bin/setup' | grep -q 'scripts'"
    [ "$status" -eq 0 ]
}

@test "setup: install_skill creates reviews directory" {
    run bash -c "grep -A80 'install_skill()' '$PROJECT_ROOT/bin/setup' | grep -q 'reviews'"
    [ "$status" -eq 0 ]
}

@test "setup: install_skill creates learnings directory" {
    run bash -c "grep -A80 'install_skill()' '$PROJECT_ROOT/bin/setup' | grep -q 'learnings'"
    [ "$status" -eq 0 ]
}

@test "setup: install_skill copies session hooks" {
    run bash -c "awk '/^install_skill\(\)/{f=1} f{print} /^}/{if(f)exit}' '$PROJECT_ROOT/bin/setup' | grep -q 'session-hooks'"
    [ "$status" -eq 0 ]
}

@test "setup: install_skill actually deploys session-hooks files to disk" {
    # Regression test for a bug where scripts/session-hooks/ was added to the
    # repo (review-code-cleanup.sh) but install_skill only ever copied
    # scripts/*.sh and scripts/helpers/*.sh, silently never deploying it.
    TEST_TEMP_DIR=$(mktemp -d)
    src_dir="${TEST_TEMP_DIR}/src/skills/review-code"
    dst_dir="${TEST_TEMP_DIR}/dst/skills/review-code"
    mkdir -p "${src_dir}/scripts/session-hooks"
    echo '#!/usr/bin/env bash' > "${src_dir}/scripts/session-hooks/review-code-cleanup.sh"
    mkdir -p "${src_dir}/scripts/helpers"
    touch "${src_dir}/SKILL.md"

    run bash -c "
        set -euo pipefail
        info() { :; }
        debug() { :; }
        warn() { :; }
        error() { :; }
        SCRIPT_DIR='${TEST_TEMP_DIR}/src'
        CLAUDE_DIR='${TEST_TEMP_DIR}/dst'
        SKILL_DIR='${dst_dir}'
        source <(sed -n '/^copy_scripts_dir()/,/^}/p' '$PROJECT_ROOT/bin/setup')
        source <(sed -n '/^install_skill()/,/^}/p' '$PROJECT_ROOT/bin/setup')
        install_skill
    "

    [ "$status" -eq 0 ]
    [ -f "${dst_dir}/scripts/session-hooks/review-code-cleanup.sh" ]
    [ -x "${dst_dir}/scripts/session-hooks/review-code-cleanup.sh" ]

    rm -rf "${TEST_TEMP_DIR}"
}

# =============================================================================
# Workflow tests
# =============================================================================

@test "setup: main calls check_prerequisites" {
    run bash -c "grep -A100 '^main()' '$PROJECT_ROOT/bin/setup' | grep -q 'check_prerequisites'"
    [ "$status" -eq 0 ]
}

@test "setup: main calls verify_repo_structure" {
    run bash -c "grep -A100 '^main()' '$PROJECT_ROOT/bin/setup' | grep -q 'verify_repo_structure'"
    [ "$status" -eq 0 ]
}

@test "setup: main calls cleanup_old_config" {
    run bash -c "grep -A100 '^main()' '$PROJECT_ROOT/bin/setup' | grep -q 'cleanup_old_config'"
    [ "$status" -eq 0 ]
}

@test "setup: main calls install_skill" {
    run bash -c "grep -A100 '^main()' '$PROJECT_ROOT/bin/setup' | grep -q 'install_skill'"
    [ "$status" -eq 0 ]
}

@test "setup: main calls install_agents" {
    run bash -c "grep -A100 '^main()' '$PROJECT_ROOT/bin/setup' | grep -q 'install_agents'"
    [ "$status" -eq 0 ]
}

@test "setup: main calls install_context" {
    run bash -c "grep -A100 '^main()' '$PROJECT_ROOT/bin/setup' | grep -q 'install_context'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Smart merge function existence tests
# =============================================================================

@test "setup: has get_section_headers function" {
    run bash -c "grep -q '^get_section_headers()' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -eq 0 ]
}

@test "setup: has has_section function" {
    run bash -c "grep -q '^has_section()' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -eq 0 ]
}

@test "setup: has extract_section function" {
    run bash -c "grep -q '^extract_section()' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -eq 0 ]
}

@test "setup: merge_markdown_sections uses get_section_headers" {
    run bash -c "grep -A30 '^merge_markdown_sections()' '$PROJECT_ROOT/bin/setup' | grep -q 'get_section_headers'"
    [ "$status" -eq 0 ]
}

@test "setup: merge_markdown_sections uses has_section" {
    run bash -c "grep -A30 '^merge_markdown_sections()' '$PROJECT_ROOT/bin/setup' | grep -q 'has_section'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Smart merge functional tests
# =============================================================================

# Helper to source only the smart merge functions from bin/setup
# This avoids running the full setup script which has side effects
setup_smart_merge() {
    TEST_TEMP_DIR=$(mktemp -d)
    export TEST_TEMP_DIR

    # Extract just the smart merge functions from bin/setup
    cat > "$TEST_TEMP_DIR/smart_merge.sh" << 'FUNCTIONS'
get_section_headers() {
    local file="$1"
    grep -E '^## ' "${file}" 2> /dev/null | sed 's/^## //' || true
}

has_section() {
    local file="$1"
    local section="$2"
    grep -qFx "## ${section}" "${file}" 2> /dev/null
}

extract_section() {
    local file="$1"
    local section="$2"
    awk -v section="$section" '
        /^## / {
            if ($0 == "## " section) {
                printing = 1
            } else if (printing) {
                exit
            }
        }
        printing { print }
    ' "${file}"
}

dedupe_sections_in_place() {
    local file="$1"
    local original
    original=$(cat "${file}")

    local deduped
    deduped=$(awk '
        /^## / {
            if ($0 in seen) { skip = 1 } else { seen[$0] = 1; skip = 0 }
        }
        !skip { print }
    ' "${file}")

    if [[ "${deduped}" == "${original}" ]]; then
        return 1
    fi

    printf '%s\n' "${deduped}" > "${file}"
    return 0
}

merge_markdown_sections() {
    local src="$1"
    local dst="$2"
    local new_sections_added=0
    local section_headers
    section_headers=$(get_section_headers "${src}")

    while IFS= read -r section; do
        [[ -z "${section}" ]] && continue
        if ! has_section "${dst}" "${section}"; then
            local section_content
            section_content=$(extract_section "${src}" "${section}")
            if [[ -n "${section_content}" ]]; then
                echo "" >> "${dst}"
                echo "${section_content}" >> "${dst}"
                new_sections_added=$((new_sections_added + 1))
            fi
        fi
    done <<< "${section_headers}"

    echo "${new_sections_added}"
}

# Minimal stand-ins for bin/setup's logging helpers. The real ones write to
# stderr specifically so they can't corrupt a caller's `$(...)` capture; this
# copy must match that or the process_context_file tests below would pass
# for the wrong reason.
debug() {
    echo "-> $1" >&2
}

get_file_checksum() {
    local file="$1"
    if [[ -f "${file}" ]]; then
        if command -v md5 &> /dev/null; then
            md5 -q "${file}"
        else
            md5sum "${file}" | cut -d' ' -f1
        fi
    else
        echo ""
    fi
}

process_context_file() {
    local src="$1"
    local dst="$2"
    local display_name="$3"

    if [[ ! -f "${dst}" ]]; then
        cp "${src}" "${dst}"
        echo "new"
        return
    fi

    local was_deduped=false
    if dedupe_sections_in_place "${dst}"; then
        was_deduped=true
        debug "Removed duplicate section(s): ${display_name}"
    fi

    local src_sum dst_sum
    src_sum=$(get_file_checksum "${src}")
    dst_sum=$(get_file_checksum "${dst}")

    if [[ "${src_sum}" == "${dst_sum}" ]]; then
        if [[ "${was_deduped}" == true ]]; then
            echo "deduped"
        else
            echo "updated"
        fi
        return
    fi

    local sections_added
    sections_added=$(merge_markdown_sections "${src}" "${dst}")

    if [[ "${sections_added}" -gt 0 ]]; then
        debug "Merged ${sections_added} new section(s): ${display_name}"
        echo "merged"
    elif [[ "${was_deduped}" == true ]]; then
        echo "deduped"
    else
        echo "preserved"
    fi
}
FUNCTIONS
}

teardown_smart_merge() {
    [ -d "$TEST_TEMP_DIR" ] && rm -rf "$TEST_TEMP_DIR"
}

@test "get_section_headers: extracts H2 headers from markdown" {
    setup_smart_merge
    source "$TEST_TEMP_DIR/smart_merge.sh"

    cat > "$TEST_TEMP_DIR/test.md" << 'EOF'
# Title (H1 - should be ignored)
Some intro content

## Section One
Content for section one

## Section Two
Content for section two
EOF

    result=$(get_section_headers "$TEST_TEMP_DIR/test.md")

    [[ "$result" == *"Section One"* ]]
    [[ "$result" == *"Section Two"* ]]
    [[ "$result" != *"Title"* ]]

    teardown_smart_merge
}

@test "get_section_headers: returns empty for file with no H2 headers" {
    setup_smart_merge
    source "$TEST_TEMP_DIR/smart_merge.sh"

    cat > "$TEST_TEMP_DIR/no_h2.md" << 'EOF'
# Only H1 header
Some content without H2
EOF

    result=$(get_section_headers "$TEST_TEMP_DIR/no_h2.md")

    [ -z "$result" ]

    teardown_smart_merge
}

@test "has_section: returns 0 when section exists" {
    setup_smart_merge
    source "$TEST_TEMP_DIR/smart_merge.sh"

    cat > "$TEST_TEMP_DIR/test.md" << 'EOF'
## Existing Section
Content
EOF

    run has_section "$TEST_TEMP_DIR/test.md" "Existing Section"
    [ "$status" -eq 0 ]

    teardown_smart_merge
}

@test "has_section: returns non-zero when section does not exist" {
    setup_smart_merge
    source "$TEST_TEMP_DIR/smart_merge.sh"

    cat > "$TEST_TEMP_DIR/test.md" << 'EOF'
## Some Section
Content
EOF

    run has_section "$TEST_TEMP_DIR/test.md" "Missing Section"
    [ "$status" -ne 0 ]

    teardown_smart_merge
}

@test "has_section: returns 0 for a title containing regex metacharacters" {
    setup_smart_merge
    source "$TEST_TEMP_DIR/smart_merge.sh"

    # Regression test: titles like "Derive Awareness (Critical)" or
    # "Accessibility Requirements (WCAG 2.1 AA)" contain unescaped ERE
    # metacharacters. A grep -E match on these previously always failed,
    # so has_section reported the section missing even when present,
    # causing merge_markdown_sections to re-append it on every run.
    cat > "$TEST_TEMP_DIR/test.md" << 'EOF'
## Derive Awareness (Critical)
Content
EOF

    run has_section "$TEST_TEMP_DIR/test.md" "Derive Awareness (Critical)"
    [ "$status" -eq 0 ]

    teardown_smart_merge
}

@test "extract_section: extracts section header and content" {
    setup_smart_merge
    source "$TEST_TEMP_DIR/smart_merge.sh"

    cat > "$TEST_TEMP_DIR/test.md" << 'EOF'
## First Section
First content

## Target Section
Target content line 1
Target content line 2

## Third Section
Third content
EOF

    result=$(extract_section "$TEST_TEMP_DIR/test.md" "Target Section")

    [[ "$result" == *"## Target Section"* ]]
    [[ "$result" == *"Target content line 1"* ]]
    [[ "$result" == *"Target content line 2"* ]]
    [[ "$result" != *"First content"* ]]
    [[ "$result" != *"Third content"* ]]

    teardown_smart_merge
}

@test "extract_section: handles section at end of file" {
    setup_smart_merge
    source "$TEST_TEMP_DIR/smart_merge.sh"

    cat > "$TEST_TEMP_DIR/test.md" << 'EOF'
## First Section
First content

## Last Section
Final content here
EOF

    result=$(extract_section "$TEST_TEMP_DIR/test.md" "Last Section")

    [[ "$result" == *"## Last Section"* ]]
    [[ "$result" == *"Final content here"* ]]

    teardown_smart_merge
}

@test "extract_section: handles empty section" {
    setup_smart_merge
    source "$TEST_TEMP_DIR/smart_merge.sh"

    cat > "$TEST_TEMP_DIR/test.md" << 'EOF'
## Empty Section
## Next Section
Content here
EOF

    result=$(extract_section "$TEST_TEMP_DIR/test.md" "Empty Section")

    # Should contain the header
    [[ "$result" == *"## Empty Section"* ]]
    # Should NOT contain content from next section
    [[ "$result" != *"Content here"* ]]

    teardown_smart_merge
}

@test "merge_markdown_sections: adds new sections to destination" {
    setup_smart_merge
    source "$TEST_TEMP_DIR/smart_merge.sh"

    cat > "$TEST_TEMP_DIR/src.md" << 'EOF'
## Existing Section
Source content

## New Section
New content to add
EOF

    cat > "$TEST_TEMP_DIR/dst.md" << 'EOF'
## Existing Section
User modified content
EOF

    sections_added=$(merge_markdown_sections "$TEST_TEMP_DIR/src.md" "$TEST_TEMP_DIR/dst.md")

    [ "$sections_added" -eq 1 ]
    grep -q "## New Section" "$TEST_TEMP_DIR/dst.md"
    grep -q "New content to add" "$TEST_TEMP_DIR/dst.md"
    # Original content should be preserved
    grep -q "User modified content" "$TEST_TEMP_DIR/dst.md"

    teardown_smart_merge
}

@test "merge_markdown_sections: preserves existing sections in destination" {
    setup_smart_merge
    source "$TEST_TEMP_DIR/smart_merge.sh"

    cat > "$TEST_TEMP_DIR/src.md" << 'EOF'
## Shared Section
Source version of content
EOF

    cat > "$TEST_TEMP_DIR/dst.md" << 'EOF'
## Shared Section
Destination version with user edits - SHOULD BE KEPT
EOF

    sections_added=$(merge_markdown_sections "$TEST_TEMP_DIR/src.md" "$TEST_TEMP_DIR/dst.md")

    [ "$sections_added" -eq 0 ]
    # Destination content should be unchanged
    grep -q "Destination version with user edits - SHOULD BE KEPT" "$TEST_TEMP_DIR/dst.md"
    # Source content should NOT overwrite
    ! grep -q "Source version of content" "$TEST_TEMP_DIR/dst.md"

    teardown_smart_merge
}

@test "merge_markdown_sections: returns count of added sections" {
    setup_smart_merge
    source "$TEST_TEMP_DIR/smart_merge.sh"

    cat > "$TEST_TEMP_DIR/src.md" << 'EOF'
## Section A
Content A

## Section B
Content B

## Section C
Content C
EOF

    cat > "$TEST_TEMP_DIR/dst.md" << 'EOF'
## Section A
Existing A
EOF

    sections_added=$(merge_markdown_sections "$TEST_TEMP_DIR/src.md" "$TEST_TEMP_DIR/dst.md")

    # Should add Section B and Section C (2 new sections)
    [ "$sections_added" -eq 2 ]

    teardown_smart_merge
}

@test "merge_markdown_sections: does not duplicate a section whose title has regex metacharacters across repeated runs" {
    setup_smart_merge
    source "$TEST_TEMP_DIR/smart_merge.sh"

    # Regression test for the bin/setup rerun bug: sections like
    # "Derive Awareness (Critical)" were re-appended on every run because
    # has_section's grep -E never matched the literal parentheses.
    cat > "$TEST_TEMP_DIR/src.md" << 'EOF'
## Derive Awareness (Critical)
Detection signals here.
EOF

    cp "$TEST_TEMP_DIR/src.md" "$TEST_TEMP_DIR/dst.md"

    # Simulate `bin/setup` being run repeatedly (its stated, supported usage).
    for _ in 1 2 3; do
        merge_markdown_sections "$TEST_TEMP_DIR/src.md" "$TEST_TEMP_DIR/dst.md" > /dev/null
    done

    occurrences=$(grep -c "## Derive Awareness (Critical)" "$TEST_TEMP_DIR/dst.md")
    [ "$occurrences" -eq 1 ]

    teardown_smart_merge
}

@test "merge_markdown_sections: handles empty source file" {
    setup_smart_merge
    source "$TEST_TEMP_DIR/smart_merge.sh"

    touch "$TEST_TEMP_DIR/empty_src.md"

    cat > "$TEST_TEMP_DIR/dst.md" << 'EOF'
## Existing
Content
EOF

    sections_added=$(merge_markdown_sections "$TEST_TEMP_DIR/empty_src.md" "$TEST_TEMP_DIR/dst.md")

    [ "$sections_added" -eq 0 ]
    # Destination should be unchanged
    grep -q "## Existing" "$TEST_TEMP_DIR/dst.md"

    teardown_smart_merge
}

@test "setup: has dedupe_sections_in_place function" {
    run bash -c "grep -q '^dedupe_sections_in_place()' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -eq 0 ]
}

@test "setup: process_context_file uses dedupe_sections_in_place" {
    run bash -c "grep -A20 '^process_context_file()' '$PROJECT_ROOT/bin/setup' | grep -q 'dedupe_sections_in_place'"
    [ "$status" -eq 0 ]
}

@test "dedupe_sections_in_place: removes duplicate sections, keeps first occurrence" {
    setup_smart_merge
    source "$TEST_TEMP_DIR/smart_merge.sh"

    cat > "$TEST_TEMP_DIR/dup.md" << 'EOF'
# Title

## Derive Awareness (Critical)
First copy, this is the one that should survive.

## Other Section
Other content.

## Derive Awareness (Critical)
Second copy, a duplicate that should be removed.
EOF

    run dedupe_sections_in_place "$TEST_TEMP_DIR/dup.md"
    [ "$status" -eq 0 ]

    occurrences=$(grep -c "## Derive Awareness (Critical)" "$TEST_TEMP_DIR/dup.md")
    [ "$occurrences" -eq 1 ]
    grep -q "First copy, this is the one that should survive." "$TEST_TEMP_DIR/dup.md"
    ! grep -q "Second copy, a duplicate that should be removed." "$TEST_TEMP_DIR/dup.md"
    # Untouched section and the pre-H2 title survive.
    grep -q "^# Title$" "$TEST_TEMP_DIR/dup.md"
    grep -q "## Other Section" "$TEST_TEMP_DIR/dup.md"

    teardown_smart_merge
}

@test "dedupe_sections_in_place: returns non-zero and leaves file unchanged when there are no duplicates" {
    setup_smart_merge
    source "$TEST_TEMP_DIR/smart_merge.sh"

    cat > "$TEST_TEMP_DIR/clean.md" << 'EOF'
## Section One
Content one.

## Section Two
Content two.
EOF
    cp "$TEST_TEMP_DIR/clean.md" "$TEST_TEMP_DIR/clean.md.orig"

    run dedupe_sections_in_place "$TEST_TEMP_DIR/clean.md"
    [ "$status" -ne 0 ]

    diff "$TEST_TEMP_DIR/clean.md" "$TEST_TEMP_DIR/clean.md.orig"

    teardown_smart_merge
}

@test "dedupe_sections_in_place: collapses many repeated duplicates (simulates a corrupted installation)" {
    setup_smart_merge
    source "$TEST_TEMP_DIR/smart_merge.sh"

    {
        echo "# Rust Review Guidelines"
        for _ in $(seq 1 238); do
            echo ""
            echo "## Derive Awareness (Critical)"
            echo "Detection signals here."
        done
    } > "$TEST_TEMP_DIR/bloated.md"

    run dedupe_sections_in_place "$TEST_TEMP_DIR/bloated.md"
    [ "$status" -eq 0 ]

    occurrences=$(grep -c "## Derive Awareness (Critical)" "$TEST_TEMP_DIR/bloated.md")
    [ "$occurrences" -eq 1 ]

    teardown_smart_merge
}

@test "setup: has process_context_file function" {
    run bash -c "grep -q '^process_context_file()' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -eq 0 ]
}

@test "setup: logging helpers write to stderr, not stdout" {
    # Regression test: process_context_file's return value is the stdout of
    # a \$(...) call, and it calls debug() internally. If any of info/warn/
    # error/debug wrote to stdout, that log text would corrupt the captured
    # status (see the two tests below for the concrete failure mode this
    # caused: "deduped"/"merged" silently vanishing from the setup summary).
    for fn in info warn error debug; do
        run bash -c "grep -A2 \"^${fn}()\" '$PROJECT_ROOT/bin/setup' | grep -q '>&2'"
        [ "$status" -eq 0 ]
    done
}

@test "process_context_file: returns a single-word status even when a section was deduplicated" {
    setup_smart_merge
    source "$TEST_TEMP_DIR/smart_merge.sh"

    cat > "$TEST_TEMP_DIR/src.md" << 'EOF'
## Derive Awareness (Critical)
Content.
EOF

    # A destination that already has every section from src, just duplicated,
    # so dedupe changes it but merge finds nothing new to add.
    cat > "$TEST_TEMP_DIR/dst.md" << 'EOF'
## Derive Awareness (Critical)
Content.

## Derive Awareness (Critical)
Content.
EOF

    result=$(process_context_file "$TEST_TEMP_DIR/src.md" "$TEST_TEMP_DIR/dst.md" "test.md")

    # Must be exactly "deduped", not that plus a stray debug line, and not
    # silently swallowed into `*) ;;` by a case statement that can't match
    # a multi-line value.
    [ "$result" = "deduped" ]

    teardown_smart_merge
}

@test "process_context_file: returns a single-word status when new sections are merged" {
    setup_smart_merge
    source "$TEST_TEMP_DIR/smart_merge.sh"

    cat > "$TEST_TEMP_DIR/src.md" << 'EOF'
## Existing Section
Source content.

## New Section
New content.
EOF

    cat > "$TEST_TEMP_DIR/dst.md" << 'EOF'
## Existing Section
User content, kept as-is.
EOF

    result=$(process_context_file "$TEST_TEMP_DIR/src.md" "$TEST_TEMP_DIR/dst.md" "test.md")

    [ "$result" = "merged" ]
    grep -q "## New Section" "$TEST_TEMP_DIR/dst.md"

    teardown_smart_merge
}

@test "setup: install_context uses process_context_file" {
    run bash -c "grep -A100 'install_context()' '$PROJECT_ROOT/bin/setup' | grep -q 'process_context_file'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Installation path tests
# =============================================================================

@test "setup: uses SKILL_DIR under ~/.claude/skills/review-code" {
    run bash -c "grep -q 'SKILL_DIR=\"\${CLAUDE_DIR}/skills/review-code\"' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -eq 0 ]
}

@test "setup: context is installed to skill directory" {
    run bash -c "grep -A10 'install_context()' '$PROJECT_ROOT/bin/setup' | grep -q 'SKILL_DIR.*context'"
    [ "$status" -eq 0 ]
}

@test "setup: no longer uses .env config file" {
    # Verify setup doesn't create .env files anymore
    run bash -c "grep -q 'create_config' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -ne 0 ]
}

@test "setup: cleans up deprecated config files" {
    run bash -c "grep -A20 'cleanup_old_config()' '$PROJECT_ROOT/bin/setup' | grep -q '.env'"
    [ "$status" -eq 0 ]
}
