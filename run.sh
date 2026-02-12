#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"

WS="/home/theengineer/.openclaw/workspace"
GOALS_DIR="$WS/goals"
STATE="$GOALS_DIR/state.json"
INDEX="$GOALS_DIR/index.md"
EVENTS="$GOALS_DIR/events.ndjson"

OPENCLAW_STATE_DIR="/home/theengineer/.openclaw"
CRON_JOBS_JSON="$OPENCLAW_STATE_DIR/cron/jobs.json"

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

orchestrator_main_message() {
  cat <<'MSG'
You are the OpenClaw Orchestrator (hourly).

Hard rules:
- Use ONLY OpenClaw tools.
- State: /home/theengineer/.openclaw/workspace/goals
- Do not send Telegram messages except: (a) goal completion with proof, (b) critical failure loop alert.
- Single-flight per goal_id via goals/locks.
- Ensure exactly one child schedule exists per goal_id; name must be goal:<goal_id>.

ANTI-DEADLOCK POLICY (mandatory):
- NEVER run any `openclaw ...` CLI command via exec from inside a cron-triggered agent run (including `openclaw cron`, `openclaw status`, `openclaw logs`, etc.). This can self-deadlock.
- Use the corresponding OpenClaw tools instead (cron tool for schedules; file tools for state; message tool for messaging).

On each run:
1) Load goals/state.json.
2) Harvest goals from goals/inbox.md (blocks containing [GOAL] case-insensitive; prefer explicit [GOAL:ID]).
   Telegram harvesting: skip unless there is an OpenClaw tool that can list messages.
3) Child schedule enforcement:
   - Call cron.list (tool) to get jobs.
   - For each active goal:
     - desired name: goal:<goal_id>
     - If exists, store id in goal record (child_job_id) and patch schedule/payload via cron.update.
     - If missing, create via cron.add and store returned id.
     - If duplicates, keep newest enabled, disable others, send critical alert.
     - Safety: next run must be >= now + timeoutSeconds + 120s.
4) Worker prompt generation: include goal_id, provenance, DoD, verify_steps, last_action, last_error, retry/backoff, sessionKey.
5) Verification: for done_pending_verify, execute verify_steps with tools; store proof; if verified done: cron.remove child job + send completion message.
6) Backoff: 10m, 30m, 1h, 2h, 4h, 8h (cap 8h). Same error >=5 => blocked.
7) Persist state.json atomically + append events.ndjson + update goals/index.md.
MSG
}

digest_message() {
  cat <<'MSG'
You are the OpenClaw Digest Reporter.

Rules:
- Send Telegram digest ONLY now (this scheduled run). No greeting, no signature.
- Use ONLY OpenClaw tools.
- NEVER run any `openclaw ...` CLI command via exec from inside this cron-triggered run.
- Read state from /home/theengineer/.openclaw/workspace/goals/state.json and index.md.

Include:
- Goals created today + sources
- Goals in progress + last action + next retry time
- Goals completed since last digest + verification evidence pointers
- Blocked/canceled + what is needed
- Token usage summary since last digest (best-effort from stored per-goal counters)
- Limitations (e.g., if email/github harvesting not configured)

Output as a single Telegram message.
MSG
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

gateway_cron_available() {
  timeout 3s openclaw cron list --json >/dev/null 2>&1
}

upsert_cron_jobs_via_gateway() {
  # Creates/repairs orchestrator:main and orchestrator:digest via the gateway.
  python3 - <<'PY'
import json, subprocess, sys

def sh(*args):
  p=subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
  return p.returncode, p.stdout, p.stderr

code,out,err=sh('openclaw','cron','list','--json')
if code!=0:
  print(err.strip())
  raise SystemExit(2)

j=json.loads(out)
jobs=j.get('jobs',[]) or []
by_name={ (job.get('name') or ''): job for job in jobs }

def job_id(name):
  job=by_name.get(name)
  if not job: return None
  return job.get('id')

main_id=job_id('orchestrator:main')
digest_id=job_id('orchestrator:digest')

main_msg=open('/home/theengineer/.openclaw/workspace/skills/orchestrator-skill/.orchestrator_main_message.txt','r',encoding='utf-8').read()
digest_msg=open('/home/theengineer/.openclaw/workspace/skills/orchestrator-skill/.digest_message.txt','r',encoding='utf-8').read()

# orchestrator:main (hourly, isolated, no deliver)
if main_id:
  sh('openclaw','cron','edit',main_id,
     '--name','orchestrator:main',
     '--agent','main',
     '--every','1h',
     '--session','isolated',
     '--message',main_msg,
     '--timeout-seconds','3300',
     '--enable',
     '--no-deliver')
else:
  sh('openclaw','cron','add',
     '--name','orchestrator:main',
     '--agent','main',
     '--every','1h',
     '--session','isolated',
     '--message',main_msg,
     '--timeout-seconds','3300',
     '--no-deliver')

# orchestrator:digest (09:00 and 21:00 Asia/Singapore, isolated, announce)
if digest_id:
  sh('openclaw','cron','edit',digest_id,
     '--name','orchestrator:digest',
     '--agent','main',
     '--cron','0 9,21 * * *',
     '--tz','Asia/Singapore',
     '--session','isolated',
     '--message',digest_msg,
     '--timeout-seconds','600',
     '--enable',
     '--announce')
else:
  sh('openclaw','cron','add',
     '--name','orchestrator:digest',
     '--agent','main',
     '--cron','0 9,21 * * *',
     '--tz','Asia/Singapore',
     '--session','isolated',
     '--message',digest_msg,
     '--timeout-seconds','600',
     '--announce')

print('OK')
PY
}

upsert_cron_jobs_by_editing_jobs_json() {
  # Fallback when gateway is unreachable: patch ~/.openclaw/cron/jobs.json directly.
  # This should only be used for local repair/debug.
  python3 - <<'PY'
import json
import uuid
from pathlib import Path

jobs_path=Path('/home/theengineer/.openclaw/cron/jobs.json')

def now_ms():
  import time
  return int(time.time()*1000)

j=json.loads(jobs_path.read_text())
jobs=j.get('jobs',[]) or []

main_msg=Path('/home/theengineer/.openclaw/workspace/skills/orchestrator-skill/.orchestrator_main_message.txt').read_text(encoding='utf-8')
digest_msg=Path('/home/theengineer/.openclaw/workspace/skills/orchestrator-skill/.digest_message.txt').read_text(encoding='utf-8')

# Helpers

def find_jobs(name):
  return [job for job in jobs if (job.get('name')==name)]

def upsert(name, desired):
  existing=find_jobs(name)
  if not existing:
    jobs.append(desired)
    return
  # keep first, disable duplicates
  keep=existing[0]
  keep.clear(); keep.update(desired)
  for extra in existing[1:]:
    extra['enabled']=False

now=now_ms()

main_job={
  'id': str(uuid.uuid4()),
  'agentId': 'main',
  'name': 'orchestrator:main',
  'enabled': True,
  'createdAtMs': now,
  'updatedAtMs': now,
  'schedule': {'kind':'every','everyMs':3600000,'anchorMs': now},
  'sessionTarget': 'isolated',
  'wakeMode': 'now',
  'payload': {'kind':'agentTurn','message': main_msg, 'timeoutSeconds': 3300},
  'delivery': {'mode':'none'},
}

digest_job={
  'id': str(uuid.uuid4()),
  'agentId': 'main',
  'name': 'orchestrator:digest',
  'enabled': True,
  'createdAtMs': now,
  'updatedAtMs': now,
  'schedule': {'kind':'cron','expr':'0 9,21 * * *','tz':'Asia/Singapore'},
  'sessionTarget': 'isolated',
  'wakeMode': 'now',
  'payload': {'kind':'agentTurn','message': digest_msg, 'timeoutSeconds': 600},
  'delivery': {'mode':'announce'},
}

# Preserve IDs if already present
for name, new in [('orchestrator:main', main_job), ('orchestrator:digest', digest_job)]:
  existing=find_jobs(name)
  if existing:
    new['id']=existing[0].get('id') or new['id']
    new['createdAtMs']=existing[0].get('createdAtMs') or new['createdAtMs']

upsert('orchestrator:main', main_job)
upsert('orchestrator:digest', digest_job)

j['jobs']=jobs

# atomic write
out=jobs_path.with_suffix('.json.tmp')
out.write_text(json.dumps(j, indent=2, sort_keys=False)+"\n")
out.replace(jobs_path)

print('OK_FALLBACK_JOBS_JSON_PATCHED')
PY
}

write_message_cache_files() {
  # Store prompts into stable files so the python helpers can read them.
  printf "%s" "$(orchestrator_main_message)" > /home/theengineer/.openclaw/workspace/skills/orchestrator-skill/.orchestrator_main_message.txt
  printf "%s" "$(digest_message)" > /home/theengineer/.openclaw/workspace/skills/orchestrator-skill/.digest_message.txt
}

run_local_lightweight_cycle() {
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

j['last_orchestrator_run_at']=ran_at
runs=j.setdefault('runs',{})
runs[ran_at]={
  'ran_at': ran_at,
  'harvested': 0,
  'new_goals': [],
  'updated_goals': [],
  'notes': ['run_once_local_fallback_no_gateway']
}

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

tmp=state_path.with_suffix('.json.tmp')
tmp.write_text(json.dumps(j,indent=2,sort_keys=False)+"\n")
tmp.replace(state_path)

with events_path.open('a',encoding='utf-8') as f:
  f.write(json.dumps({
    'ts': ran_at,
    'kind': 'orchestrator.run_once',
    'note': 'Triggered via orchestrator.run_once fallback (gateway unavailable)'
  })+'\n')

print('OK_LOCAL_FALLBACK')
PY
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
    echo "== cron jobs (names only; best-effort) =="
    if timeout 5s openclaw cron list --json 2>/dev/null | python3 - <<'PY'
import json,sys
try:
  j=json.load(sys.stdin)
except Exception:
  raise SystemExit(1)
for job in j.get('jobs',[]) or []:
  print(f"- {job.get('name')} ({'enabled' if job.get('enabled') else 'disabled'})")
PY
    then
      :
    else
      echo '(cron list unavailable)'
      if [ -f "/home/theengineer/.openclaw/cron/jobs.json" ]; then
        echo
        echo "== ~/.openclaw/cron/jobs.json (names only) =="
        python3 - <<'PY'
import json
from pathlib import Path
p=Path('/home/theengineer/.openclaw/cron/jobs.json')
j=json.loads(p.read_text())
for job in j.get('jobs',[]) or []:
  print(f"- {job.get('name')} ({'enabled' if job.get('enabled') else 'disabled'})")
PY
      fi
    fi
    ;;

  orchestrator.install)
    ensure_base_files
    write_message_cache_files

    if gateway_cron_available; then
      upsert_cron_jobs_via_gateway
    else
      upsert_cron_jobs_by_editing_jobs_json
    fi
    ;;

  orchestrator.run_once)
    ensure_base_files
    write_message_cache_files

    # Preferred: trigger the real orchestrator:main job via gateway.
    if gateway_cron_available; then
      JOB_ID="$(openclaw cron list --json | python3 - <<'PY'
import json,sys
j=json.load(sys.stdin)
for job in j.get('jobs',[]) or []:
  if job.get('name')=='orchestrator:main':
    print(job.get('id') or '')
    break
PY
)"
      if [ -n "$JOB_ID" ]; then
        echo "Running orchestrator:main ($JOB_ID) ..."
        # best-effort: don't hang forever
        timeout 120s openclaw cron run "$JOB_ID" --expect-final --timeout 120000 || true
        echo
        echo "== goals/index.md (first ~120 lines) =="
        sed -n '1,120p' "$INDEX" || true
        echo "OK"
      else
        echo "orchestrator:main not found; falling back to local cycle"
        run_local_lightweight_cycle
      fi
    else
      echo "Gateway cron unavailable; falling back to local cycle"
      run_local_lightweight_cycle
    fi
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

try:
  j=json.loads(state_path.read_text())
except Exception as e:
  problems.append(f"state.json unreadable: {e}")
  j=None

if j is not None:
  for k in ['version','created_at','goals','runs']:
    if k not in j:
      problems.append(f"state.json missing key: {k}")

try:
  events_path.open('a').close()
except Exception as e:
  problems.append(f"events.ndjson not writable: {e}")

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
