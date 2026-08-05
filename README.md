# claude-budget-gauge

**The gauge your orchestrator reads before it spends.** Budget governance for
autonomous and multi-agent Claude Code runs: the operator's subscription
window utilization (5-hour session + weekly cap) as one machine-readable JSON
line, packaged as a Claude Code skill together with the policy an agent needs
to *act* on it — forwarding budgets to subagents, reserving headroom,
calibrating %-per-call, deciding between "pause until the window resets" and
"stop".

```console
$ gauge.sh
{"status":"ok","fetched_at":"2026-08-05T10:36:03Z","five_hour_pct":67.0,
 "five_hour_resets_at":"2026-08-05T12:10:00+00:00","seven_day_pct":29.0,
 "seven_day_resets_at":"2026-08-09T05:59:59+00:00","warnings":[]}
```

## Two things you should know before using it

- **The endpoint is undocumented.** The gauge reads
  `api.anthropic.com/api/oauth/usage` — the same internal endpoint Claude
  Code's own `/usage` uses, discovered by the community, not an official API.
  It may change or disappear without notice. The mitigation is built into the
  contract: the gauge reports `{"status":"unknown"}` with a reason instead of
  ever guessing.
- **One code path spends real money.** If your stored OAuth token has expired
  (typical in containers/CI running under `CLAUDE_CODE_OAUTH_TOKEN`), the
  gauge self-heals by making **one minimal, subscription-billed Haiku call**
  (~6 output tokens) through the stored login so the CLI refreshes its own
  credential. One attempt, no retry, never on a fresh token — but it is real
  spend and you should know it exists.

## What this is not

Not a usage monitor for humans — that niche is well served. Claude Code has
`/usage` built in, and since 2.1.x it hands your statusline a `rate_limits`
object on stdin with **zero API calls**; [ccusage](https://github.com/ccusage/ccusage),
[Claude-Code-Usage-Monitor](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor),
and [friends](docs/prior-art.md) cover the pretty-display case better than
this ever will. If you just want a number on screen, use those.

This is for the case none of them cover: an **agent** that has to decide
whether it can afford the next batch. Per-session token counting can't answer
that — the 5h/7d window is shared across every session, subagent, and machine
on the subscription — and nothing injects window state into the model's
context. The gauge is the missing instrument, and the skill is the missing
policy. See [docs/prior-art.md](docs/prior-art.md) for the full landscape
survey behind these claims.

## Install

**As a plugin (recommended — gets updates):**

```
/plugin marketplace add tobihol/claude-budget-gauge
/plugin install budget-gauge@claude-budget-gauge
```

**As a manual skill (works, never updates):** copy `skills/budget-gauge/`
into `~/.claude/skills/` (personal) or `<project>/.claude/skills/` (project).

**As a bare script (containers, CI, non-Claude-Code orchestrators):** vendor
[`skills/budget-gauge/gauge.sh`](skills/budget-gauge/gauge.sh) — it is
self-contained POSIX `sh` and needs only `jq`, `curl`, and a Claude Code
login on the machine. `gauge.sh --help` summarizes the contract.

## The contract

One compact JSON line on stdout, **always exit 0**:

| Field | Meaning |
|---|---|
| `status` | `"ok"` or `"unknown"` — nothing else |
| `fetched_at` | UTC timestamp of the reading (readings are cached ≤3 min) |
| `five_hour_pct` / `seven_day_pct` | utilization in percent (0–100) of the 5-hour session window / weekly cap |
| `five_hour_resets_at` / `seven_day_resets_at` | when each window rolls over |
| `warnings` | limits the account is close to, incl. per-model scoped weekly caps; `[]` when all normal |
| `reason` | (`unknown` only) human-readable cause |

The binding interpretation rule: **`unknown` never means "unchanged"** — it
means the budget state is unavailable, and an orchestrator must not launch new
paid batches on it. [`skills/budget-gauge/SKILL.md`](skills/budget-gauge/SKILL.md)
is the full contract: interpretation rules, budget forms, forwarding and
enforcement policy, fallbacks, credential hygiene.

Credential hygiene, briefly: the token is read at call time from the stored
login (credentials file or macOS keychain), passed to curl via stdin config —
never argv, so it never appears in `ps` — and never written anywhere. The
script never writes the credential store. The JSON output contains no secrets.

## Testing

```console
$ tests/smoke.sh          # --help + every unknown branch, sandboxed —
                          # your real login is never read or sent
$ tests/smoke.sh --live   # additionally one real reading
```

## Repo layout

| Path | What it is |
|---|---|
| `skills/budget-gauge/` | The product: `SKILL.md` (policy + contract) and `gauge.sh` (instrument) |
| `.claude-plugin/` | Plugin + marketplace metadata (this repo is its own marketplace) |
| `examples/` | A worked orchestrator integration, incl. the container/host-refreshed-file wiring — one way to wire it, not the contract |
| `tests/smoke.sh` | Smoke test; exercises each failure branch without touching your login |
| `docs/prior-art.md` | Landscape survey: what already exists, why this is positioned as agent-facing |

## License

MIT © 2026 Tobias Holtdirk
