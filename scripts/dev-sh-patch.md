# dev.sh patch

Add these two lines immediately after `export PORT` in `scripts/devbox/dev.sh`
to persist the selected port so the landscape agent can read it:

```bash
PORT="$(find_free_port "${PORT:-3000}")"
export PORT
mkdir -p .devbox                        # ← add
echo "$PORT" > .devbox/worktree-port   # ← add
```

The `.devbox/` directory is already gitignored.
