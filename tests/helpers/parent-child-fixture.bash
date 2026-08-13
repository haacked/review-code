#!/usr/bin/env bash
# Test helper: build a parent-branch/child-branch stack in the current repo.
# Requires an initialized repo with a `main` branch and at least one commit.
# parent-branch gets an origin/ tracking ref (so prefer_remote_ref picks the
# origin/ form); child-branch forks from it. Leaves the repo checked out on
# main so functions under test never query gt about the current branch.
make_parent_child_branches() {
    git checkout -q -b parent-branch
    echo "p" > p.txt && git add p.txt && git commit -q -m "P"
    git update-ref refs/remotes/origin/parent-branch HEAD

    git checkout -q -b child-branch
    echo "c" > c.txt && git add c.txt && git commit -q -m "C"

    git checkout -q main
}
