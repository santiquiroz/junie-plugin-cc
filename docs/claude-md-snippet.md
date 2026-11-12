# CLAUDE.md snippet

Paste this block into your `CLAUDE.md` to delegate bounded tasks to Junie.

```markdown
# JetBrains Junie delegation

Subagent `junie:junie-rescue`; commands `/junie:rescue` and `/junie:setup`.
Use self-contained tasks; Junie headless is slow. Detached runs last up to
45 minutes by default (`JUNIE_RESCUE_MAX_SECONDS=2700`). The subagent starts
a detached job and repeats separate foreground `wait <id>` calls in
480-second slices (maximum 540); exit 75 means still running. Retain the id
if interrupted: the job continues and can be awaited or cancelled later.
`cancel <id>` kills the tree with exit 130; a wait past the deadline exits 124.

| Trigger | Action |
|---|---|
| Bounded task | `junie:junie-rescue` in the background with a self-contained task |
| Independent review / second opinion | `junie:junie-rescue` with `--read-only`; include the code or diff |
| Quota, rate limit or auth signal | Do not retry Junie; tell the user in one line and handle the task inline |

Never delegate domain logic, business rules, architecture, or anything whose
WHY lives in this conversation.

Review `git status` and `git diff` after every run. Junie has no sandbox on
Windows and auto-approves all commands: the constraints in the prompt are not
enforced. `--read-only` runs in a disposable worktree for isolation.
The default model `junie-lite` is free; `--model` selects credit-consuming models.
Run `/junie:setup` once to check CLI and auth.
```
