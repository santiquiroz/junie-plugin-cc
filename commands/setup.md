---
description: Check Junie CLI installation, authentication, and available models
argument-hint: ""
allowed-tools: Bash
---

Run the shared preflight and report its output without revealing credentials:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/junie-forward.sh" preflight
```

This checks:

1. **Junie binary** — resolves the binary from `JUNIE_BIN`, `$JUNIE_DATA_DIR/versions/<current>/junie[junie.exe]`, or `junie` on PATH. Shows the version.
2. **Authentication** — checks for `JUNIE_API_KEY` or `*.dpapi` files in `$JUNIE_HOME/dpapi_credentials/` (default `~/.junie/dpapi_credentials/`). Never prints credentials.
3. **Optional model** — if `--model <slug>` is passed, shows the selected model.

Handle failures:

- **127**: install JetBrains Junie or ensure `junie` is on `PATH`. Set `JUNIE_BIN` to override launcher discovery. Run `/junie:setup` again.
- **70**: run `junie` once in a normal terminal to sign in interactively, or set `JUNIE_API_KEY` with a valid token, then rerun `/junie:setup`.

To see available models, run:

```bash
junie list-models
```

The default model is `junie-lite` (free, no `--effort`). Other models like
`gemini-3.7-flash`, `claude-opus-5-5`, `gpt-6.1-terra` accept `--effort low|medium|high`
and consume JetBrains credits.

For custom skills, set `JUNIE_RESCUE_SKILLS` to semicolon-separated directories
(e.g. `JUNIE_RESCUE_SKILLS="/path/to/skill1;/path/to/skill2"`). Each directory
becomes a `--skill-location` argument; missing directories cause an error.

Never print the contents of Junie's auth files or an API key.
