# Prior art — Claude Code usage/quota tooling

Landscape survey done 2026-08-04 (web search, public repos only). Purpose:
establish what already exists, so this project's README can position
honestly and link competitors generously.

## Summary

The **reader** niche is crowded: many tools query the same undocumented
endpoint or read the statusline `rate_limits` payload, and render it for a
human. The **agent-facing budget governance** niche appears unoccupied.

## Native Claude Code features (the strongest "competitor")

- **`/usage`** — built-in command, prints 5h / 7d utilization as localized
  human text.
- **statusline stdin `rate_limits`** — since Claude Code 2.1.x the statusline
  command receives `rate_limits.five_hour` / `.seven_day` on stdin, with
  **zero API calls**. Anything that only needs a number on screen for a
  human should use this, not an HTTP request.

Implication: never pitch this project as a way to *see* your usage.

## Community tools

| Project | Form | Notes |
|---|---|---|
| [ccusage](https://github.com/ccusage/ccusage) | npm CLI (`npx ccusage`) | The most polished. Parses local JSONL transcripts for cost, tracks active 5-hour blocks, statusline integration. |
| [Claude-Code-Usage-Monitor](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor) | Python TUI | Real-time monitor with predictions and warnings. |
| [claude-code-statusline](https://github.com/ohugonnot/claude-code-statusline) | statusline | Reads `rate_limits` from stdin, zero API calls; quota, reset countdown, context window, model, git branch. |
| [cc-usage-monitor](https://github.com/harveyxiacn/cc-usage-monitor) | plugin | 5h/7d in the statusline and after every task, plus a slash command. |
| [claude-pulse](https://github.com/NoobyGains/claude-pulse) | monitor | Session + weekly limits, plan tier, colour-coded bars. |
| [Usage4Claude](https://github.com/f-is-h/usage4claude) | macOS menu bar | 5h, 7d, extra usage, per-model (Opus/Sonnet) weekly quotas. |
| [claude-usage-monitor](https://github.com/aiedwardyi/claude-usage-monitor) | statusline plugin | 5h/7d quota, context usage, tokens, reset countdowns. |
| [claude-usage-widget](https://github.com/bozdemir/claude-usage-widget) | desktop widget + CLI | Cross-platform, forecasts, burn alerts, themes; also covers Codex. |

Write-ups worth reading before finalizing the README:

- [Tracking Claude, Codex, and Gemini quotas from one script](https://ianlpaterson.com/blog/tracking-claude-codex-gemini-quotas-from-one-script/)
- [Building a custom Claude Code statusline](https://therolle.com/posts/2026/building-claude-code-statusline/)
- [Statusline: usage limits, pacing targets, context window (gist)](https://gist.github.com/jtbr/4f99671d1cee06b44106456958caba8b)

## The endpoint

`https://api.anthropic.com/api/oauth/usage` — **undocumented**, discovered by
the community, the same one `/usage` uses. Requires the
`anthropic-beta: oauth-2025-04-20` header (401 without it) and the stored
login's short-lived access token. Returns `five_hour` / `seven_day`
utilization plus reset timestamps and per-model scoped limits.

Community convention (which this project follows): read
`~/.claude/.credentials.json` → `claudeAiOauth.accessToken`, cache the
response for a few minutes.

Official, documented alternatives — **neither covers subscription window
utilization**, so they are not substitutes:

- [Claude Code Analytics API](https://platform.claude.com/docs/en/build-with-claude/claude-code-analytics-api)
- [Usage and Cost API](https://platform.claude.com/docs/en/manage-claude/usage-cost-api)

## Adjacent: agent spend control

Claude Code ships subagent fan-out limits — concurrency (default 20),
per-session total (default 200), spawn depth (default 3) — which cap *how
many* agents run, not *how much subscription window* they consume. See
[Claude Code put guardrails on its own agent fleets](https://www.digitalapplied.com/blog/claude-code-subagent-depth-limits-budget-caps-2026).

Nothing found that lets an orchestrator read remaining quota and gate its
own spending on it. That gap is this project.

## Known pain point this project addresses

Under `CLAUDE_CODE_OAUTH_TOKEN` (containers, CI, long-running headless
processes) the stored access token (~8h TTL) is never refreshed, producing
`401 OAuth access token has expired`. Related:
[anthropics/claude-code#80091](https://github.com/anthropics/claude-code/issues/80091).
No published workaround was found; `gauge.sh`'s self-heal is, as far as this
survey goes, novel.

## Limits of this survey

Web search over public repos and blogs on one day. It cannot prove a
negative — someone may have equivalent work in a private repo or behind a
name that didn't surface. State novelty claims as "no public equivalent
found", never as "the first".
