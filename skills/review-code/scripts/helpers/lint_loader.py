"""Load lint-comment-voice.py as a module.

The linter's filename has a hyphen, so it cannot be imported by name. Both
pipeline consumers (gate-voice-lint.py, lint-review-narrative.py) need its
rules, and both run from the installed copy under
~/.claude/skills/review-code/scripts/, which is not a git checkout. Resolving
the path from this file rather than from a repo root is what makes them work
there.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path
from types import ModuleType

SCRIPTS_DIR = Path(__file__).resolve().parent.parent
LINTER_PATH = SCRIPTS_DIR / "lint-comment-voice.py"


def load_linter() -> ModuleType:
    spec = importlib.util.spec_from_file_location("lint_comment_voice", LINTER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load linter at {LINTER_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
