#!/usr/bin/env bash
# Mint a GitHub App installation token for the running agent. Sourced by the
# wrappers in .agents/bin, not run directly.
#
# Each agent is its own GitHub App, so a commit and a pull request are authored
# by that agent's bot user rather than by a human, and one agent can be revoked
# by deleting its key without touching the others.
#
# An installation token lives one hour. That is the point: a leaked token is dead
# within the hour, where a leaked personal access token is good for its full
# lifetime. The long-lived secret is the app's private key, which never leaves
# this machine and is only ever used to sign a short JWT.
#
# Provides: lua_app_configured, lua_app_token, lua_app_bot_identity

# shellcheck source=./agent.sh
# agent.sh must already be sourced by the caller: lua_agent, lua_credential_file.

# Which GitHub owner's app this machine should use. More than one person can run
# the same agent against this repo, so the agent name alone does not identify an
# app. Order: $LUA_APP_OWNER, then .agents/secrets/app_owner, then nothing, which
# is fine as long as the registry holds exactly one app for this agent.
lua_app_owner() {
  if [[ -n "${LUA_APP_OWNER:-}" ]]; then
    printf '%s' "${LUA_APP_OWNER,,}"
    return 0
  fi

  local file owner
  # A linked worktree has no ignored files of its own, so fall back to the main
  # checkout, the same way credentials resolve.
  for file in "${AGENTS_DIR}/secrets/app_owner" "$(lua_app_owner_path)"; do
    if [[ -n "$file" && -f "$file" ]]; then
      owner="$(tr -d '[:space:]' < "$file")"
      [[ -n "$owner" ]] || continue
      printf '%s' "${owner,,}"
      return 0
    fi
  done
  return 1
}

# Where the owner marker belongs: the main checkout, never a worktree.
lua_app_owner_path() {
  local root
  root="$(lua_main_root "$AGENTS_DIR" 2>/dev/null)" || return 0
  printf '%s/.agents/secrets/app_owner' "$root"
}

# App id for <owner>.<agent>. With no owner set, a single registry entry for this
# agent is used; two or more is ambiguous and refused rather than guessed, since
# guessing would authenticate as somebody else's app.
lua_app_id() {
  local agent="${1,,}" owner key matches=()

  if owner="$(lua_app_owner)"; then
    key="${owner}.${agent}"
    if [[ -z "${GITHUB_APP_IDS[$key]:-}" ]]; then
      # Refuse rather than fall back. A typo here would otherwise end up
      # authenticating with whatever token happens to be on this machine.
      cat >&2 <<EOF
Error: no app registered for '$key' in .agents/apps.conf.

Registered: ${!GITHUB_APP_IDS[*]}

Fix the owner in $(lua_app_owner_path), or in LUA_APP_OWNER, or add your app to
.agents/apps.conf. Not falling back to another credential.
EOF
      return 1
    fi
    printf '%s' "${GITHUB_APP_IDS[$key]}"
    return 0
  fi

  for key in "${!GITHUB_APP_IDS[@]}"; do
    [[ "${key##*.}" == "$agent" ]] && matches+=("$key")
  done

  if [[ "${#matches[@]}" -eq 1 ]]; then
    printf '%s' "${GITHUB_APP_IDS[${matches[0]}]}"
    return 0
  fi

  if [[ "${#matches[@]}" -gt 1 ]]; then
    cat >&2 <<EOF
Error: .agents/apps.conf holds more than one app for agent '$agent':

  ${matches[*]}

Say which one is yours, then retry:

  echo '<your-github-login>' > "$(lua_app_owner_path)"

or set LUA_APP_OWNER for a single command. Never pick another person's app.
EOF
    return 1
  fi

  return 0
}

# True when this agent has both an app id and a private key, so app auth is
# possible. Lets the wrappers prefer app auth and fall back to a token.
lua_app_configured() {
  local agent id
  agent="$(lua_agent)" || return 1
  # An ambiguous registry is fatal rather than a reason to fall back: falling
  # back would authenticate as whatever token is lying around, which is the
  # opposite of what per-agent credentials are for.
  id="$(lua_app_id "$agent")" || exit 1
  [[ -n "$id" ]] || return 1
  [[ -n "$(lua_app_key_file 2>/dev/null)" ]] || return 1
}

lua_app_key_file() {
  lua_credential_file "${AGENTS_DIR}/secrets/github_app_key" "GitHub App private key" \
    "Create the app at https://github.com/settings/apps, generate a private key, and save it here." \
    ".pem"
}

base64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

# A JWT proves to GitHub that we hold the app's private key. GitHub rejects an
# exp more than 10 minutes out and is picky about clock skew, so iat is backdated
# a minute and exp kept short.
lua_app_jwt() {
  local agent app_id key_file now header payload signing_input signature
  agent="$(lua_agent)"
  app_id="$(lua_app_id "$agent")"
  key_file="$(lua_app_key_file)" || return 1
  now="$(date +%s)"

  header="$(printf '{"alg":"RS256","typ":"JWT"}' | base64url)"
  payload="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$app_id" | base64url)"
  signing_input="${header}.${payload}"

  signature="$(printf '%s' "$signing_input" |
    openssl dgst -sha256 -sign "$key_file" -binary | base64url)"

  printf '%s.%s' "$signing_input" "$signature"
}

# Call the API as the app itself rather than as an installation. Used only to
# find the installation and to read the app's own slug.
lua_app_api() {
  local path="$1" jwt
  jwt="$(lua_app_jwt)" || return 1
  curl -sS --fail-with-body \
    -H "Authorization: Bearer $jwt" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com${path}"
}

# The installation id is discovered rather than configured: it changes if the app
# is reinstalled, and a stale hardcoded value fails in a confusing way.
lua_app_installation_id() {
  lua_app_api "/repos/${GITHUB_REPO}/installation" |
    "$PYTHON_BIN" -c 'import json,sys
d = json.load(sys.stdin)
if "id" not in d:
    sys.exit("GitHub: " + d.get("message", "no installation for this repository"))
print(d["id"])'
}

# Cached installation token. Minting one costs two API round trips, and every
# wrapper command would otherwise pay them. The cache file holds "<expiry>
# <token>" and lives beside the other secrets, so the gitignore that covers them
# covers it too.
lua_app_token() {
  local agent cache now expiry token install_id response
  agent="$(lua_agent)" || return 1
  cache="${AGENTS_DIR}/secrets/.app_token_cache.${agent}"
  now="$(date +%s)"

  if [[ -f "$cache" ]]; then
    read -r expiry token < "$cache" || true
    # Five minutes of headroom: a token that expires mid-push is worse than one
    # extra mint.
    if [[ -n "${token:-}" && -n "${expiry:-}" && "$expiry" -gt "$((now + 300))" ]]; then
      printf '%s' "$token"
      return 0
    fi
  fi

  install_id="$(lua_app_installation_id)" || return 1

  # The access_tokens endpoint is a POST, which lua_app_api does not do.
  local jwt
  jwt="$(lua_app_jwt)" || return 1
  response="$(curl -sS --fail-with-body -X POST \
    -H "Authorization: Bearer $jwt" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/app/installations/${install_id}/access_tokens")"

  token="$("$PYTHON_BIN" -c 'import json,sys
d = json.loads(sys.argv[1])
if "token" not in d:
    sys.exit("GitHub: " + d.get("message", "no token in response"))
print(d["token"])' "$response")" || return 1

  # expires_at is ISO 8601 UTC; store it as epoch so the check above is cheap.
  expiry="$("$PYTHON_BIN" -c 'import calendar,json,sys,time
d = json.loads(sys.argv[1])
print(calendar.timegm(time.strptime(d["expires_at"], "%Y-%m-%dT%H:%M:%SZ")))' "$response")"

  printf '%s %s\n' "$expiry" "$token" > "$cache"
  chmod 600 "$cache" 2>/dev/null || true
  printf '%s' "$token"
}

# Commit identity for the app's bot user. An installation token has no user, so
# GET /user does not work here: the slug comes from the app itself, and the bot
# user's numeric id from the users endpoint. GitHub links a commit to the bot
# when the email is <id>+<slug>[bot]@users.noreply.github.com.
lua_app_bot_identity() {
  local slug id
  slug="$(lua_app_api /app | "$PYTHON_BIN" -c 'import json,sys
d = json.load(sys.stdin)
if "slug" not in d:
    sys.exit("GitHub: " + d.get("message", "app lookup failed"))
print(d["slug"])')" || return 1

  id="$(curl -sS --fail-with-body \
    -H "Authorization: Bearer $(lua_app_token)" \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/users/${slug}%5Bbot%5D" |
    "$PYTHON_BIN" -c 'import json,sys
d = json.load(sys.stdin)
if "id" not in d:
    sys.exit("GitHub: " + d.get("message", "bot user lookup failed"))
print(d["id"])')" || return 1

  printf '%s[bot]\t%s+%s[bot]@users.noreply.github.com\n' "$slug" "$id" "$slug"
}
