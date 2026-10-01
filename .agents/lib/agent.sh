#!/usr/bin/env bash
# Shared helper: work out which agent is running, and resolve its credential
# file. Sourced by the wrappers in .agents/bin, not run directly.
#
# Every agent that reaches GitHub uses its own personal access token, so one
# agent can be revoked without disturbing the others. Token files are named
# <base>.<agent>, live in .agents/secrets/ and are gitignored.
#
# Identity resolution, in order:
#   1. $LUA_AGENT, if set. Always wins.
#   2. Autodetection from the environment the agent sets for itself.
#   3. Nothing -- the caller is refused rather than falling back to someone
#      else's credential.
#
# Provides: lua_agent, lua_credential_file

# Lowercase, no spaces, filename-safe. Keep this list in step with AGENTS.md.
lua_agent() {
  if [[ -n "${LUA_AGENT:-}" ]]; then
    printf '%s' "$LUA_AGENT"
    return 0
  fi

  # Claude Code sets CLAUDECODE=1; AI_AGENT carries a versioned product string.
  if [[ -n "${CLAUDECODE:-}" || "${AI_AGENT:-}" == claude* ]]; then
    printf 'claude'
    return 0
  fi

  # Codex CLI marks its sandbox. CODEX_SANDBOX is not guaranteed on every
  # release, which is why LUA_AGENT exists.
  if [[ -n "${CODEX_SANDBOX:-}" || -n "${CODEX_SANDBOX_NETWORK_DISABLED:-}" || "${AI_AGENT:-}" == codex* ]]; then
    printf 'codex'
    return 0
  fi

  if [[ -n "${CURSOR_TRACE_ID:-}" ]]; then
    printf 'cursor'
    return 0
  fi

  return 1
}

# lua_credential_file <base-path> <human name> <how-to-create hint> [extension]
#
# Echoes the resolved path on success. On failure, explains what to do and
# returns non-zero -- never falls back to an unsuffixed or another agent's file.
# The agent name goes before the extension: github_app_key.claude.pem.
lua_credential_file() {
  local base="$1" what="$2" hint="$3" ext="${4:-}" agent file

  if ! agent="$(lua_agent)"; then
    cat >&2 <<EOF
Error: cannot tell which agent is running, so no $what will be used.

Credentials here are per-agent and are never shared. Set LUA_AGENT to the name
this agent should act as, then retry:

  LUA_AGENT=<agent> $0 ...

Known names are listed in AGENTS.md. Use an existing one rather than inventing
a name, or the credential file will not be found.
EOF
    return 1
  fi

  file="${base}.${agent}${ext}"

  # Linked session worktrees do not contain the main checkout's ignored secret
  # files. Resolve the shared Git directory back to the main checkout and look
  # for this same agent's credential there. Never change the agent suffix.
  if [[ ! -f "$file" ]]; then
    local search_dir common_dir common_root common_file
    # The secrets directory itself may not exist in a worktree, so start the
    # lookup from the nearest directory that does.
    search_dir="$(dirname "$base")"
    while [[ ! -d "$search_dir" && "$search_dir" != "/" && "$search_dir" != "." ]]; do
      search_dir="$(dirname "$search_dir")"
    done
    if common_dir="$(git -C "$search_dir" rev-parse \
        --path-format=absolute --git-common-dir 2>/dev/null)"; then
      common_root="$(dirname "$common_dir")"
      common_file="${common_root}/.agents/secrets/$(basename "$base").${agent}${ext}"
      if [[ -f "$common_file" ]]; then
        file="$common_file"
      fi
    fi
  fi

  if [[ ! -f "$file" ]]; then
    cat >&2 <<EOF
Error: no $what for agent '$agent' at $file

Each agent gets its own credential. Do not point this at another agent's file;
create one for '$agent':

  $hint

  printf '%s' 'VALUE_HERE' > "$file" && chmod 600 "$file"

If '$agent' is not the identity you meant, set LUA_AGENT and retry.
EOF
    return 1
  fi

  printf '%s' "$file"
}

# Absolute path of the main checkout, even when called from a linked worktree.
lua_main_root() {
  local start="${1:-$PWD}"
  dirname "$(git -C "$start" rev-parse --path-format=absolute --git-common-dir)"
}
