#!/usr/bin/env python3
"""Move legacy review checkouts while preserving their registered paths."""

import argparse
from pathlib import Path
import shutil


def entries(root, relative=Path()):
    for path in (root / relative).iterdir():
        child = relative / path.name
        if path.is_dir() and not path.is_symlink() and len(child.parts) < 3:
            yield from entries(root, child)
        else:
            yield path, child


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("old", type=Path)
    parser.add_argument("canonical", type=Path)
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    old, canonical, root = (
        path.expanduser().absolute() for path in (args.old, args.canonical, args.root)
    )
    try:
        if root.resolve().is_relative_to(old.resolve()):
            raise ValueError("configured worktree root is inside the legacy skill")
        sources = []
        aliases = set()
        for name in (".worktrees", "worktrees"):
            alias = canonical / name
            for source in (old / name, alias):
                if not source.exists() and not source.is_symlink():
                    continue
                aliases.add(alias)
                if source.resolve() == root.resolve():
                    continue
                if source.is_symlink() or not source.is_dir():
                    raise ValueError(
                        f"cannot migrate unmanaged worktree path: {source}"
                    )
                if root.resolve().is_relative_to(source.resolve()):
                    raise ValueError(
                        f"worktree root is inside a migration source: {source}"
                    )
                sources.append(source)

        moves = []
        destinations = set()
        for source in sources:
            for path, relative in entries(source):
                destination = root / relative
                if (
                    destination.exists()
                    or destination.is_symlink()
                    or destination in destinations
                ):
                    raise ValueError(f"worktree migration collision: {destination}")
                for parent in destination.parents:
                    if parent == root:
                        break
                    if parent.is_symlink() or (parent.exists() and not parent.is_dir()):
                        raise ValueError(f"unsafe migration parent: {parent}")
                destinations.add(destination)
                moves.append((path, destination))

        moved = []
        try:
            for source, destination in moves:
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(source), str(destination))
                moved.append((source, destination))
        except OSError:
            for source, destination in reversed(moved):
                source.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(destination), str(source))
            raise

        for source in sources:
            shutil.rmtree(source)
        for alias in aliases:
            if alias == root or alias.resolve() == root.resolve():
                continue
            alias.parent.mkdir(parents=True, exist_ok=True)
            root.mkdir(parents=True, exist_ok=True)
            alias.symlink_to(root, target_is_directory=True)
    except (OSError, ValueError) as error:
        parser.exit(1, f"worktree migration: {error}\n")


if __name__ == "__main__":
    main()
