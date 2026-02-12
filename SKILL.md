---
name: orchestrator
description: "Install and operate the OpenClaw goals orchestrator (state files + cron jobs). Provides status and one-shot runs."
---

# Orchestrator Skill

This skill manages the self-driving goal orchestrator that lives under:

- `workspace/goals/`

Commands provided by this skill:

- `orchestrator.status` — show current goals + schedules overview
- `orchestrator.install` — create/repair required folders + baseline files under `workspace/goals/` **and** create/repair the required cron jobs:
  - `orchestrator:main` (hourly)
  - `orchestrator:digest` (09:00 and 21:00 Asia/Singapore)
- `orchestrator.run_once` — trigger `orchestrator:main` immediately (via `openclaw cron run` when available; otherwise falls back to a local lightweight cycle that updates `goals/state.json` + regenerates `goals/index.md`)
- `orchestrator.validate` — validate orchestrator health (checks `state.json` structure + file writability)
- `orchestrator.validate_health` — alias for `orchestrator.validate` (for backwards/goal compatibility)

## Notes

- Scheduled orchestrator runs (cron-triggered) must not shell out to `openclaw ...` from inside the agent run (can deadlock). Use OpenClaw tools.
- This skill is intended for **interactive repair**: it uses the OpenClaw CLI to manage cron jobs. If the Gateway is unreachable, `orchestrator.install` will fall back to patching `~/.openclaw/cron/jobs.json` locally.
