#!/usr/bin/env python3
"""Shared soft limits and validation for domain reviewer investigation."""

TOOL_CALL_LIMIT = 60
SEARCH_LIMIT = 30
LIMITS = {"tool_calls": TOOL_CALL_LIMIT, "searches": SEARCH_LIMIT}


def validate_budget(coverage, required=False):
    if "budget" not in coverage:
        if required:
            raise ValueError("coverage.budget is required for this review")
        return None
    budget = coverage["budget"]
    if not isinstance(budget, dict):
        raise TypeError("coverage.budget must be an object")
    for field in LIMITS:
        if type(budget.get(field)) is not int or budget[field] < 0:
            raise ValueError(f"coverage.budget.{field} must be a nonnegative integer")
    status = budget.get("status")
    if status not in ("complete", "limited"):
        raise ValueError("coverage.budget.status must be complete or limited")
    reached = [field for field, limit in LIMITS.items() if budget[field] >= limit]
    if status == "limited" and (not reached or not coverage["gaps"]):
        raise ValueError(
            "a limited budget requires a reached limit and named coverage gaps"
        )
    return {**budget, "limits": LIMITS, "limits_reached": reached}


def instructions():
    return f"""## Soft Reviewer Work Budget

Each domain reviewer gets {TOOL_CALL_LIMIT} investigation tool calls and {SEARCH_LIMIT} searches for its assigned diff. These limits apply to both harnesses, including chunk reviewers and inline fallbacks. Track your own counts; the runner does not interrupt tools. Context exploration and finding validation have separate roles and do not use this budget.

Count each underlying tool invocation, including reads of the briefing, diff, and source, shell commands, failed calls, and external lookups. A parallel batch counts every child call. Each distinct search query also counts as one search, including rg, grep, glob, find, and code or web search. Count separate queries inside one shell command separately. Do not bundle work or delegate to evade either limit. Writing or returning your final report is exempt.

Read the supplied context and assigned diff first. Keep a checklist of the files, symbols, and domain checks still pending. Reuse the explorer's answers. Before each new call, check both counts; do not start work that would exceed either limit. When a count reaches its limit and investigation remains, stop new investigation and report what is unfinished. This stop rule takes precedence over instructions to complete every checklist item or follow every caller. Never omit unread diff ranges from the gaps.

Return coverage.budget as {{"tool_calls": <count>, "searches": <count>, "status": "complete" or "limited"}}. Use limited when a limit stopped work, with at least one specific coverage.gaps entry naming a path or symbol and the check left undone. For example: "src/queue.py consume(): retry behavior after a failed acknowledgement was not checked". "Budget exhausted" alone is insufficient. Complete means the budget did not stop work; unrelated access gaps still belong in coverage.gaps. Finishing all work exactly at a limit is complete. If an in-flight call overshoots and work remains, report limited and name what remains unchecked. If it finishes all pending work, report complete with the actual counters.

Preserve every verified finding and its full evidence. Put hypotheses you could not verify in coverage.gaps, never turn them into speculative findings or questions to the author. Empty findings with gaps mean an incomplete review, not a clean review. Always finish and deliver the report after stopping investigation.

A resume or delivery retry for the same assignment carries the earlier counts forward; a new report filename does not reset them. A coverage retry can use only the remaining budget. If earlier counts are unavailable, stop and tell the orchestrator the budget cannot be accounted for. Do not invent zero counts.
"""


if __name__ == "__main__":
    print(instructions())
