#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"

WS="/home/theengineer/.openclaw/workspace"
GOALS_DIR="$WS/goals"
STATE="$GOALS_DIR/state.json"
INDEX="$GOALS_DIR/index.md"
EVENTS="$GOALS_DIR/events.ndjson"

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

ensure_base_files() {
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
    sed -i "s/__REPLACED__/$(now_iso)/" "$STATE"
  fi

  [ -f "$EVENTS" ] || : > "$EVENTS"

  [ -f "$GOALS_DIR/inbox.md" ] || cat > "$GOALS_DIR/inbox.md" <<'MD'
# Goals Inbox

Add goals by writing text that contains [GOAL].
Optional explicit id: [GOAL:ID]

(Add real goals below.)
MD

  [ -f "$INDEX" ] || : > "$INDEX"
}

case "$ACTION" in
  orchestrator.status)
    echo "== goals/index.md =="
    if [ -f "$INDEX" ]; then
      sed -n '1,240p' "$INDEX"
    else
      echo "missing: $INDEX"
    fi
    echo
    echo "== state.json (high level) =="
    python3 - <<'PY'
import json
from pathlib import Path
p=Path('/home/theengineer/.openclaw/workspace/goals/state.json')
try:
  j=json.loads(p.read_text())
except Exception as e:
  print(f"state.json unreadable: {e}")
  raise SystemExit(2)
print(f"version: {j.get('version')}")
print(f"last_orchestrator_run_at: {j.get('last_orchestrator_run_at')}")
print(f"goals: {len(j.get('goals',{}) or {})}")
print(f"runs: {len(j.get('runs',{}) or {})}")
PY
    echo
    echo "== cron jobs (names only; best-effort, interactive only) =="
    # This is for interactive/manual runs only; scheduled runs must not call openclaw.
    if timeout 3s openclaw cron list --json 2>/dev/null | python3 - <<'PY'
import json,sys
try:
  j=json.load(sys.stdin)
except Exception:
  # swallow parse errors (e.g., timeout/no output)
  raise SystemExit(1)
for job in j.get('jobs',[]) or []:
  name=job.get('name')
  enabled=job.get('enabled')
  print(f"- {name} ({'enabled' if enabled else 'disabled'})")
PY
    then
      :
    else
      echo '(cron list unavailable)'
    fi
    ;;

  orchestrator.install)
    ensure_base_files
    echo "OK"
    ;;

  orchestrator.run_once)
    ensure_base_files
    python3 - <<'PY'
import json
from datetime import datetime, timezone
from pathlib import Path

WS=Path('/home/theengineer/.openclaw/workspace')
goals_dir=WS/'goals'
state_path=goals_dir/'state.json'
index_path=goals_dir/'index.md'
events_path=goals_dir/'events.ndjson'

def now_iso():
  return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00:00','Z')

j=json.loads(state_path.read_text())
ran_at=now_iso()

# Update high-level run markers
j['last_orchestrator_run_at']=ran_at
runs=j.setdefault('runs',{})
runs[ran_at]={
  'ran_at': ran_at,
  'harvested': 0,
  'new_goals': [],
  'updated_goals': [],
  'notes': ['run_once_via_skill']
}

# Render a simple index.md summary (this is intentionally lightweight; full parity is tracked under a separate goal)
goals=j.get('goals',{}) or {}
active=[]
archived=[]
for gid,g in goals.items():
  st=(g or {}).get('status')
  if st=='archived':
    archived.append((gid,g))
  else:
    active.append((gid,g))

def fmt_goal(gid,g):
  g=g or {}
  title=g.get('title') or g.get('text','').splitlines()[0][:120]
  next_run=g.get('next_run_at')
  run_state=g.get('run_state')
  return f"- **{gid}** — {title}  (next_run_at: {next_run}, run_state: {run_state}, status: {g.get('status')})"

lines=[]
lines.append('# Goals')
lines.append('')
lines.append(f"Last orchestrator run: `{ran_at}`")
lines.append('')
lines.append('## Active')
lines.append('')
if active:
  for gid,g in sorted(active, key=lambda x: x[0]):
    lines.append(fmt_goal(gid,g))
else:
  lines.append('- (none)')
lines.append('')
lines.append('## Archived')
lines.append('')
if archived:
  for gid,g in sorted(archived, key=lambda x: x[0]):
    lines.append(f"- {gid}")
else:
  lines.append('- (none)')
lines.append('')

index_path.write_text('\n'.join(lines)+"\n")

# Atomic-ish state write (write temp then replace)
tmp=state_path.with_suffix('.json.tmp')
tmp.write_text(json.dumps(j,indent=2,sort_keys=False)+"\n")
tmp.replace(state_path)

# Append an event marker
with events_path.open('a',encoding='utf-8') as f:
  f.write(json.dumps({
    'ts': ran_at,
    'kind': 'orchestrator.run_once',
    'note': 'Triggered via skills/orchestrator-skill/run.sh orchestrator.run_once'
  })+'\n')

print('OK')
PY
    ;;

  orchestrator.validate|orchestrator.validate_health)
    ensure_base_files
    python3 - <<'PY'
import json
from pathlib import Path

WS=Path('/home/theengineer/.openclaw/workspace')
goals_dir=WS/'goals'
state_path=goals_dir/'state.json'
events_path=goals_dir/'events.ndjson'
index_path=goals_dir/'index.md'

problems=[]

# state.json
try:
  j=json.loads(state_path.read_text())
except Exception as e:
  problems.append(f"state.json unreadable: {e}")
  j=None

if j is not None:
  for k in ['version','created_at','goals','runs']:
    if k not in j:
      problems.append(f"state.json missing key: {k}")

# events.ndjson
try:
  events_path.open('a').close()
except Exception as e:
  problems.append(f"events.ndjson not writable: {e}")

# index.md
try:
  index_path.open('a').close()
except Exception as e:
  problems.append(f"index.md not writable: {e}")

if problems:
  print('NOT_OK')
  for p in problems:
    print(f"- {p}")
  raise SystemExit(2)

print('OK')
PY
    ;;

  *)
    echo "Usage: $0 <action>"
    echo "Actions: orchestrator.status | orchestrator.install | orchestrator.run_once | orchestrator.validate | orchestrator.validate_health"
    exit 1
    ;;
esac
