#!/usr/bin/env bash
# GitHub API and gh CLI as the agent, with the agent's own token.
#
# Usage:
#   .agents/bin/gh-agent.sh whoami                      account behind this agent's token
#   .agents/bin/gh-agent.sh pr-create <title> [body]    PR from current branch into BASE_BRANCH
#   .agents/bin/gh-agent.sh pr-status [number]          PR state, mergeability, review decision
#   .agents/bin/gh-agent.sh checks [ref]                CI result per check for a commit (default HEAD)
#   .agents/bin/gh-agent.sh runs [branch]               recent workflow runs
#   .agents/bin/gh-agent.sh run <run-id>                jobs and steps of one run, failures first
#   .agents/bin/gh-agent.sh log <job-id>                plain-text log of one job
#   .agents/bin/gh-agent.sh gh <args...>                any gh command, authenticated
#   .agents/bin/gh-agent.sh api <METHOD> <path> [data]  raw REST call via curl
#
# Everything here works over REST with curl. The gh CLI is optional sugar; it is
# not required for branches, PRs or reading CI.
#
# The token is read from the file per command and never exported into the shell,
# never printed, and never written to gh's own config.
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$(dirname "$BIN_DIR")"

source "$AGENTS_DIR/lib/agent.sh"
source "$AGENTS_DIR/repo.conf"

: "${GITHUB_REPO:?GITHUB_REPO not set -- add it to .agents/repo.conf}"
: "${BASE_BRANCH:=main}"

PYTHON_BIN="$(command -v python3 || command -v python)" || {
  echo "Error: no python3/python on PATH. Needed to encode JSON request bodies." >&2
  exit 1
}

TOKEN_FILE="$(lua_credential_file "$AGENTS_DIR/secrets/github_token" "GitHub token" \
  "GitHub > Settings > Developer settings > Fine-grained tokens: repository $GITHUB_REPO, Contents + Pull requests + Issues read/write, Actions read-only, named for the agent.")" || exit 1

run_gh() {
  command -v gh >/dev/null 2>&1 || {
    echo "Error: gh CLI not installed. Use '$0 api <METHOD> <path>' instead." >&2
    return 127
  }
  # GH_TOKEN lives only in this one command's environment. It takes precedence
  # over anything in gh's own config, so a human login already stored there is
  # never used, and nothing is written back to it.
  GH_TOKEN="$(cat "$TOKEN_FILE")" GH_REPO="$GITHUB_REPO" \
    GH_PROMPT_DISABLED=1 gh "$@"
}

cmd_api() {
  local method="${1:?Usage: gh-agent.sh api <METHOD> <path> [json-data]}"
  local path="${2:?Usage: gh-agent.sh api <METHOD> <path> [json-data]}"
  local data="${3:-}"
  local -a args=(-sS --fail-with-body -X "$method"
    -H "Authorization: Bearer $(cat "$TOKEN_FILE")"
    -H 'Accept: application/vnd.github+json'
    -H 'X-GitHub-Api-Version: 2022-11-28')
  # Long or multi-line bodies: pass '-' and feed JSON on stdin rather than
  # building a shell-quoted string.
  if [[ "$data" == "-" ]]; then
    args+=(--data-binary @-)
  elif [[ -n "$data" ]]; then
    args+=(-d "$data")
  fi
  curl "${args[@]}" "https://api.github.com${path}"
}

cmd_whoami() {
  cmd_api GET /user |
    grep -o '"\(login\|name\)":[[:space:]]*"[^"]*"' |
    sed 's/"//g; s/:[[:space:]]*/: /'
}

# JSON-encode the arguments as an object of string fields: json_object k v k v...
# Python does the escaping, because a hand-built string breaks on the first
# quote, backslash or newline in a PR body. Python is already required to build
# this repo.
json_object() {
  "$PYTHON_BIN" -c 'import json,sys; a=sys.argv[1:]; print(json.dumps(dict(zip(a[::2],a[1::2]))))' "$@"
}

# PR creation over REST rather than through gh, so it works on a machine with no
# gh installed. Two calls: create the PR, then request the reviewer, which the
# create endpoint cannot do.
cmd_pr_create() {
  local title="${1:?Usage: gh-agent.sh pr-create <title> [body]}"
  local body="${2:-}"
  local branch response number

  branch="$(git rev-parse --abbrev-ref HEAD)"
  if [[ "$branch" == "$BASE_BRANCH" ]]; then
    echo "Error: HEAD is $BASE_BRANCH. PRs come from an agent task branch." >&2
    return 1
  fi

  response="$(json_object title "$title" head "$branch" base "$BASE_BRANCH" body "$body" |
    cmd_api POST "/repos/${GITHUB_REPO}/pulls" -)"
  number="$(printf '%s' "$response" | grep -o '"number":[[:space:]]*[0-9]\+' | head -1 |
    grep -o '[0-9]\+')"

  if [[ -z "$number" ]]; then
    echo "Error: PR not created. API said:" >&2
    printf '%s\n' "$response" >&2
    return 1
  fi
  echo "PR #${number}: https://github.com/${GITHUB_REPO}/pull/${number}"

  if [[ -n "${PR_REVIEWER:-}" ]]; then
    # Reviewer is required, so a failure here is reported rather than swallowed.
    if "$PYTHON_BIN" -c 'import json,sys; print(json.dumps({"reviewers":[sys.argv[1]]}))' "$PR_REVIEWER" |
        cmd_api POST "/repos/${GITHUB_REPO}/pulls/${number}/requested_reviewers" - >/dev/null; then
      echo "Reviewer requested: $PR_REVIEWER"
    else
      echo "Warning: PR #${number} created but reviewer '$PR_REVIEWER' was not requested." >&2
      echo "GitHub refuses a review request from the PR's own author -- request it by hand." >&2
    fi
  fi
}

fmt() { "$PYTHON_BIN" "$AGENTS_DIR/lib/format.py" "$1"; }

# PR for the branch checked out here, or an explicit number.
cmd_pr_status() {
  local number="${1:-}"
  if [[ -n "$number" ]]; then
    cmd_api GET "/repos/${GITHUB_REPO}/pulls/${number}" | fmt pr
    return
  fi
  local branch owner
  branch="$(git rev-parse --abbrev-ref HEAD)"
  owner="${GITHUB_REPO%%/*}"
  cmd_api GET "/repos/${GITHUB_REPO}/pulls?head=${owner}:${branch}&state=all&per_page=1" | fmt pr
}

# CI result for one commit, built from the Actions API rather than the Checks
# API. The Checks API would be the natural fit -- it is what a PR's "Checks" tab
# renders -- but fine-grained personal access tokens cannot be granted
# "Checks: read" at all: the permission is documented, absent from the token UI,
# and the endpoint rejects fine-grained tokens. Commit statuses are no help
# either, because GitHub Actions publishes check runs and never commit statuses,
# so that endpoint is permanently empty here.
#
# Actions: read covers workflow runs and their jobs, and for this repo every
# check is an Actions job, so nothing is actually lost.
cmd_checks() {
  local ref="${1:-HEAD}" sha runs id
  if [[ "$ref" == "HEAD" || "$ref" == "@" ]]; then
    sha="$(git rev-parse HEAD)"
  else
    sha="$(git rev-parse "$ref" 2>/dev/null || printf '%s' "$ref")"
  fi

  runs="$(cmd_api GET "/repos/${GITHUB_REPO}/actions/runs?head_sha=${sha}&per_page=20")"
  local ids
  ids="$(printf '%s' "$runs" | "$PYTHON_BIN" -c 'import json,sys
d = json.load(sys.stdin)
if "message" in d and "workflow_runs" not in d:
    sys.exit("GitHub: " + d["message"])
for r in d.get("workflow_runs", []):
    print(r["id"])')"

  if [[ -z "$ids" ]]; then
    echo "No workflow run for commit ${sha:0:12} yet."
    echo "Pushed less than a minute ago, or the paths-ignore filter in runner.yml skipped it."
    return 0
  fi

  echo "commit ${sha:0:12}"
  for id in $ids; do
    printf '%s' "$runs" | "$PYTHON_BIN" -c 'import json,sys
d = json.load(sys.stdin)
want = sys.argv[1]
for r in d.get("workflow_runs", []):
    if str(r["id"]) == want:
        s = r["conclusion"] or r["status"]
        print("\nrun {}  {}  [{}]".format(r["id"], r.get("name") or "?", s))' "$id"
    cmd_api GET "/repos/${GITHUB_REPO}/actions/runs/${id}/jobs?per_page=100" | fmt jobs
  done
}

cmd_runs() {
  local branch="${1:-}"
  local query="per_page=10"
  [[ -n "$branch" ]] && query="${query}&branch=${branch}"
  cmd_api GET "/repos/${GITHUB_REPO}/actions/runs?${query}" | fmt runs
}

cmd_run() {
  local id="${1:?Usage: gh-agent.sh run <run-id>}"
  cmd_api GET "/repos/${GITHUB_REPO}/actions/runs/${id}/jobs?per_page=100" | fmt jobs
}

# The logs endpoint answers with a redirect to a short-lived blob, so follow it.
# Output is plain text, often long -- pipe it through grep or tail.
cmd_log() {
  local id="${1:?Usage: gh-agent.sh log <job-id>}"
  curl -sS -L --fail-with-body \
    -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/${GITHUB_REPO}/actions/jobs/${id}/logs"
}

COMMAND="${1:?Usage: gh-agent.sh whoami|pr-create|pr-status|checks|runs|run|log|gh|api [args...]}"
shift || true

case "$COMMAND" in
  whoami)    cmd_whoami ;;
  pr-create) cmd_pr_create "$@" ;;
  pr-status) cmd_pr_status "$@" ;;
  checks)    cmd_checks "$@" ;;
  runs)      cmd_runs "$@" ;;
  run)       cmd_run "$@" ;;
  log)       cmd_log "$@" ;;
  gh)        run_gh "$@" ;;
  api)       cmd_api "$@" ;;
  *)
    echo "Unknown command '$COMMAND'." >&2
    echo "Use whoami, pr-create, pr-status, checks, runs, run, log, gh or api." >&2
    exit 1
    ;;
esac
