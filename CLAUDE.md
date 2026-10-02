# godot_luaAPI — Claude Code

@AGENTS.md

**[AGENTS.md](AGENTS.md) is the canonical instruction file and is imported above.** It is not
duplicated here. Claude Code loads this file automatically and does not load `AGENTS.md` on its own,
which is the only reason this file exists.

Claude-Code-specific mechanics, which are the rest of what it is for:

- The response style is enforced by the `caveman-full` output style in
  [`.claude/output-styles/caveman-full.md`](.claude/output-styles/caveman-full.md), selected in
  [`.claude/settings.json`](.claude/settings.json). That puts the rule in the system prompt rather
  than in a per-turn reminder, so a long run of tool calls cannot bury it. `/caveman lite|full|ultra`
  switches intensity; default here is **full**.
- You authenticate as your own GitHub App, `trey-agent-claude[bot]`, whose private key is
  `.agents/secrets/github_app_key.claude.pem` and whose app id is in `.agents/apps.conf`. Commits and
  PRs are authored by that bot, not by a human. Never read or fall back to another agent's credential,
  and never use the SSH `origin` remote.
- Work in `.agents/worktrees/claude/<task-slug>`, created by
  `.agents/bin/git-agent.sh worktree <task-slug>`. Never edit tracked files in the root checkout.
