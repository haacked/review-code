## Shell Script Best Practices

**Script safety:**

- Always use `set -e` to exit on errors
- Use `set -u` to catch undefined variables
- Use `set -o pipefail` to catch errors in pipelines
- Quote variables to prevent word splitting: `"$var"`

**Shebang patterns:**

- Use `#!/usr/bin/env bash` for scripts requiring bash 4.0+ features (associative arrays, `${var,,}`, etc.)
- Use `#!/bin/bash` for scripts compatible with older bash (3.2+)
- Never use `#!/bin/sh` for bash-specific features
- Avoid bashisms if targeting POSIX sh
- Check script with `shellcheck` for common issues

**Why `#!/usr/bin/env bash`:**

- Finds bash in PATH (may be newer version on macOS where `/bin/bash` is 3.2)
- Required for associative arrays (`declare -A`) which need bash 4.0+
- Better for systems with custom bash installations

**Bash 4.0+ features:**

- Associative arrays: `declare -A map; map[key]=value`
- Case modification: `${var,,}` (lowercase), `${var^^}` (uppercase)
- `**` globbing: `shopt -s globstar; for f in **/*.sh`

## Error Handling

**Defensive scripting:**

- Check command exit codes explicitly when needed
- Use `command -v` instead of `which` for checking commands
- Provide meaningful error messages with context
- Use `trap` for cleanup on exit

**Pattern:**

```bash
if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required but not installed" >&2
    exit 1
fi
```text

## Variable Handling

**Critical patterns:**

- Always quote variables: `"$variable"`
- Use `${var}` for clarity when concatenating
- Use `${var:-default}` for default values
- Use `${var:?error}` to require variables
- Avoid global variables - pass parameters to functions

**Anti-patterns:**

- Unquoted variables (causes word splitting)
- Using backticks `` `cmd` `` instead of `$(cmd)`
- Using `eval` (security risk)
- Unnecessary use of `cat` (useless use of cat)

## File Operations

**Safe patterns:**

- Check file existence: `[ -f "$file" ]`
- Use absolute paths or validate relative paths
- Use `mktemp` for temporary files
- Clean up temporary files with `trap`

**Common mistakes:**

- Not checking if files exist before operations
- Using `ls` output in scripts (use globbing instead)
- Race conditions with temp files

## Input Validation

**Security critical:**

- Validate and sanitize all user input
- Use `readonly` for constants
- Avoid constructing commands from user input
- Use arrays for command arguments, not string concatenation

**Pattern:**

```bash
readonly CONFIG_FILE="/etc/app/config"

if [[ ! "$user_input" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Invalid input" >&2
    exit 1
fi
```text

## Arrays and Loops

**Use arrays for lists:**

```bash
files=("file1.txt" "file2.txt" "file with spaces.txt")
for file in "${files[@]}"; do
    process "$file"
done
```text

**Reading files:**

```bash
while IFS= read -r line; do
    process "$line"
done < file.txt
```text

**Anti-patterns:**

- Parsing `ls` output
- Using `for` with word splitting
- Not preserving whitespace in loops

## Functions

**Good practices:**

- Use `local` for function variables
- Return status codes, output to stdout
- Document function purpose and parameters
- Keep functions focused and small

**Pattern:**

```bash
process_file() {
    local file="$1"
    local output="$2"

    if [ ! -f "$file" ]; then
        return 1
    fi

    # Process and output
    transform "$file" > "$output"
}
```text

## Command Substitution

**Modern syntax:**

- Use `$(command)` not backticks
- Quote command substitution: `"$(command)"`
- Check exit status separately if needed

**Pattern:**

```bash
result=$(command) || {
    echo "Command failed" >&2
    exit 1
}
```text

## Testing and Conditions

**Use `[[` for conditions:**

- `[[ ]]` is more powerful than `[ ]`
- Safer with variables and patterns
- Supports `&&` and `||` inside

**Common tests:**

- `[[ -f $file ]]` - file exists
- `[[ -d $dir ]]` - directory exists
- `[[ -n $var ]]` - variable is not empty
- `[[ -z $var ]]` - variable is empty
- `[[ $a == $b ]]` - string equality
- `[[ $a =~ regex ]]` - regex match

## Logging and Output

**Standard practices:**

- Write errors to stderr: `echo "Error" >&2`
- Use consistent log format
- Don't create custom logging if not needed
- Use `echo` for simple output

**Pattern:**

```bash
log_error() {
    echo "ERROR: $*" >&2
}

log_info() {
    echo "INFO: $*"
}
```text

## Performance

**Avoid common pitfalls:**

- Don't parse command output repeatedly
- Use built-in string operations instead of `sed`/`awk`
- Minimize subshells and external commands
- Use `read` built-in instead of external tools
- Avoid O(n²) array membership checks in loops

**Efficient patterns:**

- `${var#pattern}` - remove prefix
- `${var%pattern}` - remove suffix
- `${var//pattern/replacement}` - replace all
- `${var,,}` - convert to lowercase (bash 4.0+)
- `${var^^}` - convert to uppercase (bash 4.0+)

**Use associative arrays for O(1) lookups (bash 4.0+):**

```bash
# SLOW: O(n²) - checking membership in loop
languages=()
for item in "${items[@]}"; do
    [[ ! " ${languages[@]} " =~ " $item " ]] && languages+=("$item")
done

# FAST: O(n) - using associative array
declare -A seen_languages
for item in "${items[@]}"; do
    seen_languages[$item]=1
done
languages=("${!seen_languages[@]}")
```text

## Dependencies

**Check before use:**

- Verify required commands exist
- Specify minimum versions if needed
- Provide clear error messages for missing deps
- Consider portability (GNU vs BSD tools)

## Quality Checklist

**Before committing:**

- Run `shellcheck` to catch common issues
- Test with `set -euo pipefail`
- Verify with different inputs
- Check quoting is correct
- Ensure cleanup happens (use `trap`)

## Common Anti-Patterns

**Avoid these:**

- `ls | grep` - use globbing instead
- `cat file | grep` - use `grep file`
- Unquoted `$@` - use `"$@"`
- `which command` - use `command -v`
- `==` in `[ ]` - use `=` or upgrade to `[[ ]]`
- Ignoring command failures silently

## Security Considerations

**Critical checks:**

- Never use `eval` on untrusted input
- Validate file paths (prevent path traversal)
- Use absolute paths for critical commands
- Don't trust `$PATH` for security-sensitive scripts
- Avoid command injection via variable expansion
- Use `readonly` for sensitive variables
