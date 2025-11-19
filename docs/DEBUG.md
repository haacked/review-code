# DEBUG Mode

DEBUG mode captures intermediate artifacts, command logs, and outputs during
review processing to help verify correctness and debug issues.

## Quick Start

Enable DEBUG mode with an environment variable:

```bash
export REVIEW_CODE_DEBUG=1
/review-code pr 123
```

Or for a single review:

```bash
REVIEW_CODE_DEBUG=1 /review-code pr 123
```

## What Gets Captured

When DEBUG mode is enabled, review-code creates a session directory containing:

```text
~/.cache/review-code/debug/
└── {org}-{repo}-{mode}-{identifier}-{timestamp}/
    ├── session.json              # Session metadata
    ├── 00-input/                 # Input arguments
    ├── 01-parse/                 # Argument parsing results
    ├── 02-diff-filter/           # Diff filtering (before/after)
    ├── 03-language-detection/    # Language/framework detection
    ├── 04-context-loading/       # Context files loaded
    ├── 07-final-output/          # Final JSON output to Claude
    ├── timing.ndjson             # Timing data for each stage
    └── README.md                 # Human-readable summary
```

### Debug Artifacts

Each stage directory may contain:

- **`commands.log`** - Commands executed with timestamps and exit codes
- **`stdout.log`** - Standard output from commands
- **`stderr.log`** - Standard error from commands
- **`*.json`** - JSON artifacts (parsed/formatted)
- **`*.txt`** - Text artifacts (diffs, lists, etc.)
- **`trace.log`** - Detailed execution trace
- **`stats.json`** - Stage-specific statistics

## Examples

### Debug a PR Review

```bash
REVIEW_CODE_DEBUG=1 /review-code 123
```

Creates a session like:

```text
~/.cache/review-code/debug/posthog-posthog-pr-123-20251118-181500/
```

### Debug Local Changes

```bash
REVIEW_CODE_DEBUG=1 /review-code
```

### Debug a Commit

```bash
REVIEW_CODE_DEBUG=1 /review-code abc123
```

## Inspecting Debug Output

### View the Summary

```bash
cat ~/.cache/review-code/debug/posthog-posthog-pr-123-*/README.md
```

Shows:

- Session information
- Timing breakdown
- Statistics (diff reduction, files, languages)
- List of all artifacts

### Explore Artifacts

```bash
# List all sessions
ls -la ~/.cache/review-code/debug/

# View specific stage
ls -la ~/.cache/review-code/debug/*/01-parse/

# Check diff filtering
cat ~/.cache/review-code/debug/*/02-diff-generation/raw-diff.txt
cat ~/.cache/review-code/debug/*/02-diff-generation/filtered-diff.txt
```

### Check Timing

```bash
# View timing data
cat ~/.cache/review-code/debug/*/timing.ndjson | jq -s '.'
```

## Cleanup

### List Debug Sessions

```bash
bin/debug-cleanup --list
```

Shows all sessions with size and age.

### Remove Old Sessions

```bash
# Remove sessions older than 7 days (default)
bin/debug-cleanup

# Remove sessions older than 30 days
bin/debug-cleanup --older-than 30

# Remove all sessions
bin/debug-cleanup --all
```

## Use Cases

### Verify Diff Filtering

Check that the diff filtering is working correctly:

```bash
REVIEW_CODE_DEBUG=1 /review-code pr 123

# Compare before/after
diff ~/.cache/review-code/debug/*/02-diff-generation/raw-diff.txt \
     ~/.cache/review-code/debug/*/02-diff-generation/filtered-diff.txt
```

### Debug Language Detection

See what languages and frameworks were detected:

```bash
cat ~/.cache/review-code/debug/*/03-language-detection/output.json | jq .
```

### Investigate Performance

Find slow stages:

```bash
cat ~/.cache/review-code/debug/*/timing.ndjson | \
  jq -s 'group_by(.stage) |
         map({stage: .[0].stage,
              duration: (.[1].timestamp - .[0].timestamp)}) |
         sort_by(.duration) |
         reverse'
```

### Debug Context Loading

See which context files were loaded:

```bash
cat ~/.cache/review-code/debug/*/04-context-loading/context-files-loaded.txt
```

## Configuration

### Custom Debug Directory

Change where debug artifacts are stored:

```bash
export REVIEW_CODE_DEBUG_PATH="$HOME/.review-code-debug"
REVIEW_CODE_DEBUG=1 /review-code pr 123
```

## Performance Impact

- **DEBUG mode off**: 0% overhead (functions return immediately)
- **DEBUG mode on**: ~5-10% slower due to file I/O (acceptable for debugging)

## Architecture

DEBUG mode is implemented via `lib/helpers/debug-helpers.sh` which provides:

- `debug_init()` - Initialize session
- `debug_save()` - Save text artifact
- `debug_save_json()` - Save JSON artifact
- `debug_log_command()` - Execute and log command
- `debug_time()` - Record timing event
- `debug_trace()` - Add trace message
- `debug_stats()` - Save statistics
- `debug_finalize()` - Generate summary

All functions are no-ops when `REVIEW_CODE_DEBUG` is not set to `1`.

## Integration Status

Currently integrated into:

- ✅ `lib/review-orchestrator.sh` - Main orchestration, timing, final output
- ✅ Core helper functions tested
- 🔄 Diff pipeline (future: detailed before/after diffs)
- 🔄 Context loading (future: which files loaded)
- 🔄 PR context (future: gh CLI responses)
- 🔄 Cache operations (future: hit/miss tracking)

## Future Enhancements

Planned additions for deeper debugging:

1. **Diff Pipeline**: Capture raw diffs, exclusion patterns, filtering stats
2. **Language Detection**: Log pattern matches and detection logic
3. **Context Loading**: Track which .md files loaded and hierarchy
4. **PR Context**: Save raw gh CLI responses
5. **Cache Operations**: Log cache hits/misses and keys used
6. **Incremental Mode**: Show state comparison and decisions

## Troubleshooting

### No debug directory created

- Check that `REVIEW_CODE_DEBUG=1` is set
- Verify you have write permissions to `~/.cache/review-code/debug/`

### Debug artifacts incomplete

- Check for errors in stderr
- Ensure the review completed successfully
- Some stages may not generate artifacts if skipped

### Disk space concerns

- Use `bin/debug-cleanup --list` to see usage
- Set up regular cleanup: `bin/debug-cleanup --older-than 7`
- Or use a custom debug path with more space

## Usage Examples

### Complete Workflow

```bash
# Enable DEBUG mode
export REVIEW_CODE_DEBUG=1

# Run review
/review-code pr 123

# Check summary
DEBUG_DIR=$(ls -1dt ~/.cache/review-code/debug/* | head -1)
cat "$DEBUG_DIR/debug-summary.txt"

# Explore artifacts
ls -la "$DEBUG_DIR"

# Check specific stage
cat "$DEBUG_DIR/07-final-output/output.json" | jq .

# Cleanup old sessions
bin/debug-cleanup --older-than 7
```

### Finding Issues

```bash
# Enable DEBUG and run review
REVIEW_CODE_DEBUG=1 /review-code local

# If something looks wrong, inspect:
DEBUG_DIR=$(ls -1dt ~/.cache/review-code/debug/* | head -1)

# Check what was parsed
cat "$DEBUG_DIR/01-parse/output.json" | jq .

# Check final output
cat "$DEBUG_DIR/07-final-output/output.json" | jq .

# Check timing
cat "$DEBUG_DIR/timing.ndjson" | jq -s .
```
