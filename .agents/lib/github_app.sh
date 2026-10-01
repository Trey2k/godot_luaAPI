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

lua_app_id() {
  local agent="$1" var
  var="GITHUB_APP_ID_${agent}"
  printf '%s' "${!var:-}"
}

# True when this agent has both an app id and a private key, so app auth is
# possible. Lets the wrappers prefer app auth and fall back to a token.
lua_app_configured() {
  local agent
  agent="$(lua_agent)" || return 1
  [[ -n "$(lua_app_id "$agent")" ]] || return 1
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
