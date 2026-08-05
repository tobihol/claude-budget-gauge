---
name: budget-gauge
description: >
  Subscription-window budget governance for autonomous and multi-agent runs:
  gauge.sh reports the operator's Claude subscription utilization (5-hour
  session window and weekly cap, in %, with reset times and per-model
  scoped-limit warnings) as one machine-readable JSON line, plus the policy
  for acting on it. Use when deciding whether a run can afford the next batch,
  before launching subagents or large batches of subscription-billed calls,
  when forwarding a budget into subagent prompts, when calibrating
  %-per-call, or when an operator sets a spend limit. Works headless on any
  machine with a Claude Code login.
---

# budget-gauge — subscription budget: policy and instrument

Two halves. The **policy** half is written to the orchestrator — the agent that
owns the budget and launches work. The **instrument** half (`gauge.sh`, next to
this file) serves every agent that spends the window.

## Budget (policy)

**Default: unrestricted.** Unless the operator explicitly sets a budget, do not
impose or invent one — runs spend what they need. Consumption is still
*measured* by default (gauge readings below), just never *capped* on your own
initiative.

**The gauge.** Run the `gauge.sh` that sits next to this SKILL.md. It reads the
subscription window state headlessly, no setup needed:

```json
{"status":"ok","five_hour_pct":11.0,"five_hour_resets_at":"…","seven_day_pct":56.0,
 "warnings":[{"kind":"weekly_scoped","percent":85,"severity":"warning","model":"…"}]}
```

Responses are cached for 3 minutes, so anyone may call it freely.
`"status":"unknown"` means the state is unavailable — never "unchanged". The
reading is **account-wide, not run-wide**: every session on the subscription
(the operator's other terminals, other machines, other agents) draws the same
window, so a jump the run didn't cause is possible and still counts against any
ceiling — ceilings gate on the reading, whatever produced it.

Read it at run start, before and after each subagent or batch, and at every
budget-relevant decision point; log the readings so each phase's real cost is
visible whether or not a budget is set. A `warnings` entry on a model an agent
runs on (a scoped weekly cap) is worth surfacing to the operator even with no
budget set.

**Setting a budget (operator-only).** A budget exists only when the operator
states one. Record it verbatim plus a machine-checkable form — including the
gauge baseline at authorization time. Typical forms:

- **window share** — "this run may consume 50 points of the 5h window":
  spent = current_pct − baseline_pct; if `resets_at` moved, the window rolled
  over — re-baseline and count spend across windows;
- **gauge ceiling** — "never push the 5h gauge above 80%";
- **metered dollars** (API-key billing) — a $ cap, tracked from per-call
  `usage` blocks at list prices; the gauge does not apply there;
- **call caps** — at most N calls per model tier.

If the semantics are ambiguous (per-window vs. total, whether the reserve
counts, …), that is an operator question, not a guess.

**Enforcing and forwarding.** The orchestrator owns the budget; subagents
execute it:

- Every subagent prompt states either the budget or explicitly "no budget
  restrictions" — plus the gauge command and the rules: check the gauge every
  few batches, stop and report when the budget is spent, and on `unknown`
  launch no new paid batches — finish the current one, then report.
- When a budget is set, **reserve headroom**: the agents' own reasoning tokens
  spend the same window, so hold back an explicit reserve (default: 10 points
  of the authorized share) for scoring, summarizing, and reporting after the
  paid work stops.
- **Calibrate before committing.** Utilization is a percentage; convert it to
  a budget by differencing two readings around a known small workload to
  measure %-per-call, then size the large batch from that.
- On exhaustion, `resets_at` distinguishes "pause until the window rolls over
  and continue under a fresh authorization" from "stop" — that decision is the
  operator's.
- Budgets move in one direction without the operator: you may stop earlier,
  never authorize more.

## The gauge (instrument)

On subscription billing (Pro/Max), agents and their subagents all draw from the
operator's **5-hour session window** plus weekly caps. `gauge.sh` reads that
gauge; the policy above says how much of the window a run may spend.

### Usage

```bash
<path-to-this-skill>/gauge.sh
```

One compact JSON line on stdout, always exit 0:

```json
{"status":"ok","fetched_at":"2026-07-15T18:37:55Z",
 "five_hour_pct":11.0,"five_hour_resets_at":"2026-07-15T22:49:59+00:00",
 "seven_day_pct":56.0,"seven_day_resets_at":"2026-07-19T05:59:59+00:00",
 "warnings":[{"kind":"weekly_scoped","percent":85,"severity":"warning","model":"Opus"}]}
```

or `{"status":"unknown","reason":"…"}` when the gauge cannot be read.

- `five_hour_pct` / `seven_day_pct` — utilization in percent (0–100) of the
  session window and the weekly cap; `*_resets_at` — when each window rolls
  over.
- `warnings` — any limit the account is close to, including **per-model scoped
  weekly caps** (e.g. the model the orchestrator or an agent runs on); empty
  when all limits are `normal`.
- Results are cached for 3 minutes and served from cache within that window —
  call it as often as you like, the endpoint is hit at most once per
  3 minutes. `fetched_at` tells you how old the reading is.

This JSON schema is the public contract — downstream agents parse it. Fields
may be added; existing fields and the `ok`/`unknown` discipline don't change
without a major version bump.

### Rules of interpretation

1. **`unknown` never means "unchanged".** Treat it as "budget state
   unavailable": don't launch new paid batches on an unknown gauge — finish
   what is running, then use the fallbacks below or ask the operator.
2. The gauge is **account-global**: anything else the operator does on this
   account moves it too. That is correct behavior — it measures the real
   remaining window.
3. A `warning` entry on the model an *agent* runs on (not just the batch
   workload) is worth stopping for: the loop's own reasoning spends that
   scoped cap.
4. Utilization is a percentage; calibrate %-per-call around a known workload
   before committing to larger batches (see policy above).

### How it works, and its fragilities

`gauge.sh` queries Claude Code's own usage endpoint
(`api.anthropic.com/api/oauth/usage`) with the operator's stored Claude Code
login — the credentials file on Linux/WSL, the keychain on macOS. Two
fragilities, both handled:

- **The endpoint is internal and undocumented** (the same one `/usage` uses;
  community tools rely on it too). If Anthropic changes it, `gauge.sh` reports
  `unknown: unexpected response schema` rather than guessing.
- **The stored access token lives ~8 hours.** The CLI refreshes it
  automatically, but only when a call actually *uses* the stored login. In an
  env-token session (`CLAUDE_CODE_OAUTH_TOKEN` set — containers, CI) every
  call authenticates via the env token instead, so the stored token goes
  stale — and the usage endpoint accepts **only** the stored login's access
  token (the long-lived setup-token gets `permission_error`). On an expired
  token `gauge.sh` **self-heals**: it triggers one minimal Haiku call through
  the stored login (~6 output tokens, real subscription-billed spend), which
  makes the CLI refresh the credential, then re-reads it. The script never
  writes the credential store. If the token is still expired afterwards (e.g.
  the refresh token — ~1-month lifetime — lapsed too), it reports
  `unknown: stored OAuth access token expired…`; the remedy is a login in
  that environment (container: `docker exec -it <container> claude auth
  login`).

### Fallbacks when the gauge stays `unknown`, in order

1. `claude -p "/usage"` — prints the same numbers as localized human text
   (slow: full CLI startup per reading; parse the percentages defensively,
   and don't call it in a tight loop — it has no rate-limit cache). Claude
   Code parses the endpoint itself here, so this survives endpoint schema
   changes.
2. A statusline command that tees the documented `rate_limits` stdin object
   to a file (needs a live interactive session to refresh it).
3. **Host-refreshed gauge file** — for a *credential-less* environment, where
   the self-heal cannot apply because there is no stored login to refresh (a
   container authenticated purely by `CLAUDE_CODE_OAUTH_TOKEN`, never logged
   into interactively). A process **outside** that environment — the
   operator's host session — runs `gauge.sh` on a fixed cadence (~3 min) and
   writes the JSON to a path the agent can read (atomic replace: write
   `.tmp`, then `mv`). The agent reads that file wherever it would read the
   gauge, and **treats a `fetched_at` older than ~10 minutes as `unknown`** —
   a stale file is a dead feed, not a steady reading. Prefer fixing the
   cause where possible: an interactive login inside the container makes
   `gauge.sh` work natively there. A worked version of this wiring is in the
   repo's `examples/`.
4. Manual anchoring: the operator reads `/usage` and reports the % at run
   start and at decision points; token metering interpolates between anchors.

### Credential hygiene (binding)

The OAuth token is read at call time, held only in the script's memory, passed
to curl via stdin config (never argv, which `ps` can see), and never written to
disk, logs, or child-process environments. The expiry self-heal keeps this
invariant: the script never writes the credential store — the refresh is
performed by the CLI's own login code, and the script only re-reads the result.
Never modify `gauge.sh` to print, export, or store the token; never paste gauge
internals plus token into a prompt. The JSON output contains no secrets and is
safe to log.
