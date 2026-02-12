#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"

WS="/home/theengineer/.openclaw/workspace"
GOALS_DIR="$WS/goals"
STATE="$GOALS_DIR/state.json"
INDEX="$GOALS_DIR/index.md"

case "$ACTION" in
  orchestrator.status)
    echo "== goals/index.md =="
    if [ -f "$INDEX" ]; then
      sed -n '1,200p' "$INDEX"
    else
      echo "missing: $INDEX"
    fi
    echo
    echo "== cron jobs (names only) =="
    # This is for interactive/manual runs only; scheduled runs must not call openclaw.
    openclaw cron list --json 2>/dev/null | python3 - <<'PY'
import json,sys
try:
  j=json.load(sys.stdin)
except Exception:
  print('(cron list unavailable)')
  raise SystemExit(0)
for job in j.get('jobs',[]):
  print(f"- {job.get('name')} ({'enabled' if job.get('enabled') else 'disabled'})")
PY
    ;;

  orchestrator.install)
    mkdir -p "$GOALS_DIR" "$GOALS_DIR/proof" "$GOALS_DIR/locks"
    if [ ! -f "$STATE" ]; then
      cat > "$STATE" <<'JSON'
{
  "version": 1,
  "created_at": "__REPLACED__",
  "last_orchestrator_run_at": null,
  "last_digest_at": null,
  "goals": {},
  "runs": {}
}
JSON
      sed -i "s/__REPLACED__/$(date -u +%Y-%m-%dT%H:%M:%SZ)/" "$STATE"
    fi
    [ -f "$GOALS_DIR/events.ndjson" ] || : > "$GOALS_DIR/events.ndjson"
    [ -f "$GOALS_DIR/inbox.md" ] || cat > "$GOALS_DIR/inbox.md" <<'MD'
# Goals Inbox

Add goals by writing text that contains [GOAL].
Optional explicit id: [GOAL:ID]

(Add real goals below.)
MD
    [ -f "$INDEX" ] || : > "$INDEX"
    echo "OK"
    ;;

  orchestrator.run_once)
    echo "Not implemented yet (will be upgraded to call the orchestrator logic via OpenClaw tools)."
    exit 2
    ;;

  *)
    echo "Usage: $0 <action>"
    echo "Actions: orchestrator.status | orchestrator.install | orchestrator.run_once"
    exit 1
    ;;
esac
