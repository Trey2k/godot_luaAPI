#!/usr/bin/env bash
# Git operations that talk to GitHub with the agent's own token, never with a
# human's SSH key.
#
# The `origin` remote is SSH and its key belongs to a human. Agents never use it. Every agent operation that reaches GitHub --
# fetch, pull, push -- goes over HTTPS authenticated with that agent's own
# personal access token, supplied through an inline credential helper so the
# secret never enters the remote URL, the process list, the reflog or a config
# file.
#
# Usage:
#   .agents/bin/git-agent.sh identity              print "Name <email>" for the token's account
#   .agents/bin/git-agent.sh configure [repo-dir]  set commit identity, worktree-scoped
#   .agents/bin/git-agent.sh worktree <task-slug>  new worktree + branch, identity set
#   .agents/bin/git-agent.sh fetch [git args...]
#   .agents/bin/git-agent.sh pull  [git args...]   fast-forward only
#   .agents/bin/git-agent.sh push  [git args...]
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$(dirname "$BIN_DIR")"
REPO_DIR="$(dirname "$AGENTS_DIR")"

source "$AGENTS_DIR/lib/agent.sh"
source "$AGENTS_DIR/repo.conf"
source "$AGENTS_DIR/apps.conf"

: "${GITHUB_REPO:?GITHUB_REPO not set -- add it to .agents/repo.conf}"
: "${BASE_BRANCH:=main}"

AGENT="$(lua_agent)" || {
  echo "Error: cannot tell which agent is running. Set LUA_AGENT and retry." >&2
  exit 1
}

PYTHON_BIN="$(command -v python3 || command -v python)" || {
  echo "Error: no python3/python on PATH. Needed to read API responses." >&2
  exit 1
}

source "$AGENTS_DIR/lib/github_app.sh"

# App auth when this agent has an app id and a private key, personal access token
# otherwise. Under app auth the commit author is the agent's own bot user, which
# is the point: a commit and a pull request are not attributed to a human.
if lua_app_configured; then
  AUTH_MODE="app"
elif [[ "${LUA_ALLOW_PAT:-}" == "1" ]]; then
  # Opt-in only. A silent downgrade is worse than no credential: a token on a
  # human's account makes every agent commit, PR and comment look like that
  # human's own work, which is what the apps exist to prevent. That has already
  # happened once, from a checkout whose .agents/ predated app support.
  AUTH_MODE="pat"
  TOKEN_FILE="$(lua_credential_file "$AGENTS_DIR/secrets/github_token" "GitHub token" \
    "GitHub > Settings > Developer settings > Fine-grained tokens: repository $GITHUB_REPO, Contents + Pull requests + Issues read/write, Actions read-only, named for the agent.")" || exit 1
  echo "Warning: authenticating with a personal access token, not an app." >&2
  echo "Work done now is attributed to the token's account, not to this agent." >&2
else
  cat >&2 <<EOF
Error: no GitHub App configured for agent '$(lua_agent 2>/dev/null || echo unknown)'.

App auth needs an id in .agents/apps.conf and a key at
.agents/secrets/github_app_key.<agent>.pem. Check both, and check this checkout
is current: a stale .agents/ with no apps.conf looks exactly like this.

Refusing to fall back to a personal access token, which would attribute this
agent's work to a human. Set LUA_ALLOW_PAT=1 for one command if that is
genuinely wanted.
EOF
  exit 1
fi

auth_token() {
  if [[ "$AUTH_MODE" == "app" ]]; then
    lua_app_token
  else
    cat "$TOKEN_FILE"
  fi
}

REMOTE_URL="https://github.com/${GITHUB_REPO}.git"

# Inline credential helper. Keeping the token out of argv and out of the URL
# means it does not land in the process list, the reflog or a remote config.
# The first empty -c clears any inherited helper, so Git Credential Manager
# cannot answer first and prompt for a login nobody is there to give.
git_authed() {
  local token
  token="$(auth_token)" || return 1
  # The token reaches git through a credential helper and an environment variable
  # scoped to this one git process, so it stays out of the remote URL, the remote
  # config, the reflog and the process list. Resolved per call, because an app
  # installation token expires within the hour.
  LUA_GIT_TOKEN="$token" git -c credential.helper= \
      -c "credential.helper=!f(){ test \"\$1\" = get && printf 'username=%s\\npassword=%s\\n' 'x-access-token' \"\$LUA_GIT_TOKEN\"; }; f" \
      "$@"
}

api_get() {
  local path="$1"
  curl -sSf \
    -H "Authorization: Bearer $(auth_token)" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com${path}"
}

json_field() {
  # json_field <field> -- first match, strings and numbers both.
  grep -o "\"$1\":[[:space:]]*\(\"[^\"]*\"\|[0-9]\+\)" | head -1 |
    sed 's/^[^:]*:[[:space:]]*//; s/^"//; s/"$//'
}

# The account behind the token decides how GitHub attributes a push. Read name,
# login and id from the API so the commit identity matches that account instead
# of being guessed. A private profile email is normal, so fall back to the
# account's noreply address, which GitHub always links to the same user.
bot_identity() {
  # Under app auth the identity is the app's own bot user; an installation token
  # has no user behind it, so GET /user is not the question to ask.
  if [[ "$AUTH_MODE" == "app" ]]; then
    lua_app_bot_identity
    return
  fi
  local json name login id email
  json="$(api_get /user)"
  name="$(printf '%s' "$json" | json_field name)"
  login="$(printf '%s' "$json" | json_field login)"
  id="$(printf '%s' "$json" | json_field id)"
  email="$(printf '%s' "$json" | json_field email)"

  if [[ -z "$login" || -z "$id" ]]; then
    echo "Error: GitHub /user returned no login/id -- token invalid or lacks read access." >&2
    return 1
  fi
  [[ -n "$name" ]] || name="$login"
  [[ -n "$email" ]] || email="${id}+${login}@users.noreply.github.com"

  printf '%s\t%s\n' "$name" "$email"
}

cmd_identity() {
  local id name email
  id="$(bot_identity)"
  name="${id%%$'\t'*}"
  email="${id#*$'\t'}"
  printf '%s <%s>\n' "$name" "$email"
}

# A linked worktree shares .git/config with the main checkout, so `config
# --local` from inside one rewrites the root checkout's identity. `config
# --worktree` writes to the worktree's own config file instead, which needs
# extensions.worktreeConfig on.
cmd_configure() {
  local target="${1:-$PWD}" id name email git_dir common_dir

  git_dir="$(git -C "$target" rev-parse --path-format=absolute --git-dir)"
  common_dir="$(git -C "$target" rev-parse --path-format=absolute --git-common-dir)"
  if [[ "$git_dir" == "$common_dir" ]]; then
    cat >&2 <<EOF
Error: $target is the main checkout, not a linked worktree.

Agents do not commit in the root checkout. Create a worktree and work there:

  $0 worktree <task-slug>
EOF
    return 1
  fi

  id="$(bot_identity)"
  name="${id%%$'\t'*}"
  email="${id#*$'\t'}"

  git -C "$target" config --local extensions.worktreeConfig true
  git -C "$target" config --worktree user.name "$name"
  git -C "$target" config --worktree user.email "$email"
  echo "Commit identity for this worktree: $name <$email>"
}

cmd_worktree() {
  local slug="${1:?Usage: git-agent.sh worktree <task-slug>}"
  local branch="${AGENT}/${slug}"
  local main_root path
  main_root="$(lua_main_root "$REPO_DIR")"
  path="$main_root/.agents/worktrees/${AGENT}/${slug}"

  # Fail before creating anything if the token cannot name an account; a
  # worktree with no commit identity is the half-done state worth avoiding.
  bot_identity >/dev/null

  git -C "$main_root" worktree add "$path" -b "$branch" "$BASE_BRANCH"
  cmd_configure "$path"
  echo "$path"
}

# Refuse the pushes an agent has no business making: anything at the base
# branch, any force, any delete, and any branch not named for this agent.
#
# This is a guard against mistakes, NOT a security boundary. An agent holds the
# token file and can invoke git itself, so nothing here can stop a determined
# caller. The enforceable protection is the ruleset on the base branch, which
# GitHub applies server-side. Keep both.
cmd_push() {
  local arg dest branch
  for arg in "$@"; do
    case "$arg" in
      --force|-f|--force-with-lease|--force-with-lease=*|--force-if-includes)
        echo "Error: refusing to force-push. Rewriting a pushed branch loses review history." >&2
        echo "If a rebase is genuinely wanted, a human does it." >&2
        return 1
        ;;
      --delete|-d|--mirror|--prune)
        echo "Error: refusing to delete remote refs. Branch cleanup happens after a merge." >&2
        return 1
        ;;
    esac
  done

  # Check every refspec's destination. A refspec is src:dest, or a bare ref that
  # is both. Options and their values are skipped.
  for arg in "$@"; do
    [[ "$arg" == -* ]] && continue
    dest="${arg##*:}"
    dest="${dest#refs/heads/}"
    [[ -z "$dest" || "$dest" == "HEAD" ]] && continue
    if [[ "$dest" == "$BASE_BRANCH" || "$dest" == "refs/heads/$BASE_BRANCH" ]]; then
      echo "Error: refusing to push to '$BASE_BRANCH'. Agents open a PR instead." >&2
      return 1
    fi
    if [[ "$dest" != "${AGENT}/"* ]]; then
      echo "Error: refusing to push '$dest'. Agent branches are named '${AGENT}/<task-slug>'." >&2
      echo "Pushing another agent's or a human's branch is not this agent's work." >&2
      return 1
    fi
  done

  # No refspec given: whatever is checked out here is the destination.
  if [[ $# -eq 0 || "$*" == "-u" ]]; then
    branch="$(git rev-parse --abbrev-ref HEAD)"
    if [[ "$branch" != "${AGENT}/"* ]]; then
      echo "Error: HEAD is '$branch', not an '${AGENT}/<task-slug>' branch. Refusing to push." >&2
      return 1
    fi
  fi

  git_authed push "$REMOTE_URL" "$@"
}

COMMAND="${1:?Usage: git-agent.sh identity|configure|worktree|fetch|pull|push [args...]}"
shift || true

case "$COMMAND" in
  identity)  cmd_identity ;;
  configure) cmd_configure "$@" ;;
  worktree)  cmd_worktree "$@" ;;
  fetch)     git_authed fetch "$REMOTE_URL" "$@" ;;
  pull)      git_authed pull --ff-only "$REMOTE_URL" "$@" ;;
  push)      cmd_push "$@" ;;
  *)
    echo "Unknown command '$COMMAND'. Use identity, configure, worktree, fetch, pull or push." >&2
    exit 1
    ;;
esac
