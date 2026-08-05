# Example: wiring the gauge into a long-running orchestrator

**This is one way to integrate the gauge, not the contract.** The setting: an
orchestrator agent runs a multi-day loop that launches batches of
subscription-billed subagent calls, keeps a structured run log, and pauses at
decision points where a human operator authorizes spend. The generic rules
live in `skills/budget-gauge/SKILL.md`; nothing below adds to that contract.

## What the orchestrator does with the gauge

- **Reads at fixed points.** Run start, before/after each subagent or batch,
  and at every budget-relevant decision point. Each reading is logged as a
  structured `gauge_reading` event in the run log, so every iteration's real
  window cost is visible whether or not a budget is set.
- **Records budgets at authorization time.** A budget exists only when the
  operator states one. It is recorded verbatim plus a machine-checkable
  form — including the gauge baseline at authorization time — in the loop's
  state file and in the log event for that decision. Typical forms are the
  ones in SKILL.md: window share, gauge ceiling, metered dollars, per-tier
  call caps.
- **Forwards the budget into every subagent prompt.** Each prompt states the
  budget (or explicitly "no budget restrictions"), the gauge command, and the
  rules: check the gauge every few batches, stop and report when the budget
  is spent, and on `unknown` launch no new paid batches — finish the current
  one, then report.
- **Calibrates before committing.** Before a large batch, the orchestrator
  runs a small pilot batch and differences two gauge readings around it to
  measure %-per-call, then sizes the real batch from that.
- **Reserves headroom.** When a budget is set, 10 points of the authorized
  share are held back for scoring, archiving, and reporting after the paid
  work stops — the agents' own reasoning spends the same window.
- **Escalates instead of deciding.** On exhaustion, `resets_at` distinguishes
  "pause until the window rolls over" from "stop"; either way the choice is
  surfaced to the operator, never decided by the loop.

## The container wiring (host-refreshed gauge file)

One session of this setup runs inside a container authenticated purely by
`CLAUDE_CODE_OAUTH_TOKEN` — no stored login inside, so `gauge.sh`'s self-heal
has nothing to refresh. The fallback:

- The **host** session runs `gauge.sh` every ~3 minutes and writes the JSON to
  a bind-mounted path the container can read, atomically: write a `.tmp`
  file, then `mv` over the target.

  ```sh
  while :; do
    /path/to/gauge.sh > /shared/host_gauge.json.tmp \
      && mv /shared/host_gauge.json.tmp /shared/host_gauge.json
    sleep 180
  done
  ```

- The **container** agent reads that file wherever the loop calls for a gauge
  reading, and treats a `fetched_at` older than ~10 minutes as `unknown` — a
  stale file is a dead feed, not a steady reading.
- Each `gauge_reading` event logs the source (`direct` vs `host_file`) so the
  run log distinguishes the two.

Where possible, prefer fixing the cause instead: one interactive
`claude auth login` inside the container gives it a stored login, and
`gauge.sh` then works natively there, self-heal included.
