---
name: orchestrator
description: "Install and operate the OpenClaw goals orchestrator (state files + cron jobs). Provides status and one-shot runs."
---

# Orchestrator Skill

This skill manages the self-driving goal orchestrator that lives under:

- `workspace/goals/`

Commands provided by this skill:

- `orchestrator.status` — show current goals + schedules overview
- `orchestrator.install` — create/repair required folders + baseline files under `workspace/goals/`
- `orchestrator.run_once` — run a lightweight, single reconciliation cycle now (updates `goals/state.json` + regenerates `goals/index.md`)
- `orchestrator.validate` — validate orchestrator health (checks `state.json` structure + file writability)
- `orchestrator.validate_health` — alias for `orchestrator.validate` (for backwards/goal compatibility)

## Notes

- Scheduling is done **only** via OpenClaw cron.
- Do not shell out to `openclaw ...` from inside scheduled runs (can deadlock). Use OpenClaw tools.
