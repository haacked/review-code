#!/usr/bin/env python3
"""Run a domain review through the Codex CLI beside the Claude reviewers.

A domain review is a Markdown file under ``domain-reviews/``. Its frontmatter
says which repositories and changes it applies to and how to run Codex, and its
body is the prompt. Codex runs in its own detached worktree with the change
applied, so it can compile and test code without touching the author's checkout.

Subcommands:
  plan     Print the domain reviews whose triggers match a diff.
  start    Create the worktree and launch Codex in the background.
  wait     Wait for a started review, up to a limit, and print its status.
  cleanup  Remove a started review's worktree and release its slot.
"""

import argparse
import fnmatch
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

SKILL_DIR = Path(__file__).resolve().parent.parent
DOMAIN_DIR = Path(
    os.environ.get("REVIEW_CODE_DOMAIN_DIR", SKILL_DIR / "domain-reviews")
)
CACHE_DIR = Path(
    os.environ.get(
        "REVIEW_CODE_DOMAIN_CACHE",
        Path.home() / ".cache" / "review-code" / "domain-slots",
    )
)
LIST_KEYS = ("repos", "paths", "content_files", "links", "env", "slots")
DEFAULT_TIMEOUT = 1800
# Longer than any run can last, so a lock this old belongs to a run that is gone.
MAX_LOCK_AGE = 4 * 3600
# Time `wait` allows past a run's timeout for the runner to stop Codex and record its status.
STOP_GRACE = 120

REPORT_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["investigation", "findings", "coverage"],
    "properties": {
        "investigation": {"type": "string"},
        "findings": {"type": "string"},
        "coverage": {
            "type": "object",
            "additionalProperties": False,
            "required": ["files_read", "gaps"],
            "properties": {
                "files_read": {
                    "type": "array",
                    "items": {"type": "string", "minLength": 1},
                },
                "gaps": {"type": "array", "items": {"type": "string", "minLength": 1}},
            },
        },
    },
}

REPORT_CONTRACT = """

## Report format

Return a JSON object with these fields as your final message:

- `investigation`: what you checked, what you ran, and what passed, as one Markdown string.
- `findings`: every finding as one Markdown string, empty when there are none. Write each finding in this exact shape:

  ````
  #### 1. <short title>

  ```text
  `blocking`: <the defect, the input that breaks it, the wrong result, and the fix>
  ```

  Location: `<path>:<line>` | Confidence: <NN>%
  ````

  Use `blocking` or `suggestion`. `<path>` is relative to the repository root, and `<line>` is a line the diff adds or changes when one applies. When you reproduced a finding, say so in the body and include the command or test that shows it. When you only reasoned about it, say that instead.
- `coverage`: `files_read` lists the paths you inspected. `gaps` lists work you could not complete, such as a test you could not run. An empty `gaps` means you finished.
"""


def parse_domain(path):
    text = path.read_text().replace("\r\n", "\n")
    match = re.match(r"---\n(.*?)\n---\n(.*)", text, re.S)
    if not match:
        raise ValueError(f"{path}: missing frontmatter")
    meta = {"name": path.stem}
    for line in match.group(1).splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, _, value = line.partition(":")
        key, value = key.strip(), value.strip()
        meta[key] = value.split() if key in LIST_KEYS else value
    for key in LIST_KEYS:
        meta.setdefault(key, [])
    meta["prompt"] = match.group(2)
    if meta.get("content"):
        re.compile(meta["content"])
    int(meta.get("timeout") or DEFAULT_TIMEOUT)
    return meta


def load_domains():
    if not DOMAIN_DIR.is_dir():
        return []
    domains = []
    for path in sorted(DOMAIN_DIR.glob("*.md")):
        try:
            domains.append(parse_domain(path))
        except (ValueError, re.error) as error:
            print(f"domain review: skipping {path.name}: {error}", file=sys.stderr)
    return domains


def diff_paths_and_lines(diff_text):
    """Return the changed paths and (path, text) for every added or removed line."""
    paths, lines, current, in_header = set(), [], None, False
    for line in diff_text.splitlines():
        if line.startswith("diff --git "):
            current, in_header = None, True
        elif line.startswith("@@"):
            in_header = False
        elif in_header and line.startswith(("+++ ", "--- ")):
            target = line[4:].strip()
            if target != "/dev/null":
                current = re.sub(r"^[ab]/", "", target)
                paths.add(current)
        elif not in_header and line.startswith(("+", "-")) and current:
            lines.append((current, line[1:]))
    return paths, lines


def match_reason(domain, paths, lines):
    for path in sorted(paths):
        for pattern in domain["paths"]:
            if fnmatch.fnmatchcase(path, pattern):
                return f"{path} matches {pattern}"
    content = domain.get("content")
    if content:
        regex = re.compile(content)
        globs = domain["content_files"] or ["*"]
        for path, line in lines:
            if any(fnmatch.fnmatchcase(path, g) for g in globs) and regex.search(line):
                return f"a changed line in {path} matches /{content}/"
    return None


def cmd_plan(args):
    if os.environ.get("REVIEW_CODE_DOMAIN_REVIEWS") == "0":
        print("[]")
        return
    repo = f"{args.org}/{args.repo}".lower()
    paths, lines = diff_paths_and_lines(
        Path(args.diff_file).read_text(errors="replace")
    )
    available = shutil.which("codex") is not None
    plan = []
    for domain in load_domains():
        if repo not in (r.lower() for r in domain["repos"]):
            continue
        reason = match_reason(domain, paths, lines)
        if reason:
            plan.append(
                {"name": domain["name"], "reason": reason, "available": available}
            )
    print(json.dumps(plan))


def git(repo_dir, *args, **kwargs):
    return subprocess.run(
        ["git", "-C", str(repo_dir), *args],
        check=True,
        capture_output=True,
        text=True,
        **kwargs,
    ).stdout.strip()


def resolve_checkout(session):
    """Return the repository to branch from, the commit to check out, and whether to copy the uncommitted work."""
    git_ctx = session.get("git") or {}
    repo_dir = git_ctx.get("local_clone") or git_ctx.get("working_dir")
    if not repo_dir:
        raise ValueError("the review has no local clone to check out")
    mode = session.get("mode")
    if mode == "pr":
        return repo_dir, session["pr"]["head_sha"], False
    if mode == "branch":
        return (
            repo_dir,
            # The top-level `branch` is the branch under review. `git.branch` is the branch checked out in the shell.
            git(
                repo_dir,
                "rev-parse",
                f"{session.get('branch') or git_ctx['branch']}^{{commit}}",
            ),
            False,
        )
    if mode == "commit":
        return (
            repo_dir,
            git(repo_dir, "rev-parse", f"{session['commit']}^{{commit}}"),
            False,
        )
    if mode == "range":
        end = session["range"].split("..")[-1] or "HEAD"
        return repo_dir, git(repo_dir, "rev-parse", f"{end}^{{commit}}"), False
    working_dir = git_ctx.get("working_dir") or repo_dir
    return working_dir, git(working_dir, "rev-parse", "HEAD"), True


def copy_uncommitted(source, worktree):
    """Copy the uncommitted work in `source` into `worktree`, which is checked out at the same commit.

    The review's diff file cannot stand in for this: a local review with no uncommitted changes reviews the committed
    branch, and a filtered local review joins its staged and unstaged parts with an indented separator.
    """
    patch = subprocess.run(
        ["git", "-C", str(source), "diff", "HEAD", "--binary"],
        check=True,
        capture_output=True,
    ).stdout
    if patch:
        subprocess.run(
            [
                "git",
                "-C",
                str(worktree),
                "apply",
                "--binary",
                "--whitespace=nowarn",
                "-",
            ],
            input=patch,
            check=True,
            capture_output=True,
        )
    untracked = git(source, "ls-files", "--others", "--exclude-standard", "-z")
    for name in filter(None, untracked.split("\0")):
        target = Path(worktree) / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(Path(source) / name, target)


def repo_root(path):
    return Path(git(path, "rev-parse", "--show-toplevel"))


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def acquire_slot(domain):
    """Claim one of the domain's slots with an atomic mkdir. Returns None when the domain has no slots."""
    if not domain["slots"]:
        return None
    slot_dir = CACHE_DIR / domain["name"]
    slot_dir.mkdir(parents=True, exist_ok=True)
    for slot in domain["slots"]:
        lock = slot_dir / slot
        try:
            lock.mkdir()
        except FileExistsError:
            if not _lock_is_stale(lock):
                continue
            # Only the process whose rename succeeds reclaims the lock, so two starts cannot both take it.
            stale = lock.with_name(f"{lock.name}.stale.{os.getpid()}.{time.time_ns()}")
            try:
                lock.rename(stale)
            except OSError:
                continue
            shutil.rmtree(stale, ignore_errors=True)
            try:
                lock.mkdir()
            except FileExistsError:
                continue
        return slot
    raise ValueError(
        f"every slot for {domain['name']} is in use: {' '.join(domain['slots'])}"
    )


def _lock_is_stale(lock):
    try:
        age = time.time() - lock.stat().st_mtime
    except OSError:
        return False
    if age > MAX_LOCK_AGE:
        # A pid can be reused by an unrelated process, so a lock this old is stale whoever holds the pid.
        return True
    try:
        return not pid_alive(int((lock / "pid").read_text()))
    except (OSError, ValueError):
        return False


def release_slot(state):
    slot = state.get("slot")
    if slot:
        shutil.rmtree(CACHE_DIR / state["name"] / slot, ignore_errors=True)


def remove_worktree(state):
    worktree = Path(state["worktree"])
    if worktree.exists():
        subprocess.run(
            [
                "git",
                "-C",
                state["repo_dir"],
                "worktree",
                "remove",
                "--force",
                str(worktree),
            ],
            capture_output=True,
        )
    if worktree.exists():
        shutil.rmtree(worktree, ignore_errors=True)
        subprocess.run(
            ["git", "-C", state["repo_dir"], "worktree", "prune"], capture_output=True
        )


def fill(template, values):
    for key, value in values.items():
        template = template.replace("{" + key + "}", value)
    return template


def state_dir_for(artifacts_dir, name):
    return Path(artifacts_dir) / "domain-reviews" / name


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    tmp.replace(path)


def cmd_start(args):
    session = json.loads(Path(args.session_file).read_text())
    domain = next((d for d in load_domains() if d["name"] == args.name), None)
    if domain is None:
        raise ValueError(f"no domain review named {args.name}")
    if shutil.which("codex") is None:
        raise ValueError("the codex CLI is not installed")
    artifacts_dir = Path(session["artifacts_dir"])
    diff_file = Path(args.diff_file or session["diff_path"]).resolve()
    state_dir = state_dir_for(artifacts_dir, domain["name"])
    if (state_dir / "state.json").exists():
        raise ValueError(f"{domain['name']} was already started for this session")
    state_dir.mkdir(parents=True, exist_ok=True)

    repo_dir, head, copy_work = resolve_checkout(session)
    timeout = int(domain.get("timeout") or DEFAULT_TIMEOUT)
    worktree_root = (
        Path(os.environ.get("REVIEW_CODE_WORKTREE_DIR", SKILL_DIR / ".worktrees"))
        / "domain"
    )
    worktree = worktree_root / f"{artifacts_dir.name}-{domain['name']}"
    worktree_root.mkdir(parents=True, exist_ok=True)
    slot = acquire_slot(domain)
    state = {
        "name": domain["name"],
        "repo_dir": repo_dir,
        "worktree": str(worktree),
        "slot": slot,
        "head": head,
        "report_name": f"domain-{domain['name']}",
        "report_path": str(artifacts_dir / "reports" / f"domain-{domain['name']}.json"),
        "status_path": str(state_dir / "status.json"),
        "timeout": timeout,
        "lock": str(CACHE_DIR / domain["name"] / slot) if slot else None,
        "scratch": str(state_dir / "scratch"),
    }
    try:
        git(
            repo_dir,
            "-c",
            "core.hooksPath=/dev/null",
            "worktree",
            "add",
            "--detach",
            str(worktree),
            head,
        )
        if copy_work:
            copy_uncommitted(repo_dir, worktree)
        working_dir = (session.get("git") or {}).get("working_dir")
        roots = [repo_root(working_dir)] if working_dir else []
        roots.append(repo_root(repo_dir))
        for name in domain["links"]:
            source = next(
                (root / name for root in roots if (root / name).exists()),
                roots[-1] / name,
            )
            if source.exists() and not (worktree / name).exists():
                (worktree / name).symlink_to(source)

        values = {
            "DIFF_PATH": str(diff_file),
            "SLOT": slot or "",
            "WORKTREE": str(worktree),
        }
        (state_dir / "prompt.md").write_text(
            fill(domain["prompt"], values) + REPORT_CONTRACT
        )
        write_json(state_dir / "schema.json", REPORT_SCHEMA)
        env = dict(os.environ)
        for assignment in domain["env"]:
            key, _, value = fill(assignment, values).partition("=")
            env[key] = value
        command = [
            "codex",
            "exec",
            "-C",
            str(worktree),
            "--skip-git-repo-check",
            "--json",
        ]
        if domain.get("model"):
            command += ["-m", domain["model"]]
        if domain.get("effort"):
            command += ["-c", f'model_reasoning_effort="{domain["effort"]}"']
        command += ["--sandbox", domain.get("sandbox") or "workspace-write"]
        if domain.get("network") == "true":
            command += ["-c", "sandbox_workspace_write.network_access=true"]
        command += [
            "--output-schema",
            str(state_dir / "schema.json"),
            "-o",
            str(state_dir / "last-message.json"),
            "-",
        ]
        state["command"] = command
        write_json(state_dir / "state.json", state)
        write_json(
            Path(state["status_path"]), {"status": "running", "started_at": time.time()}
        )
        with open(state_dir / "runner.log", "ab") as log:
            runner = subprocess.Popen(
                [
                    sys.executable,
                    __file__,
                    "_run",
                    "--state",
                    str(state_dir / "state.json"),
                ],
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=log,
                env=env,
                start_new_session=True,
            )
        state["runner_pid"] = runner.pid
        write_json(state_dir / "state.json", state)
    except BaseException:
        remove_worktree(state)
        release_slot(state)
        shutil.rmtree(state_dir, ignore_errors=True)
        raise
    print(
        json.dumps(
            {
                "name": domain["name"],
                "state_path": str(state_dir / "state.json"),
                "report_name": state["report_name"],
                "report_path": state["report_path"],
                "worktree": str(worktree),
                "slot": slot,
                "timeout": state["timeout"],
            }
        )
    )


def cmd_run(args):
    state_path = Path(args.state)
    state = json.loads(state_path.read_text())
    state_dir = state_path.parent
    started = time.time()
    status = {"status": "failed"}
    process = None

    def stop(signum, frame):
        raise SystemExit(f"stopped by signal {signum}")

    signal.signal(signal.SIGTERM, stop)
    if state.get("lock"):
        (Path(state["lock"]) / "pid").write_text(str(os.getpid()))
    try:
        with (
            open(state_dir / "prompt.md", "rb") as prompt,
            open(state_dir / "events.jsonl", "wb") as events,
            open(state_dir / "stderr.log", "wb") as stderr,
        ):
            process = subprocess.Popen(
                state["command"],
                stdin=prompt,
                stdout=events,
                stderr=stderr,
                start_new_session=True,
            )
            try:
                exit_code = process.wait(timeout=state["timeout"])
            except subprocess.TimeoutExpired:
                _stop_group(process)
                status = {
                    "status": "timed_out",
                    "error": f"codex ran past {state['timeout']} seconds",
                }
                return
        if exit_code != 0:
            status = {
                "status": "failed",
                "error": f"codex exited {exit_code}; see {state_dir / 'stderr.log'}",
            }
            return
        report = json.loads((state_dir / "last-message.json").read_text())
        report["open_from_others"] = []
        write_json(Path(state["report_path"]), report)
        status = {"status": "done"}
    except BaseException as error:
        status = {"status": "failed", "error": str(error)}
    finally:
        if process is not None:
            _stop_group(process)
        status["duration_ms"] = int((time.time() - started) * 1000)
        try:
            # A finding cites its reproduction under `.codex-scratch/`, which must outlive the checkout.
            scratch = Path(state["worktree"]) / ".codex-scratch"
            if scratch.is_dir():
                shutil.copytree(scratch, state["scratch"], dirs_exist_ok=True)
        except OSError:
            pass
        try:
            remove_worktree(state)
        finally:
            release_slot(state)
            write_json(Path(state["status_path"]), status)


def _stop_group(process):
    """Stop Codex and everything it started, which share its process group."""
    if process.poll() is not None:
        return
    for sig, grace in ((signal.SIGTERM, 30), (signal.SIGKILL, 5)):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=grace)
            return
        except subprocess.TimeoutExpired:
            continue


def cmd_wait(args):
    state = json.loads(Path(args.state).read_text())
    deadline = time.time() + args.max_seconds
    while True:
        status = json.loads(Path(state["status_path"]).read_text())
        if status["status"] != "running":
            break
        pid = state.get("runner_pid")
        overdue = (
            time.time() > status.get("started_at", 0) + state["timeout"] + STOP_GRACE
        )
        if not pid or not pid_alive(pid) or overdue:
            # The runner may have recorded its result between the two reads.
            status = json.loads(Path(state["status_path"]).read_text())
            if status["status"] != "running":
                break
            if pid and pid_alive(pid):
                try:
                    os.killpg(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            status = {
                "status": "failed",
                "error": "the runner stopped without recording a result",
            }
            remove_worktree(state)
            release_slot(state)
            write_json(Path(state["status_path"]), status)
            break
        if time.time() >= deadline:
            break
        time.sleep(5)
    print(
        json.dumps(
            {
                **status,
                "name": state["name"],
                "report_name": state["report_name"],
                "report_path": state["report_path"],
            }
        )
    )


def cmd_cleanup(args):
    state = json.loads(Path(args.state).read_text())
    pid = state.get("runner_pid")
    if pid and pid_alive(pid):
        try:
            # The runner stops Codex's process group before it exits.
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        deadline = time.time() + 60
        while pid_alive(pid) and time.time() < deadline:
            time.sleep(0.5)
    remove_worktree(state)
    release_slot(state)
    print(json.dumps({"name": state["name"], "removed": state["worktree"]}))


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = parser.add_subparsers(dest="command", required=True)
    plan = sub.add_parser("plan")
    plan.add_argument("--org", required=True)
    plan.add_argument("--repo", required=True)
    plan.add_argument("--diff-file", required=True)
    start = sub.add_parser("start")
    start.add_argument("--session-file", required=True)
    start.add_argument("--name", required=True)
    start.add_argument("--diff-file")
    run = sub.add_parser("_run")
    run.add_argument("--state", required=True)
    wait = sub.add_parser("wait")
    wait.add_argument("--state", required=True)
    wait.add_argument("--max-seconds", type=int, default=540)
    cleanup = sub.add_parser("cleanup")
    cleanup.add_argument("--state", required=True)
    args = parser.parse_args()
    handlers = {
        "plan": cmd_plan,
        "start": cmd_start,
        "_run": cmd_run,
        "wait": cmd_wait,
        "cleanup": cmd_cleanup,
    }
    try:
        handlers[args.command](args)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        detail = getattr(error, "stderr", None) or str(error)
        parser.exit(1, f"domain review: {detail.strip()}\n")


if __name__ == "__main__":
    main()
