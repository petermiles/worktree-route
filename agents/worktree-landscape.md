---
name: worktree-landscape
description: Snapshot all git worktrees and live Claude Code sessions for the current repo. Returns which worktrees exist, their branches, dirty-file count, assigned dev server port, server running status, and which OMP instances are occupying them. Call this before deciding whether to route work into a new or existing worktree, or whether a dev server needs to be started. Works from any directory inside a git repo.
tools: Bash
model: haiku
---

Report the multi-agent worktree landscape for the current repo. Read-only.

## Instructions

Run the following steps in order and combine the results into the output below.

### Step 1 — repo root

```bash
git rev-parse --show-toplevel
```

If this fails, output "Not inside a git repo." and stop.

### Step 2 — worktrees (porcelain)

```bash
git worktree list --porcelain
```

Parse each blank-line-separated record. Each record contains:
- `worktree <absolute-path>` — the checkout path
- `HEAD <sha>`
- Either `branch refs/heads/<name>` (normal) or `detached` (detached HEAD)
- Optionally `bare` (bare repo — skip it)

The first record is always the "main" worktree (the original repo root).

### Step 3 — per-worktree data

For each worktree path from step 2, collect three things:

**Dirty file count:**
```bash
git -C <path> status --porcelain 2>/dev/null | wc -l | tr -d ' '
```
If the path doesn't exist on disk, note "(missing)" and skip the rest for this worktree.

**Assigned port** (read `.devbox/worktree-port` written by dev.sh or worktree-setup.sh):
```bash
cat <path>/.devbox/worktree-port 2>/dev/null || echo "unassigned"
```

**Server status** (only if a port was assigned):
```bash
# Check if the port is currently listening
(echo > /dev/tcp/localhost/<port>) >/dev/null 2>&1 && echo "running" || echo "stopped"
```
If port is "unassigned", set server status to "not started".

**Setup state** (has the worktree been initialized?):
```bash
# Check for markers that worktree-setup.sh has run
test -d <path>/node_modules && echo "deps:ok" || echo "deps:missing"
test -f <path>/.devbox/last-pnpm-build && echo "build:ok" || echo "build:missing"
test -s <path>/.env && echo "env:ok" || echo "env:missing"
```

### Step 4 — live sessions

```bash
python3 - <<'EOF'
import os, json, glob

session_dir = os.path.expanduser("~/.claude/sessions")
if not os.path.isdir(session_dir):
    print("No sessions directory found.")
    exit()

sessions = []
for path in glob.glob(os.path.join(session_dir, "*.json")):
    try:
        with open(path) as f:
            d = json.load(f)
    except Exception:
        continue
    pid = d.get("pid")
    if not pid:
        continue
    try:
        os.kill(int(pid), 0)
        alive = True
    except (OSError, ProcessLookupError):
        alive = False
    if alive:
        sessions.append({
            "pid": pid,
            "cwd": d.get("cwd", ""),
            "status": d.get("status", "unknown"),
            "sessionId": str(d.get("sessionId", ""))[:8],
        })

if not sessions:
    print("No live sessions.")
else:
    for s in sessions:
        print(f"pid={s['pid']}  cwd={s['cwd']}  status={s['status']}  sid={s['sessionId']}")
EOF
```

### Step 5 — correlate sessions to worktrees

For each live session, find which worktree its `cwd` belongs to:
- Exact match: `session.cwd == worktree.path`
- Prefix match: `session.cwd` starts with `worktree.path + "/"`
- No match: mark as "outside repo"

## Output format

Emit exactly this structure (fill in real values):

```
Repo root: <path>

Worktrees (<N>):
  TYPE  BRANCH                     DIRTY  PORT   SERVER     SETUP     SESSIONS
  main  my-current-branch          3      3000   running    ready     idle (pid=58017)
  wt    academy-wave1-schema        0      3421   stopped    ready     none
  wt    feature/foo                 0      unassigned  -     needs-setup  none
  wt    cursor/fix-skill-editor-…  0      3187   stopped    ready     none

Live sessions (<N>):
  pid=<N>  cwd=<path>  status=<idle|active|unknown>  sid=<8chars>  worktree=<label or "outside repo">
```

**SETUP column values:**
- `ready` — `.env` present, `node_modules` exists, `.devbox/last-pnpm-build` present
- `needs-setup` — one or more of those is missing (run `bash scripts/devbox/worktree-setup.sh`)
- `env-missing` — specifically `.env` is absent (most urgent — nothing works without it)

**SERVER column values:**
- `running` — port is listening right now
- `stopped` — port assigned but nothing listening
- `-` — no port assigned yet (server has never been started via dev.sh)

**SESSION column summary:**
- `none`
- `idle (pid=<N>)`
- `active (pid=<N>)` — instance is mid-task
- `multiple: idle=<N> active=<M>`

## Rules

- Read-only. Never `git checkout`, `git switch`, `git add`, `git commit`, or any mutation.
- Sort worktrees: main first, then by path alphabetically.
- If `~/.claude/sessions/` is missing or empty, say "No live sessions."
- A session with `status=active` means it's currently processing a prompt — treat it as "busy".
- Truncate branch names at 40 chars with `…` if longer.
- If a worktree path is missing from disk, show `(missing)` for all columns and skip port/server checks.
- For the SERVER check, only probe the TCP port if a port number was actually read from `.devbox/worktree-port` — never probe 0 or garbage.
