---
description: Delegate a bounded coding task to JetBrains Junie through the junie-rescue subagent
argument-hint: "[--background|--wait] [-C <dir>] [--model <slug>] [--effort <tier>] [--read-only] [the task Junie should perform]"
allowed-tools: Agent
---

Invoke the `junie:junie-rescue` subagent using the Agent tool, forwarding the raw
user request as its prompt. It is a subagent, not a skill. Return its final
output verbatim, including any `[junie-rescue] WARNING:` lines.

Execution mode:

- If the request includes `--background`, run the subagent in the background
  and continue other work; relay the result when it completes.
- If the request includes `--wait`, run the subagent in the foreground.
- If neither flag is present, default to foreground.
- `--background` and `--wait` control the Agent invocation. Remove them from
  the forwarded prompt; they are not runtime flags or task text.
- Preserve `-C <dir>`, `--model`, `--effort` and `--read-only` in the forwarded prompt.
  The subagent extracts them before forwarding the natural-language task.

Forward a self-contained task. For read-only reviews, ask the user to
include the relevant code or diff in the task.

The subagent calls `preflight`, then `start`, then repeats `wait <id>` while
it exits 75. Each is a separate foreground Bash call; waits use timeout
600000 ms, never `run_in_background`. The forwarder detaches Junie. Runs last
up to `JUNIE_RESCUE_MAX_SECONDS` (default 2700 seconds, 45 minutes), awaited in
480-second slices (maximum 540). The call budget is
`1 + 1 + ceil(MAX/480) + 1`.

If the subagent is interrupted, retain its started job id: the job keeps
running. Later use `bash "${CLAUDE_PLUGIN_ROOT}/scripts/junie-forward.sh" wait <id>`
or `cancel <id>` (exit 130). A wait past the deadline kills the process tree
with exit 124. Edits remain in the working tree.

If the result starts with `[junie-rescue] Junie quota or credit limit hit`, do not
retry Junie; report it to the user so they can choose another route, or handle
the task inline. If authentication is missing, tell the user to run
`junie` once in a terminal to sign in (or set `JUNIE_API_KEY`), then `/junie:setup`.
If no task was supplied, ask what Junie should do.

Raw user request:
$ARGUMENTS
