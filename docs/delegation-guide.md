# Delegation Guide

Use Junie for bounded tasks: a spec, rename, boilerplate, one fix or a
focused investigation. Claude Code remains the orchestrator.

Junie is slow: trivial tasks take 25 s to several minutes, so run it in the
background and keep working. Detached runs last up to 45 minutes by default
(`JUNIE_RESCUE_MAX_SECONDS=2700`). The subagent calls `start`, then repeats
foreground `wait <id>` calls in 480-second slices (maximum 540); exit 75 means
still running. A wait past the deadline kills the process tree with exit 124.
An interrupted subagent leaves the job running: retain its id to `wait` or
`cancel` later (exit 130). Edits remain in the working tree. The `run` command
keeps a short default limit of 540 seconds (`JUNIE_RESCUE_TIMEOUT` overrides the
seconds). 3–4 concurrent jobs on different files work fine; do not work on the
same files while a delegated run is active.

For an independent second opinion, use `/junie:rescue --read-only` and paste
the relevant code or diff into the task. Read-only mode runs Junie in a
disposable git worktree: any edits it attempts are discarded and the original
repo stays intact.

## Safety and workspace setup

**Junie has no sandbox on Windows and auto-approves all commands in headless mode.**
The `--read-only` flag runs Junie in a throwaway worktree and discards the
edits made there; it is not a sandbox. For normal runs, Junie can edit any
file in the workspace and run arbitrary shell commands, including ones that
touch paths outside it.

The delegate can still edit files inside the workspace: the forwarder compares
git metadata and prints `WARNING` lines for changes to `HEAD`, branch, stash,
config or hooks. Review those warnings and the working tree after every run.

Known risks:
- Junie ignores `allowlist.json` at both user and project level.
- Junie runs in "Auto" mode — no command requires approval.
- The constraints in the prompt are not enforced; they are a request, not a policy.

## Task shape

Write a self-contained task: paths, required behavior, constraints and
acceptance checks. Keep one deliverable per run. The task is sent to Junie via
a temporary file read through stdin, not an argv string. Do not work on the
same files while a delegated run is active.

Review `git status` and `git diff` after every run, along with every
`[junie-rescue] WARNING:` line. The constraints in the prompt are not a
sandbox: Junie may edit files inside the workspace.

When a run fails with quota/rate-limit output (exit 69), including `429`, quota,
credit limit or insufficient capacity, stop and report it; never retry Junie automatically. On
`Cannot find authorization` or `Please authenticate` output, run `junie` once
in a normal terminal to sign in, or set `JUNIE_API_KEY`.

## Models

The default model is `junie-lite` — free, no `--effort` flag. Other models
(`gemini-3.7-flash`, `claude-opus-5-5`, `gpt-6.1-terra`, `claude-sonnet-5-5`…)
accept `--effort low|medium|high` and consume JetBrains credits. Use
`junie list-models` to see the full catalog.

## Using it with other delegates

If you use several delegation plugins, define their order in your own
`CLAUDE.md`; this plugin does not assume any other delegate exists.
