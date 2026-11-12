# Changelog

## 0.1.0 — 2026-11-12

First release of the JetBrains Junie delegation plugin.

- `junie-rescue` forwards bounded tasks to `junie` CLI in headless mode with
  fixed flags (`--skip-update-check`, `--output-format json`, `*-default-locations=false`),
  task passed via stdin file, and JSON result parsing.
- Binary resolution: `JUNIE_BIN` override, then `$JUNIE_DATA_DIR/versions/<current>/junie[junie.exe]`,
  then `junie` on PATH (Linux/macOS).
- Auth detection: `JUNIE_API_KEY` or `*.dpapi` files in `$JUNIE_HOME/dpapi_credentials/`.
- Default model `junie-lite` (free, no `--effort`); other models accept
  `--effort low|medium|high` and consume JetBrains credits.
- `--read-only` runs Junie in a disposable git worktree and discards edits;
  original repo stays intact.
- `JUNIE_RESCUE_SKILLS` for optional curated skills (semicolon-separated dirs).
- Error detection: no-auth (exit 70), quota/credit limit (exit 69, only for failed runs), exit 0
  without JSON (explicit error).
- Detached `start`, sliced `wait` (exit 75 while running) and `cancel` (exit 130);
  default deadline 2700 seconds via `JUNIE_RESCUE_MAX_SECONDS`.
- ANSI codes stripped from Junie's stdout transcript.
- Result summary prints `result` text, usage (model, tokens, cost), `sessionId`,
  and changed files from the JSON output.
- Hermetic test suite with fake Junie CLI covering all modes.
- `/junie:rescue`, `/junie:setup`, delegation guide and English/Spanish READMEs.
