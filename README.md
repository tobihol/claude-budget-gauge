# claude-budget-gauge

**The gauge your orchestrator reads before it spends.**

A Claude Code skill for autonomous and multi-agent runs. `gauge.sh` reports
your subscription usage (5-hour session window and weekly cap) as one JSON
line; `SKILL.md` tells the agent how to act on it — forwarding budgets to
subagents, reserving headroom, calibrating %-per-call, and choosing between
"pause until reset" and "stop".

```console
$ gauge.sh
{"status":"ok","fetched_at":"2026-08-05T10:36:03Z","five_hour_pct":67.0,
 "five_hour_resets_at":"2026-08-05T12:10:00+00:00","seven_day_pct":29.0,
 "seven_day_resets_at":"2026-08-09T05:59:59+00:00","warnings":[]}
```

## Why

Human-facing usage monitors already exist: `/usage`, the statusline's
`rate_limits` input, [ccusage](https://github.com/ccusage/ccusage) and
[others](docs/prior-art.md). Use those if you just want a number on screen.

This is for an **agent** deciding whether it can afford the next batch. The
usage window is shared by every session, subagent and machine on the
subscription, so per-session token counting can't answer that question.

## Install

| As | How |
|---|---|
| Plugin (recommended, gets updates) | `/plugin marketplace add tobihol/claude-budget-gauge`<br>`/plugin install budget-gauge@claude-budget-gauge` |
| Manual skill | Copy `skills/budget-gauge/` into `~/.claude/skills/` or `<project>/.claude/skills/` |
| Bare script (containers, CI) | Vendor [`gauge.sh`](skills/budget-gauge/gauge.sh): POSIX `sh`, needs `jq`, `curl` and a Claude Code login |

## Output

One JSON line on stdout, always exit 0. Readings are cached for 3 minutes.

| Field | Meaning |
|---|---|
| `status` | `"ok"` or `"unknown"` |
| `five_hour_pct` / `seven_day_pct` | Utilization (0–100) of the 5-hour session window / weekly cap |
| `five_hour_resets_at` / `seven_day_resets_at` | When each window rolls over |
| `warnings` | Limits close to their cap, incl. per-model weekly caps; `[]` if none |
| `fetched_at` | UTC time of the reading |
| `reason` | Why the state is `unknown` |

- **`unknown` never means "unchanged".** The state is unavailable; don't
  launch new paid batches on it.
- **`five_hour_pct: null`** means the plan has no session window (verified
  Ultra accounts). The weekly cap is then the binding limit.

[`SKILL.md`](skills/budget-gauge/SKILL.md) is the full contract and policy.

## Caveats

- **Undocumented endpoint.** The gauge reads `api.anthropic.com/api/oauth/usage`,
  the internal endpoint behind `/usage`. If it changes, the gauge reports
  `unknown` rather than guessing.
- **One code path spends money.** If the stored OAuth token has expired
  (common in containers/CI using `CLAUDE_CODE_OAUTH_TOKEN`), the gauge makes
  one minimal Haiku call (~6 output tokens) so the CLI refreshes its login.
- **Credentials.** The token is read at call time, passed to curl via stdin
  (never argv), and never written anywhere. The output contains no secrets.

## Development

```console
$ tests/smoke.sh          # every branch, sandboxed; your login is never used
$ tests/smoke.sh --live   # plus one real reading
```

| Path | Contents |
|---|---|
| `skills/budget-gauge/` | `SKILL.md` (policy, contract) and `gauge.sh` (instrument) |
| `.claude-plugin/` | Plugin and marketplace metadata |
| `examples/` | Worked orchestrator integration, incl. container wiring |
| `tests/` | Smoke tests |
| `docs/prior-art.md` | Survey of existing usage tools |

## License

MIT © 2026 Tobias Holtdirk
