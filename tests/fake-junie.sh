#!/usr/bin/env bash
set -u

# Fake Junie CLI for tests
# Modes controlled by FAKE_JUNIE_MODE variable:
#   ok (default) — writes JSON result, prints transcript with ANSI
#   noauth — prints "Cannot find authorization. Please authenticate before running Junie." and exits 0
#   quota — prints quota error and exits 0
#   nojson — exits 0 without writing JSON
#   edit-file — creates a file in the workspace
#   sleep — sleeps for FAKE_JUNIE_SLEEP seconds

if [ "${1:-}" = --version ]; then
  printf '%s\n' 'Junie 26.11.1 (4020.7)'
  exit 0
fi

if [ "${1:-}" = list-models ]; then
  printf '%s\n' '[{"id":"junie-lite","name":"Junie Lite","default":true},{"id":"gemini-3.7-flash","name":"Gemini 3.7 Flash"},{"id":"claude-opus-5-5","name":"Claude Opus 5.5"},{"id":"gpt-6.1-terra","name":"GPT 6.1 Terra"}]'
  exit 0
fi

# Find --json-output-file to know where to write
json_output_file=""
project_dir=""
model_used=""
previous=""
for arg in "$@"; do
  if [ "$previous" = --json-output-file ]; then json_output_file=$arg; previous=""; fi
  if [ "$previous" = --project ]; then project_dir=$arg; previous=""; fi
  if [ "$previous" = --model ]; then model_used=$arg; previous=""; fi
  [ "$arg" = --json-output-file ] && previous=--json-output-file
  [ "$arg" = --project ] && previous=--project
  [ "$arg" = --model ] && previous=--model
done

# Record call info
calls="${FAKE_JUNIE_CALLS:-/tmp/fake-junie-calls}"
mkdir -p "$calls"
number=1
while [ -e "$calls/$number.args" ]; do number=$((number + 1)); done
printf '%s\0' "$@" >"$calls/$number.args"
printf '%s\n' "$0" >"$calls/$number.launcher"

# Record stdin (the task file content)
cat >"$calls/$number.stdin"

# Record env
{
  printf 'GIT_TERMINAL_PROMPT=%s\n' "${GIT_TERMINAL_PROMPT-}"
  printf 'GIT_SSH_COMMAND=%s\n' "${GIT_SSH_COMMAND-}"
} >"$calls/$number.env"

# Record the task file content if we can find it in args
task_content=""
for arg in "$@"; do
  if [[ "$arg" == *.txt ]] && [ -r "$arg" ]; then
    task_content=$(cat "$arg")
    break
  fi
done

mode="${FAKE_JUNIE_MODE:-ok}"

case "$mode" in
  sleep)
    sleep "${FAKE_JUNIE_SLEEP:-30}" &
    child_pid=$!
    [ -z "${FAKE_JUNIE_CHILD_PID_FILE:-}" ] || printf '%s\n' "$child_pid" >"$FAKE_JUNIE_CHILD_PID_FILE"
    wait "$child_pid"
    exit "${FAKE_JUNIE_EXIT:-0}"
    ;;

  noauth)
    # Junie exits 0 but prints auth error to stdout and does NOT write JSON
    printf '\033[32mJunie starting...\033[0m\n'
    printf 'Cannot find authorization. Please authenticate before running Junie.\n'
    exit 0
    ;;

  quota)
    printf '\033[32mJunie starting...\033[0m\n'
    printf 'Error: quota exceeded — insufficient credits for this model.\n'
    exit 0
    ;;

  json-errors)
    printf '\033[31mJunie failed\033[0m\n'
    if [ -n "$json_output_file" ]; then
      mkdir -p "$(dirname "$json_output_file")"
      printf '%s\n' '{"errors":["Model '"'"'gemini-3.7-flash'"'"' is unavailable with Junie Lite-only access. Choose Junie Lite or specify another provider with --provider."]}' >"$json_output_file"
    fi
    exit 1
    ;;

  quota-words)
    # A successful run whose transcript talks about quotas must not be reported as a quota hit
    printf 'Updated the quota handling: credit balance, 429 retries and insufficient funds messages.\n'
    ;;

  nojson)
    # Exits 0 but does not write the JSON file
    printf '\033[32mJunie starting...\033[0m\n'
    printf '\033[90mJunie 26.11.1 (4020.7) (pid=%s): log file: /tmp/junie.log\033[0m\n' "$$"
    exit 0
    ;;

  edit-file)
    # Create a file in the project directory to simulate edits
    if [ -n "$project_dir" ]; then
      printf 'edited by junie\n' >"$project_dir/junie-edited.txt"
    fi
    # Fall through to ok mode to also write JSON
    ;;
esac

# Default: ok mode — write JSON result and print transcript
printf '\033[32mJunie starting...\033[0m\n'
printf '\033[90mJunie 26.11.1 (4020.7) (pid=%s): log file: /tmp/junie.log\033[0m\n' "$$"
printf '\033[2mProcessing task...\033[0m\n'

if [ -n "$json_output_file" ]; then
  mkdir -p "$(dirname "$json_output_file")"
  model="${model_used:-junie-lite}"
  cat >"$json_output_file" <<ENDJSON
{"sessionId":"session-test-$(date +%s)","taskName":"Test task","result":"- Tarea completada.\n\nSTATUS: DONE","changes":[{"afterContent":{"kind":"TextFileContent","text":"hola\n"},"afterAbsolutePath":"$(printf '%s' "${project_dir:-/tmp}"/hola.txt | sed 's/\\/\\\\/g')","afterRelativePath":"hola.txt"}],"llmUsage":[{"model":"${model}","calls":3,"cost":0.001,"inputTokens":500,"cacheInputTokens":400,"cacheCreateTokens":0,"outputTokens":100}]}
ENDJSON
fi

exit "${FAKE_JUNIE_EXIT:-0}"
