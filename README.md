# junie-plugin-cc

Delegate bounded coding tasks from [Claude Code](https://claude.com/claude-code)
to JetBrains Junie CLI (`junie`) in headless mode.

Claude Code remains the orchestrator: it supplies the task contract, handles
domain decisions and reviews the changes. Use this plugin for a bounded spec,
rename, boilerplate task, one fix, focused investigation or read-only second
opinion. Junie is slow: a trivial task took about 35 seconds with `junie-lite`.

> Leer en español: [README.es.md](README.es.md)

## When it helps

- **Bounded tasks:** a spec, rename, boilerplate, one fix or a focused
  investigation — work with a clear contract that does not need the
  conversation's context.
- **Read-only second opinions:** `--read-only` reviews pasted code or a diff
  in a disposable git worktree without touching the original repo.
- **Long decoupled runs:** jobs detach and run up to 45 minutes by default
  while you keep working; an interrupted wait can resume later with the job id.
- **Honest cost:** Junie is slow. Keep delegated tasks self-contained and do
  not wait on it for quick answers.
- **Free default model:** `junie-lite` is free (no credits). Use `--model`
  for other models that accept `--effort` and consume JetBrains credits.

## Requirements

- Claude Code; the forwarder runs through its Bash tool (Git Bash on Windows).
- JetBrains Junie CLI. Verified facts target Junie **26.11.1 on Windows 11**.
- Node.js on `PATH`; the forwarder uses `node` for JSON result parsing.
- Authentication via interactive `junie` sign-in (creates `*.dpapi` files)
  or the `JUNIE_API_KEY` environment variable.

On Windows, Junie installs a shim `~/.local/bin/junie.bat`; the real binary
is `<data>/versions/<v>/junie/junie.exe` where `<data>` = `$JUNIE_DATA_DIR`
or `~/.local/share/junie` and `<v>` = first line of `<data>/current`.
On Linux/macOS, `junie` is expected on `PATH`. `JUNIE_BIN` overrides launcher
selection (also used by the tests).

## Install

In Claude Code:

```text
/plugin marketplace add santiquiroz/junie-plugin-cc
/plugin install junie@junie-plugin-cc
```

## Setup

Once per machine:

```text
/junie:setup
```

If needed, run `junie` once in a normal terminal to sign in interactively.
The plugin's setup command checks these preconditions without printing credentials.

## Usage

```text
/junie:rescue --background add unit tests for src/utils/money.ts covering rounding and negative amounts
/junie:rescue --read-only review this pasted diff for race conditions: <diff>
/junie:rescue --model gemini-3.7-flash --effort high diagnose this focused build failure
```

`/junie:rescue` invokes the `junie-rescue` subagent automatically, forwarding the
raw request as its prompt and returning its output verbatim, including any
`[junie-rescue] WARNING:` lines. Put flags before the task text. Supported flags:

- `--wait` — default; run the subagent in the foreground. It awaits a
  detached Junie job through repeated `wait` slices. An interrupted subagent
  leaves the job running; retain its id to `wait` or `cancel` later.
- `--background` — run the subagent in the background and relay its output
  when it completes. These execution flags are removed from the task before
  forwarding; the forwarder's Bash calls remain foreground.
- `--model <slug>` — optional; if omitted Junie uses `junie-lite` (free).
  Slugs are validated before invocation.
- `--effort <tier>` — `low`, `medium`, or `high`. Only applies to non-`junie-lite`
  models. `junie-lite` ignores this flag.
- `--read-only` — runs Junie in a disposable git worktree; any edits it
  attempted are discarded and the original repo stays intact. Paste code
  or a diff to review.
- `-C <dir>` — run Junie in another directory, such as a git worktree,
  instead of the caller's current one. The home directory, its ancestors
  and agent config folders (`~/.claude`, `~/.codex`, `~/.copilot`,
  `~/.gemini`, `~/.ssh`, `~/.config`, `~/.junie-rescue`, `~/.junie`,
  `~/.dsh`) are refused.

### Long runs

Runs last up to `JUNIE_RESCUE_MAX_SECONDS` (default 2700 seconds, 45 minutes).
`start` detaches the job and `wait <id>` awaits it in 480-second slices
(`--slice <seconds>` accepts up to 540). Each is a separate foreground Bash
call with timeout 600000 ms; exit 75 means still running. The call budget is
`1 + 1 + ceil(MAX/480) + 1`. If the subagent is interrupted, the job continues:
retain its started id to `wait <id>` or `cancel <id>` later. Cancellation exits
130; a wait past the deadline kills the process tree and exits 124. Edits
remain in the working tree. The `run` command keeps a short default limit of 540 seconds
(`JUNIE_RESCUE_TIMEOUT` overrides the seconds). The forwarder passes the task
and constraints in a temporary file read via stdin, not in the process argument list.

### What the forwarder runs

The `junie-rescue` subagent uses foreground `preflight`, then `start`, then
repeated `wait <id>` calls while exit 75 reports a running job. The script
detaches Junie with `nohup`, background and `disown`; job files live under
`${JUNIE_RESCUE_HOME:-$HOME/.junie-rescue}/jobs/<id>/`. It creates a task file
containing the request and its constraints, then runs the equivalent of:

```bash
junie --project <native current directory> \
  --skip-update-check --output-format json \
  --skill-default-locations=false --command-default-location=false \
  --agent-default-location=false --mcp-default-locations=false \
  --config-default-locations=false --share-anonymous-statistics=false \
  --json-output-file <native temporary path> \
  --model junie-lite \
  < <task file with constraints>
```

`--model <slug>` replaces `junie-lite`. Non-`junie-lite` models with `--effort`
add that flag. `JUNIE_RESCUE_SKILLS` adds `--skill-location` per directory.
The child gets `GIT_TERMINAL_PROMPT=0`,
`GIT_SSH_COMMAND="ssh -o BatchMode=yes"`, no MSYS path-conversion overrides,
and the task file on stdin. Paths are converted with `cygpath -w` when available.

After the run, the forwarder prints the `result` field from the JSON output,
a usage line (model, tokens, cost), the `sessionId`, and any changed files.
ANSI escape codes are stripped from Junie's stdout transcript.

## Safety model

**Junie has no sandbox on Windows and auto-approves all commands in headless mode.**
The `--read-only` flag runs Junie in a disposable git worktree and discards
the edits it makes there. For normal runs, Junie can edit any file in the
workspace, and because its shell commands run unrestricted with your user
account, it can also write outside the workspace, delete files or run
`git push` if it decides to.

The task constraints forbid committing, pushing, resetting, checking out,
cleaning, switching branches and deleting files — but the prompt's constraints
are not a sandbox: the delegate can still edit files inside the workspace.
Before and after the run, the forwarder compares `HEAD`, branch, stash, git config
and hooks and prints a `[junie-rescue] WARNING:` for changes. Review every
warning and the working tree diff before your next git command.

### Risks

- **No Windows sandbox:** Junie headless runs in "Auto" mode and approves
  any command. It ignores `allowlist.json` at both user and project level.
- **File edits:** Junie can create, modify and rename files in the workspace.
  Review `git status` and `git diff` after every run.
- **Shell commands:** Junie can run arbitrary shell commands. The constraints
  ask it not to, but they are not enforced.
- **Read-only worktree:** `--read-only` points Junie at a disposable git
  worktree and discards the edits made there. It is not a sandbox: a command
  that names an absolute path outside the worktree still runs.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `JUNIE_BIN` | launcher discovery | Overrides Junie binary selection (also used by the tests) |
| `JUNIE_API_KEY` | none | Authentication; takes priority over dpapi files |
| `JUNIE_HOME` | `~/.junie` | Junie home directory (for dpapi_credentials lookup) |
| `JUNIE_DATA_DIR` | `~/.local/share/junie` | Junie data directory (for versioned binary lookup) |
| `JUNIE_RESCUE_HOME` | `$HOME/.junie-rescue` | Job files live under `jobs/<id>/` |
| `JUNIE_RESCUE_MAX_SECONDS` | `2700` (45 minutes) | Detached-run deadline for `start`/`wait` |
| `JUNIE_RESCUE_TIMEOUT` | `540` | Short `run` command limit, in seconds |
| `JUNIE_RESCUE_SKILLS` | none | Semicolon-separated skill directories → `--skill-location` each |
| `JUNIE_RESCUE_FORCE_WINDOWS` | `0` | Treat the host as Windows (tests) |
| `JUNIE_RESCUE_KILL` | `taskkill` | Process-tree kill command (hermetic tests) |

## Troubleshooting

- **No credentials (exit 70):** `JUNIE_API_KEY` takes priority. Otherwise setup
  checks `$JUNIE_HOME/dpapi_credentials/` for any `*.dpapi` file without reading it.
  If neither exists, run `junie` once in a normal terminal to sign in, then `/junie:setup`.
- **Missing CLI (exit 127):** install JetBrains Junie or ensure `junie` is
  on `PATH`. `JUNIE_BIN` overrides launcher selection. Run `/junie:setup` again.
- **Missing Node (exit 127):** install Node.js and ensure `node` is on `PATH`
  for JSON result parsing.
- **Exit 0 without JSON:** Junie exited successfully but produced no result
  file — the task may not have completed. Check the output for error messages.
- **Quota or credit limit (exit 69):** when a run fails (nonzero exit, no
  result JSON or `errors` in it) and its output mentions `quota`, `credit`,
  `rate limit`, `429`, `too many requests` or `insufficient`, the forwarder
  reports it. A successful run is never classified, so a task about quota code
  does not trip it. Never retry automatically.
- **Model not on the free plan:** the free tier is "Junie Lite-only access";
  any other `--model` fails with that message and the forwarder suggests
  `--model junie-lite`.
- **Interrupted subagent:** an interrupted subagent leaves the detached job
  running. Retain its started id to `wait <id>` or `cancel <id>` later.
  Cancellation exits 130; a wait past the deadline kills the process tree and
  exits 124. Edits remain in the working tree.

## Using it with other delegates

If you use several delegation plugins, decide their order in your `CLAUDE.md`;
this plugin assumes none. On quota, rate-limit or authentication signals it
stops and reports, so the caller can choose another route.

Related projects: [deepseek-plugin-cc](https://github.com/santiquiroz/deepseek-plugin-cc), [copilot-plugin-cc](https://github.com/santiquiroz/copilot-plugin-cc), [antigravity-plugin-cc](https://github.com/santiquiroz/antigravity-plugin-cc), [cursor-plugin-cc](https://github.com/santiquiroz/cursor-plugin-cc), [ollama-plugin-cc](https://github.com/santiquiroz/ollama-plugin-cc).

## Files and tests

| Path | Purpose |
|---|---|
| `agents/junie-rescue.md` | Thin Bash-only forwarder subagent |
| `scripts/junie-forward.sh` | Launcher, preflight, safe invocation, timeout and git warnings |
| `tests/run.sh` | Hermetic test suite using a fake Junie CLI |
| `tests/fake-junie.sh` | Fake Junie binary for tests |
| `/junie:rescue`, `/junie:setup` | Delegation and preflight commands |
| `docs/delegation-guide.md` | Delegation safety and fallback |
| `docs/claude-md-snippet.md` | Ready-to-paste delegation guidance |

The test suite is `bash tests/run.sh`. CI runs it on Ubuntu and Windows.

## License

[MIT](LICENSE)

**Not affiliated with JetBrains or Anthropic.**
