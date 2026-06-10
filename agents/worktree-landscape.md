---
name: worktree-landscape
description: Snapshot all git worktrees and live Claude Code sessions for the current repo. Returns which worktrees exist, their branches, dirty-file count, and which OMP instances are occupying them. Call this before deciding whether to route work into a new or existing worktree. Works from any directory inside a git repo.
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

### Step 3 — dirty file count per worktree

For each worktree path extracted in step 2:
```bash
git -C <path> status --porcelain 2>/dev/null | wc -l | tr -d ' '
```

If the path doesn't exist on disk, note "(missing)" instead.

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
    # check if process is alive
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
  [main]  <path>          branch=<branch>  dirty=<N>  sessions=<summary>
  [wt]    <path>          branch=<branch>  dirty=<N>  sessions=<summary>
  ...

Live sessions (<N>):
  pid=<N>  cwd=<path>  status=<idle|active|unknown>  sid=<8chars>  worktree=<label or "outside repo">
  ...
```

Where `<summary>` for sessions is one of:
- `none`
- `idle (pid=<N>)`
- `active (pid=<N>)` — this means the instance is mid-task
- `multiple: idle=<N> active=<M>`

## Rules

- Read-only. Never `git checkout`, `git switch`, `git add`, `git commit`, or any mutation.
- Sort worktrees: main first, then by path alphabetically.
- If `~/.claude/sessions/` is missing or empty, say "No live sessions."
- A session with `status=active` means it's currently processing a prompt — treat it as "busy".
- Cap branch names at 60 chars; truncate with `…` if longer.
- If a worktree path is missing from disk, show `(missing)` for dirty count and note it.
