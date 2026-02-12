---
name: orchestrator
description: "Install and operate the OpenClaw goals orchestrator (state files + cron jobs). Provides status and one-shot runs."
---

# Orchestrator Skill

This skill manages the self-driving goal orchestrator that lives under:

- `workspace/goals/`

Commands provided by this skill:

- `orchestrator.status` — show current goals + schedules overview
- `orchestrator.install` — create/repair folders + cron jobs
- `orchestrator.run_once` — run a single orchestrator reconciliation cycle now (no schedule changes outside OpenClaw)

## Notes

- Scheduling is done **only** via OpenClaw cron.
- Do not shell out to `openclaw ...` from inside scheduled runs (can deadlock). Use OpenClaw tools.
