# Working in this repo

Instructions for any coding agent working on godot_luaAPI. **This file is canonical** — Codex and
opencode read it natively. Claude Code needs its own copy, so [CLAUDE.md](CLAUDE.md) imports this
file rather than duplicating it. **Change this file first, then propagate.**

Everything an agent needs beyond these two files lives under [`.agents/`](.agents/) — wrappers,
per-agent credentials and session worktrees — to keep the repository root as close to upstream as
possible.

---

## 1. Response style

Respond terse like smart caveman. All technical substance stay. Only fluff die.

This is how you write in this repo. Not a mode you enter. Not something that expires as a session
gets long.

Drop:

- Articles (a/an/the), filler (just/really/basically/actually/simply)
- Pleasantries (sure/certainly/of course/happy to), hedging
- Tool-call narration, decorative tables, emoji
- Long raw error-log dumps unless asked — quote the shortest decisive line

Keep exact: technical terms, code blocks, commands, class and method names, filenames, error
strings. Standard acronyms (API/ABI/GC/JIT/CI) are fine.

Never:

- Invent abbreviations (cfg/impl/req/res/fn). The tokenizer splits them the same as the full word —
  no tokens saved, reader still decodes. Full word is cheaper and clearer.
- Use causal arrows (→). Own token, saves nothing. Write the word.
- Third person or self-reference. Write "i did x", never "caveman did x". Never name or announce the
  style. No normal answer plus a terse recap.

Fragments OK. Short synonyms: big not extensive, fix not "implement a solution for".

Pattern: `[thing] [action] [reason]. [next step].`

- Not: "Sure! I'd be happy to help you with that."
- Yes: "Ref leak in `LuaCallableExtra::call`. `luaL_unref` never runs on error path. Fix:"

Match the user's language. Compress the style, not the language.

**This covers commit messages, PR bodies and issue text.** They are the worst offenders, because
length there feels like diligence. Keep every technical fact and the reason behind it; drop connective
padding, restatements of the diff, and sentences that exist to introduce the next sentence. A commit
body is short paragraphs of substance. If a line would survive deletion without losing a fact, delete
it.

**Write normally for:** code and comments; documentation committed for users (README, `DOTNET.md`,
`EXPORT.md`, `doc_classes/*.xml`); security warnings; irreversible-action confirmations; multi-step
sequences where dropped articles make the order ambiguous; and any point the user says they are
confused or repeats a question. Resume terse prose right after the part that needed clarity.

Off only on an explicit "stop caveman" or "normal mode" from the user. Not drift, not session length,
not uncertainty. If unsure, still on.

---

## 2. Repo

GDScript-facing Lua bindings for Godot 4, buildable two ways from one source tree: as an engine
**module** compiled into Godot, and as a **GDExtension** loaded by a stock editor. See
[README.md](README.md).

**Where the project stands.** `Trey2k/godot_luaAPI` is a fork of `WeaselGames/godot_luaAPI`, and
**upstream is archived** and has been for some time. The goal of the work here is to bring the binding
up to a current Godot version, get it stable, and eventually unarchive upstream. Until then **this
fork is the project**: it holds the real branches, PRs and issues, and nothing is sent anywhere else.

**Never open a pull request against `WeaselGames/godot_luaAPI`.** GitHub defaults a fork's new PR to
the parent repository, so this is the easy mistake to make, and an archived repository cannot accept
one anyway. `gh-agent.sh pr-create` pins base and head to this fork; do not route around it with the
web UI or a bare `gh pr create`. Upstream is read-only history — read it for context, write nothing
to it.

- `src/` — the binding. `src/classes/` holds the public classes, `src/lua/` the interpreter glue
- `doc_classes/*.xml` — the public API documentation, one file per exposed class
- `external/` — submodules: `godot-cpp`, `lua`, `lua51`, `luaJIT`
- `project/` — Godot project used for the demo and the test suite
- `project/testing/` — the unit tests, run headless by CI
- `scripts/` — formatting and spell-check gates, plus the GDExtension `SConstruct`
- `.github/workflows/` — `runner.yml` is the entry point; it calls the per-platform workflows
- `.agents/` — agent wrappers, credentials, session worktrees

GDExtension build from the repo root:

```bash
scons target=template_debug platform=<platform> arch=<arch>      # Lua
scons target=template_debug platform=<platform> arch=<arch> luaapi_luaver=jit   # LuaJIT
```

Binaries land in `project/addons/luaAPI/bin/`. Module builds happen inside a Godot source checkout
with this repo cloned to `modules/luaAPI`, per README.

Tests are a headless run of the Godot project, not a separate harness:

```bash
<godot-binary> --headless --path project/
```

It writes `project/log.txt`. CI reads that file; a failing assertion shows up there, so read it
rather than trusting a zero exit code.

### Submodules

`external/` is submodules. Never commit a submodule pointer bump as a side effect of some other
change, and never edit files inside `external/` — upstream fixes go upstream. A clone needs
`--recurse-submodules`; if headers are missing, that is why.

---

## 3. Static checks gate every PR

`static-checks.yml` runs before any build job, over the changed files only. Run the same scripts
locally before pushing — a formatting failure wastes a whole CI matrix:

```bash
bash scripts/file_format.sh <file>...    # line endings, trailing whitespace, BOM, final newline
bash scripts/clang_format.sh <file>...   # C++ style, per .clang-format
bash scripts/codespell.sh                # spelling
```

`.clang-format` and `.clang-tidy` are the style, not a suggestion. Do not reformat lines a change
does not touch.

**A new or changed exposed class, method, signal or constant needs its `doc_classes/*.xml` updated in
the same commit.** The XML is checked by CI and is what Godot's in-editor help shows. Changing a
binding without the doc is an incomplete change.

---

## 4. Where facts live

**GitHub issues are the source of truth for anything outstanding.** Open questions, known gaps,
deferred decisions and TODOs belong at https://github.com/Trey2k/godot_luaAPI/issues — this fork's own
tracker — not in a file in this repo and not in a comment. The archived upstream tracker is history;
it may explain why something is the way it is, but nothing outstanding lives there and nothing is
filed there.

```bash
.agents/bin/gh-agent.sh api GET '/repos/Trey2k/godot_luaAPI/issues?state=open'
```

**Committed documentation is context, and nothing else.** `README.md` is how to install and build,
`EXPORT.md` export quirks, `DOTNET.md` the .NET path, `doc_classes/` the API reference. None of them
is a work-item list.

**The code is the source of truth for behavior.** Read the binding rather than quoting a remembered
signature; the API has changed shape more than once.

---

## 5. Confirm before writing

Ask first, act after an answer. Each of these is visible outside this machine or hard to undo.

- **Opening a PR or pushing a branch.** Say what the branch contains.
- **Creating or commenting on a GitHub issue.** Show the title and substance. It may already be
  tracked or already fixed. This repo is public — an issue is published the moment it is created.
- **Editing `.github/workflows/`, `SConstruct`, `config.py` or submodule pointers.** These break every
  contributor's build, not just this checkout. A workflow change also **executes in CI as soon as the
  branch is pushed**, with no review in front of it — see section 6.
- **Any change to the public API** — renaming or removing an exposed class, method, signal or
  constant. That breaks user projects silently at runtime.

Read-only API queries need no confirmation.

**Agents never merge a pull request — not even their own, not even after CI goes green.** Opening the
PR is where an agent's work ends. Merging is Trey's. See *What actually keeps an agent in its lane*
in section 6 for why this is a written rule rather than something GitHub enforces.

---

## 6. Agent work is session-safe and in its own worktree

**Root checkout always represents `main`. Never switch it to a task branch, never edit tracked files
there, never commit there.** Root is for read-only inspection, fast-forward updates and worktree
management.

Every task gets a branch named `<agent>/<task-slug>` and one linked worktree at
`.agents/worktrees/<agent>/<task-slug>`, which is gitignored. `git-agent.sh worktree` creates both
and sets the commit identity, which is the part that is easy to forget:

```bash
cd <repo-root>
.agents/bin/git-agent.sh pull                     # fast-forward main over HTTPS as the agent
.agents/bin/git-agent.sh worktree <task-slug>     # worktree + branch + commit identity
cd .agents/worktrees/<agent>/<task-slug>
```

All edits, builds, tests, staging and commits happen inside that worktree. One worktree belongs to
one branch; never reuse it for another branch. If root is dirty or cannot fast-forward, stop and
report the blocker. After a PR merges, remove only a clean worktree with `git worktree remove`, then
`git worktree prune`.

A worktree does not contain the ignored files from root. Build artifacts and `.agents/secrets/` stay
in the main checkout; the wrappers already resolve credentials back to it.

### Git talks to GitHub as the agent, never over Trey's SSH key

`origin` is `git@github.com:Trey2k/godot_luaAPI.git` and that SSH key is Trey's. **Agents never use
it.** Every agent operation that reaches GitHub goes over HTTPS with that agent's own token, through
[`.agents/bin/git-agent.sh`](.agents/bin/git-agent.sh):

```bash
.agents/bin/git-agent.sh fetch
.agents/bin/git-agent.sh pull
.agents/bin/git-agent.sh push -u HEAD:refs/heads/<agent>/<task-slug>
```

The wrapper builds the HTTPS URL from `.agents/repo.conf` and feeds the token to git through an
inline credential helper, so the secret never enters the remote URL, the process list, the reflog or
a config file. It also clears any inherited credential helper first — otherwise Git Credential
Manager answers first and blocks on a login prompt nobody is there to answer.

**Never push to `main`, and never force-push, delete or rewrite any branch.** `git-agent.sh push`
refuses all of those, plus any destination not named `<agent>/<task-slug>`. If push or PR creation
fails, leave the work on the task branch and report the blocker. Do not fall back to the SSH remote,
to Trey's credentials, or to plain `git push` to get around the wrapper.

**Commit identity is worktree-scoped, and it has to be.** A linked worktree shares `.git/config` with
the main checkout, so `git config --local user.email` from inside a worktree rewrites the *root*
checkout's identity and every later commit Trey makes there would carry it. `configure` turns on
`extensions.worktreeConfig` and writes through `git config --worktree`, which lands in
`.git/worktrees/<name>/config.worktree` and leaves root alone. It refuses to run in the main
checkout. Never set an agent identity with `--local` or `--global`.

```bash
.agents/bin/git-agent.sh identity     # prints the Name <email> commits will carry
.agents/bin/git-agent.sh configure    # writes worktree-scoped user.name / user.email
```

Both read `login`, `name` and `id` from `GET /user` with the agent's own token, so the identity
matches the account GitHub will attribute the push to. A private profile email falls back to that
account's `users.noreply.github.com` address.

### Pull requests

Push the branch, then open a PR targeting `main`:

```bash
.agents/bin/gh-agent.sh pr-create "<title>" "<body>"
```

It fills base, head and reviewer from `.agents/repo.conf` and refuses to run from `main`. The PR is
authored by the agent's bot user, so requesting Trey as reviewer works normally. If `pr-create` ever
warns that the reviewer was not requested, the agent is running on the fallback personal access token
instead of its app — GitHub rejects a review request whose requester is the PR's own author. Check
`gh-agent.sh whoami`; do not paper over it by assigning someone else.

Everything the wrapper does runs over REST with `curl`. The `gh` CLI is optional sugar and is not
installed on this machine; nothing in `.agents/` depends on it.

```bash
.agents/bin/gh-agent.sh pr-status            # PR for the current branch: state, mergeability, reviewers
.agents/bin/gh-agent.sh pr-status 123        # a specific PR
.agents/bin/gh-agent.sh api GET /repos/Trey2k/godot_luaAPI/pulls
.agents/bin/gh-agent.sh api POST /repos/Trey2k/godot_luaAPI/issues -   # JSON on stdin
```

Pass long or multi-line bodies on stdin with `-` rather than building a shell-quoted string.

### Reading CI, which is where a PR actually passes or fails

`runner.yml` fans out into a big matrix: static checks, then per-platform module and GDExtension
builds, then the unit-test jobs. **A pushed branch is not done until those pass.** Read the result
rather than assuming it:

```bash
.agents/bin/gh-agent.sh checks            # every job for HEAD's commit, grouped by workflow run
.agents/bin/gh-agent.sh checks <sha>      # a specific commit
.agents/bin/gh-agent.sh runs <branch>     # recent workflow runs, with their run ids
.agents/bin/gh-agent.sh run <run-id>      # jobs of one run, failures first, with failed step names
.agents/bin/gh-agent.sh log <job-id>      # plain-text log of one job
```

`checks` is keyed by **commit**, not by branch — a stale-looking answer usually means a newer commit
was pushed, so re-read after a push rather than trusting the previous answer. It reads Actions runs
rather than the Checks API, because a fine-grained token cannot be granted Checks access at all; see
the credentials section. `run` prints the
`log <job-id>` command for each failed job. Job logs are long: pipe through `grep` or `tail` and quote
the shortest decisive line rather than pasting the dump.

A matrix job that fails on one platform only is the normal failure here, usually a compiler that is
stricter than the local one. Fix it for that platform; do not disable the job.

### Credentials are per-agent, and each agent is its own GitHub App

**Every agent authenticates as its own GitHub App.** A commit and a pull request are therefore
authored by that agent's bot user — `trey-agent-claude[bot]` for `claude` — and never by a human. One
agent is revoked by deleting its key or uninstalling its app, without disturbing the others.

Two files per agent, and only one of them is a secret:

```
.agents/apps.conf                               app registry, committed, not secret
.agents/secrets/github_app_key.<agent>.pem      private key, gitignored, never leaves this machine
.agents/secrets/app_owner                       which owner's app this machine uses, if ambiguous
```

**The registry is keyed `<github-owner>.<agent>`, not by agent name alone**, because more than one
person can run a Claude agent against this repo and each has their own app:

```bash
declare -A GITHUB_APP_IDS=(
  [trey2k.claude]=5154233
)
```

With one entry for an agent it is used directly. With several, say which is yours through
`LUA_APP_OWNER` or `.agents/secrets/app_owner` — one lowercase GitHub login, in the main checkout, not
in a worktree. **An owner that matches nothing is refused, not fallen back on:** a typo would otherwise
authenticate with whatever credential is lying around, which is the opposite of the point.

Adding yourself: create an app, install it on this repository, drop its key at
`.agents/secrets/github_app_key.<agent>.pem`, add a line to the registry, and set `app_owner` if the
registry now holds more than one app for your agent.

The wrappers exchange that key for an **installation token that expires in an hour**, cached in
`.agents/secrets/.app_token_cache.<agent>`. That is the point of app auth: a leaked token is dead
within the hour, where a leaked personal access token is good until someone notices. The key is the
only long-lived secret, and it is used solely to sign a short-lived JWT.

The installation id is looked up at runtime rather than configured, because reinstalling the app
changes it and a stale value fails confusingly.

Known agent names: **`claude`** (set up now), with **`codex`** and **`cursor`** recognised by the
detector if apps are added later. Use one of these — a name the wrappers do not know will not find a
credential.

[`.agents/lib/agent.sh`](.agents/lib/agent.sh) works out which agent is running. It reads
`$LUA_AGENT` if set, otherwise detects from the environment each agent sets for itself. **If it
cannot tell, it refuses rather than falling back to somebody else's credential.** Detection is
best-effort, so set `LUA_AGENT` explicitly when a wrapper says it cannot identify you:

```bash
LUA_AGENT=claude .agents/bin/gh-agent.sh whoami
```

App permissions, per agent, on this repository only:

| Permission | Level | Needed for |
|---|---|---|
| Contents | Read and write | pushing `<agent>/<slug>` branches |
| Pull requests | Read and write | `pr-create`, `pr-status` |
| Issues | Read and write | reading and filing issues |
| Actions | Read-only | `checks`, `runs`, `run`, `log` |
| Checks | Read-only | available to apps, unlike fine-grained tokens |
| Workflows | Read and write | editing `.github/workflows/`; see the warning below |
| Metadata | Read-only | required by GitHub for all of the above |

**Workflows is granted, and it is the permission to respect.** CI modernisation is agent work here —
the build matrix needs it — so agents can edit `.github/workflows/`. Know what that means:

**A workflow change runs in CI the moment the branch is pushed, before any human looks at it.** The
`pull_request` trigger executes the version on the branch, so agent-authored CI code executes without
review. There is no approval gate in front of it.

What keeps that bounded, and it is not much:

- This repo uses **no custom secrets**. `GITHUB_TOKEN` is the only one referenced, in
  `static-checks.yml`. Nothing can be exfiltrated that is not already public.
- No `pull_request_target` or `workflow_run` triggers, which are the ones that hand a branch's code
  write-scoped credentials.
- `GITHUB_TOKEN` default permissions should stay **read-only** in Settings > Actions > General, so a
  workflow an agent writes cannot push, tag or comment with it.

So: workflow edits are confirm-first under section 5, and that rule carries real weight here rather
than being bureaucratic. Say what the change is and why before pushing it. Never add a step that
exports a secret, posts repository contents anywhere, or weakens `static-checks.yml` to make a failing
PR pass — rewrite the code the check is complaining about instead.

`gh-agent.sh checks` reads the Actions API even though apps may hold `Checks: read`, because every
check in this repo is an Actions job and the Actions path also works for an agent still on a token.

**Without an app, the wrappers refuse to run.** They do not quietly fall back to a personal access
token. A token lives on a human's account, so falling back makes every commit, PR and issue comment
look like that human's own work — the exact thing the apps exist to prevent, and it is not something
to discover afterwards from the byline.

This is not hypothetical. It happened from a checkout whose `.agents/` predated app support: there
was no `apps.conf`, the fallback engaged silently, and an issue comment was published under Trey's
name. The usual cause is a stale checkout, so the error says so and the first thing to try is
`git pull --ff-only`.

`LUA_ALLOW_PAT=1` re-enables the token path for one command, and prints a warning naming the account
the work will be attributed to. Use it only when that attribution is genuinely wanted.
`gh-agent.sh whoami` prints the active mode, and is worth running when something looks off.

**Creating an app is Trey's job, not an agent's.** The private key is shown once, at creation. If a
credential is missing, the wrapper prints what to create. Ask; do not work around it, and never read
or copy another agent's key.

**Read secrets inline per command. Never export them into the shell, never print them, never write
them into `gh`'s config.** The wrappers already do this — use them rather than calling `curl` or `gh`
directly.

`.agents/repo.conf` and `.agents/apps.conf` are non-secret and committed. `app_owner` is not secret
either, but it is per-machine, so it stays gitignored alongside the keys.


### What actually keeps an agent in its lane

Three layers, and they are not equally strong. Know which is which before trusting any of them.

**1. The ruleset on `main` — the only real boundary.** Server-side, applied by GitHub:

| Rule | Effect |
|---|---|
| Require a pull request before merging, 1 approval | nothing reaches `main` unreviewed |
| Block force pushes | `main` history cannot be rewritten |
| Restrict deletions | `main` cannot be deleted |

**One approval is what makes this enforcement rather than etiquette.** Each agent is a separate GitHub
App, so its bot user is the PR author and Trey's approval counts — and GitHub forbids approving your
own PR, so the agent cannot approve its own work. An agent therefore cannot land anything Trey has not
reviewed, which is a server-side guarantee rather than a rule in this file.

Bypass is **Repository admin**, so Trey keeps direct push to `main` while every app is bound by the
rules. Status checks are deliberately **not** required: `runner.yml` skips doc-only changes via
`paths-ignore`, so a required-check rule would leave a documentation PR permanently unmergeable. Read
CI with `gh-agent.sh checks` and judge instead.

**2. The app's permission set.** Administration is not granted, so repository settings, the ruleset
and collaborators are out of reach. Actions is read-only, so an agent cannot dispatch or re-run a
workflow directly — though with Workflows write it can change what a workflow does, and a push runs it.
Treat Workflows as the widest permission the app holds; the credentials section says why.

**3. `git-agent.sh push` — mistake prevention, not security.** It refuses `main`, refuses `--force`
and `--delete`, and refuses any branch not named `<agent>/<task-slug>`. An agent can reach the app key
and mint its own token, so this layer stops accidents and nothing more. It is still worth having, and
working around it is a rule violation rather than a clever shortcut.

**What is still trusted rather than enforced.** `Pull requests: write` is one permission for both
opening and merging, so an agent could merge a PR that Trey has already approved, and the rule in
section 5 — agents never merge — is what prevents that. The approval requirement means it cannot merge
anything *unreviewed*, which was the part worth closing. Outside `main` an agent can still create and
delete other branches and tags; branch noise is visible and cheap to clean, and `main` is where damage
would be permanent.


### Shell

Use Bash for the `.agents/` wrappers; they are Bash scripts and depend on it. Builds (`scons`) run in
whatever shell the platform's toolchain needs. Never wrap a Bash wrapper in PowerShell.

---

## 7. Tool-specific mechanics

- **Claude Code** enforces the response style through
  [`.claude/output-styles/caveman-full.md`](.claude/output-styles/caveman-full.md), selected in
  [`.claude/settings.json`](.claude/settings.json). That puts the rule in the system prompt rather
  than in a per-turn reminder, so a long run of tool calls cannot bury it. `/caveman lite|full|ultra`
  switches intensity; default here is **full**.
- **Codex, opencode and anything else that reads `AGENTS.md`** take this file as standing
  instructions. There is no slash command to switch intensity — the level here is full.
- **Commit messages carry no `Co-Authored-By` trailer and no generated-by line.** Not for the agent,
  not for the model, not in commit messages and not in PR bodies. What identifies the agent is the
  commit author and the `<agent>/<task-slug>` branch name.
