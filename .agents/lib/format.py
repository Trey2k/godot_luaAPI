#!/usr/bin/env python3
"""Compress a GitHub API response on stdin into a few readable lines.

Called by .agents/bin/gh-agent.sh. Reading CI through grep on raw JSON loses the
pairing between a job and its conclusion, which is the part that matters when a
build fails; parsing it properly is what makes `checks` and `run` usable.

There is no `checks` mode because the Checks API cannot be reached with a
fine-grained token at all -- `gh-agent.sh checks` is built from Actions runs and
their jobs, so it formats through `runs` and `jobs`.

Usage: format.py <mode>   where mode is runs | jobs | pr | json
"""

import json
import sys


def read():
    raw = sys.stdin.read().strip()
    if not raw:
        sys.exit("No response body.")
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        sys.exit("Response was not JSON:\n" + raw[:2000])


def state(status, conclusion):
    """One short word for what a check or run amounts to right now."""
    if status != "completed":
        return status or "unknown"
    return conclusion or "unknown"


def die_on_error(data):
    """GitHub reports failures as an object with a message, not as the list."""
    if isinstance(data, dict) and "message" in data and "total_count" not in data:
        sys.exit("GitHub: {}".format(data["message"]))


def runs(data):
    die_on_error(data)
    items = data.get("workflow_runs", [])
    if not items:
        print("No workflow runs.")
        return
    for run in items:
        print(
            "{:<10} {:<12} {:<22} {}  {}".format(
                run.get("id", "?"),
                state(run.get("status"), run.get("conclusion")),
                (run.get("name") or "?")[:22],
                (run.get("head_branch") or "?")[:28],
                run.get("created_at", ""),
            )
        )


def jobs(data):
    die_on_error(data)
    items = data.get("jobs", [])
    if not items:
        print("No jobs for this run.")
        return
    # Failures first: that is what is being looked for.
    order = {"failure": 0, "timed_out": 0, "cancelled": 1}
    items.sort(key=lambda j: order.get(state(j.get("status"), j.get("conclusion")), 2))
    for job in items:
        s = state(job.get("status"), job.get("conclusion"))
        print("{:<12} {:<10} {}".format(s, job.get("id", "?"), job.get("name", "?")))
        if s in ("failure", "timed_out"):
            for step in job.get("steps", []):
                if state(step.get("status"), step.get("conclusion")) in (
                    "failure",
                    "timed_out",
                ):
                    print("             failed step: {}".format(step.get("name", "?")))
            print("             log: gh-agent.sh log {}".format(job.get("id", "?")))


def pr(data):
    die_on_error(data)
    if isinstance(data, list):
        if not data:
            print("No open PR for this branch.")
            return
        data = data[0]
    print("PR #{}: {}".format(data.get("number"), data.get("title")))
    print("url:        {}".format(data.get("html_url")))
    print("state:      {}{}".format(data.get("state"), " (merged)" if data.get("merged") else ""))
    print("head:       {} -> {}".format(
        (data.get("head") or {}).get("ref"), (data.get("base") or {}).get("ref")))
    print("mergeable:  {}  ({})".format(data.get("mergeable"), data.get("mergeable_state")))
    reviewers = [r.get("login") for r in data.get("requested_reviewers") or []]
    print("reviewers:  {}".format(", ".join(reviewers) if reviewers else "none requested"))
    print("commits:    {}  +{} -{} in {} files".format(
        data.get("commits"), data.get("additions"), data.get("deletions"),
        data.get("changed_files")))


MODES = {"runs": runs, "jobs": jobs, "pr": pr,
         "json": lambda d: print(json.dumps(d, indent=2))}

if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in MODES:
        sys.exit("Usage: format.py {}".format(" | ".join(MODES)))
    MODES[sys.argv[1]](read())
