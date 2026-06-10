---
name: worktree-route
description: Multi-agent aware worktree router. When a message references a branch, PR, or worktree by name and asks to check/review/fix it, this skill reads the live worktree and session landscape, makes an isolation decision, and either routes the work into the right worktree or explains why it's safe to work in-place. Use when the user mentions a branch/PR name with intent to work on it (e.g. "academy-wave1-schema has a requested change, can you check it?", "can you look at the fix/gce-3972 branch?", "rebase pr-7914 for me").
---

> **Before starting:** Run `node .claude/track-skill.mjs embedded worktree-route`

# Worktree Router

Routes work to the right git worktree based on the live multi-agent landscape.

## When to invoke this skill

Invoke when:
- The user names a branch, PR, or worktree slug that is **not** the current branch
- The request involves modifying, checking, reviewing, or rebasing that branch
- The phrasing suggests isolation is needed ("can you check it", "fix that PR", "rebase that branch")

Do NOT invoke for:
- Questions about the current branch's code
- Pure git metadata reads (`git log`, `git diff`) where no checkout is needed
- Requests that name the current branch explicitly

---

## Step 1 — Resolve the target branch

Extract the branch/PR reference from the user's message. It may be:

- **Exact branch name**: `academy-wave1-schema`, `fix/gce-3972-multi-transcript`
- **PR number**: `#7914`, `pr 7914`, `pull/7914`
- **Worktree slug**: `pr-7914-skill-editor`, `company-profile-fix`
- **Partial/natural language**: "the wave1 schema branch", "the 3972 fix", "that enrollment PR"

Resolution order:
1. Exact match in `git worktree list` output (branch or path)
2. Fuzzy match: `git branch -a | grep -i "<token>"` — prefer the most recently committed branch
3. PR number: `gh pr view <N> --json headRefName -q .headRefName`
4. If unresolvable, ask the user to clarify and stop here.

---

## Step 2 — Read the landscape

Call the `worktree-landscape` agent (Task tool, `subagent_type: "worktree-landscape"`) with prompt:

```
Report the worktree landscape. I'm looking for target branch: <resolved_branch>
```

From its output, extract:
- `current_worktree`: the worktree where THIS session is running (match by `cwd`)
- `current_dirty`: dirty file count of current worktree (>0 means work in progress)
- `current_active`: any session in current worktree has `status=active`
- `target_worktree`: worktree whose `branch=<resolved_branch>`, if any
- `target_occupied`: whether any live session lives in `target_worktree`
- `target_occupied_active`: whether that session is `status=active` (mid-task)

---

## Step 3 — Make the routing decision

Use this matrix. Check conditions top to bottom; take the first match.

| Condition | Decision |
|-----------|----------|
| `target_occupied_active` = true | **CONFLICT** — another session is actively working on that branch right now. Notify user, do not proceed. |
| `target_occupied` = true (but idle) | **COORDINATE** — a session exists there but is idle. Notify the user; proceed only if they confirm (the idle session may have uncommitted state). |
| `target_worktree` exists AND (`current_dirty` > 0 OR `current_active`) | **ROUTE TO EXISTING WORKTREE** — current session has in-flight work; use the dedicated worktree. |
| `target_worktree` exists AND current is idle and clean | **ROUTE TO EXISTING WORKTREE** — keep work isolated; branch isolation is almost always worth it. |
| `target_worktree` = none AND (`current_dirty` > 0 OR `current_active`) | **CREATE + ROUTE** — must isolate; create a new worktree. |
| `target_worktree` = none AND current is idle and clean AND request is read-only | **IN-PLACE** — safe to fetch/switch locally; no worktree needed. Mention this to the user. |
| `target_worktree` = none AND current is idle and clean AND request is mutating | **CREATE + ROUTE** — create a worktree for safety. |

**Read-only requests**: checking review comments, summarizing a diff, reading code, writing a report about a PR.
**Mutating requests**: applying fixes, committing, rebasing, pushing.

---

## Step 4 — Execute

### ROUTE TO EXISTING WORKTREE (non-interactive / reporting back)

For read-only or bounded tasks where you need results reported back to this session:

```bash
(cd <target_worktree_path> && claude -p "<task_prompt>" --no-session-persistence 2>&1)
```

Build `<task_prompt>` from the user's original request plus this preamble:
```
You are working in the git worktree at <target_worktree_path> on branch <branch>.
<original user request>
```

Include any PR number, branch context, or review thread info that helps scope the task.

For the common "check a PR's requested changes" case, the prompt should be:

```
You are in the worktree for branch <branch>. 
1. Run: gh pr view --json number,title,state,reviewDecision,reviews,comments
2. Fetch unresolved review threads: gh api repos/<owner>/<repo>/pulls/<N>/comments
3. Summarize: what changes were requested, which files are affected, and your recommendation (fix / push back / already addressed).
Keep the summary under 20 lines.
```

Capture stdout and present it inline in the current session.

### ROUTE TO EXISTING WORKTREE (interactive / complex work)

For tasks that need an interactive session (multi-step fix, rebase, extended investigation):

```bash
claude --tmux --worktree <slug> 
```

OR, if the worktree already exists (the `--worktree` flag creates NEW worktrees):

```bash
# Open a new tmux window/pane in the existing worktree
tmux new-window -c <target_worktree_path> "claude"
```

Tell the user: "Opening an interactive session in `<worktree_path>` on branch `<branch>`."

### CREATE + ROUTE (new worktree)

Determine the slug: sanitize `<branch>` to lowercase alphanumeric+dash, max 40 chars. Use the Linear ticket prefix if present (e.g. `gce-3972`).

```bash
# Convention: worktrees live in .claude/worktrees/ inside the repo
REPO_ROOT=$(git rev-parse --show-toplevel)
WORKTREE_PATH="$REPO_ROOT/.claude/worktrees/<slug>"
git worktree add "$WORKTREE_PATH" <branch>
```

Then proceed with ROUTE TO EXISTING WORKTREE patterns above.

### IN-PLACE

Tell the user you'll handle it in the current session. No routing needed. Proceed normally.

### CONFLICT / COORDINATE

Output a clear notice:

```
⚠️  <branch> is currently occupied by another Claude session (pid=<N>, status=<active|idle>).
Worktree: <path>

[active] Do not proceed — the other session is mid-task. 
         Check back after it finishes, or kill it with `kill <pid>` if it's stuck.

[idle]   Proceed? The idle session may have uncommitted state that would conflict.
         Confirm to route anyway, or open the other session to check its state first.
```

---

## Step 5 — After routing

For `claude -p` subagent results:
- Present the output cleanly with a header: `## Results from <branch> worktree`
- If the output contains actionable items (fix requests, test failures), list them as a checklist
- Offer to act on them interactively in this session OR route back to the worktree

For interactive (`--tmux`) spawns:
- Confirm to the user the session was opened and in which pane
- Leave a breadcrumb: add a note to the current conversation about what was delegated

---

## Worktree lifecycle

**Naming convention** (for worktrees this skill creates):
- `.claude/worktrees/<slug>` inside the repo root
- Slug = sanitized branch name, e.g. `gce-3514-enrollment` (not the full branch)

**Do NOT clean up** worktrees after use — the user or another agent may continue working there.

**Re-use over re-create**: always check if a worktree for the branch already exists before `git worktree add`. Creating a second worktree for the same branch fails with a git error.

---

## Routing rationale (emit this to the user)

Always tell the user WHY you're routing (or not). Keep it to one sentence:

- "Your current session has uncommitted work (`<N>` dirty files) — routing to the existing `<branch>` worktree."
- "No active worktree found for `<branch>` — creating one at `.claude/worktrees/<slug>`."
- "Current session is clean and this is a read-only check — handling in-place."
- "Another session (pid=`<N>`) is actively working in that worktree — not routing."

---

## Edge cases

- **Detached HEAD worktree**: treat it as a normal worktree for routing purposes. Note the detached state to the user.
- **Branch not yet fetched**: run `git fetch origin <branch>` before `git worktree add`.
- **Multiple worktrees for same branch**: shouldn't happen (git prevents it), but if detected, use the first/most recent one.
- **`claude -p` output empty**: the subagent may have hit a permission prompt. Report the empty result and suggest the user open an interactive session in that worktree directly.
- **tmux not available**: fall back to printing the `cd + claude` command for the user to run manually.
