#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/helpers/reviewer_budget.py"
}

@test "reviewer budget: publishes the numeric limits from the shared constants" {
    run python3 - "$SCRIPT" << 'PY'
import importlib.util
from pathlib import Path
import subprocess
import sys

path = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("reviewer_budget", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
assert module.TOOL_CALL_LIMIT == 60
assert module.SEARCH_LIMIT == 30
policy = subprocess.check_output([sys.executable, str(path)], text=True)
assert f"{module.TOOL_CALL_LIMIT} investigation tool calls" in policy
assert f"{module.SEARCH_LIMIT} searches" in policy
assert "When a count reaches its limit and investigation remains" in policy
assert "A resume or delivery retry for the same assignment carries the earlier counts forward" in policy
PY
    [ "$status" -eq 0 ]
}
