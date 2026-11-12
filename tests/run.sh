#!/usr/bin/env bash
set -u

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
FORWARDER="$ROOT/scripts/junie-forward.sh"
FILTER=${1:-}
REAL_GIT=$(command -v git 2>/dev/null || :)
REAL_NODE=$(command -v node 2>/dev/null || :)
REAL_BASH=$(command -v bash 2>/dev/null || :)
REAL_GIT_DIR=${REAL_GIT%/*}
REAL_NODE_DIR=${REAL_NODE%/*}
TOTAL=0
FAILED=0
RUN_COUNT=0
TEST_FAILED=0
CALL_ARGS=()

fail() { printf '  FAIL: %s\n' "$1"; TEST_FAILED=1; }
assert_status() { [ "$1" = "$2" ] || fail "$3 (expected exit $1, got $2)"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "$3 (missing: $2)" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "$3 (unexpected: $2)" ;; *) ;; esac; }
assert_equal() { [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"; }

new_sandbox() {
  SANDBOX=$(mktemp -d) || exit 1
  export HOME="$SANDBOX/home"
  export USERPROFILE="$HOME"
  if command -v cygpath >/dev/null 2>&1; then USERPROFILE=$(cygpath -w "$HOME"); export USERPROFILE; fi
  export LOCALAPPDATA="$HOME/AppData/Local"
  export FAKE_JUNIE_CALLS="$HOME/calls"
  mkdir -p "$HOME" "$LOCALAPPDATA" "$FAKE_JUNIE_CALLS" "$HOME/bin"

  # Auth: create dpapi_credentials dir with a .dpapi file
  mkdir -p "$HOME/.junie/dpapi_credentials"
  touch "$HOME/.junie/dpapi_credentials/test.dpapi"

  # Fake junie binary
  cp "$TEST_DIR/fake-junie.sh" "$HOME/bin/fake-junie"
  chmod +x "$HOME/bin/fake-junie"
  export JUNIE_BIN="$HOME/bin/fake-junie"
  export JUNIE_RESCUE_HOME="$HOME/.junie-rescue"

  # Fake kill for Windows tests
  cp "$TEST_DIR/fake-kill.sh" "$HOME/bin/fake-kill"
  chmod +x "$HOME/bin/fake-kill"
  export FAKE_JUNIE_KILL_CALLS="$HOME/kill.calls"
  : >"$FAKE_JUNIE_KILL_CALLS"

  # Unset Junie-specific vars
  unset JUNIE_API_KEY JUNIE_HOME FAKE_JUNIE_MODE FAKE_JUNIE_EXIT FAKE_JUNIE_STDERR
  unset FAKE_JUNIE_SLEEP FAKE_JUNIE_CHILD_PID_FILE JUNIE_RESCUE_MAX_SECONDS
  unset JUNIE_RESCUE_KILL JUNIE_RESCUE_SKILLS JUNIE_RESCUE_TIMEOUT JUNIE_RESCUE_FORCE_WINDOWS
  unset JUNIE_DATA_DIR
  unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
  unset MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL GIT_TERMINAL_PROMPT GIT_SSH_COMMAND

  PATH="$HOME/bin:/usr/bin:/bin"
  [ -n "$REAL_GIT_DIR" ] && PATH="$PATH:$REAL_GIT_DIR"
  [ -n "$REAL_NODE_DIR" ] && PATH="$PATH:$REAL_NODE_DIR"
  export PATH
  BASE_TEST_PATH=$PATH

  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
  git config --global user.name "Junie Rescue Test"
  git config --global user.email "junie-rescue-test@example.invalid"

  mkdir -p "$HOME/repo"
  (
    cd "$HOME/repo" || exit 1
    git init -q &&
      printf '%s\n' 'test workspace' >README.md &&
      git add README.md &&
      git commit -q -m initial
  ) || exit 1
}

invoke_args() {
  LAST_OUTPUT=$(cd "$HOME/repo" && "$REAL_BASH" "$FORWARDER" "$@" 2>&1)
  LAST_STATUS=$?
}
invoke_file() {
  input=$1
  shift
  LAST_OUTPUT=$(cd "$HOME/repo" && "$REAL_BASH" "$FORWARDER" "$@" <"$input" 2>&1)
  LAST_STATUS=$?
}
invoke_text() {
  text=$1
  shift
  LAST_OUTPUT=$(cd "$HOME/repo" && printf '%s' "$text" | "$REAL_BASH" "$FORWARDER" "$@" 2>&1)
  LAST_STATUS=$?
}

load_call_args() {
  CALL_ARGS=()
  while IFS= read -r -d '' arg; do CALL_ARGS[${#CALL_ARGS[@]}]=$arg; done <"$FAKE_JUNIE_CALLS/$1.args"
}
has_arg() {
  for arg in "${CALL_ARGS[@]}"; do [ "$arg" = "$1" ] && return 0; done
  return 1
}
arg_value() {
  local wanted=$1 i
  for ((i=0; i<${#CALL_ARGS[@]}; i++)); do
    if [ "${CALL_ARGS[$i]}" = "$wanted" ]; then
      [ $((i + 1)) -lt "${#CALL_ARGS[@]}" ] && printf '%s' "${CALL_ARGS[$((i + 1))]}"
      return 0
    fi
  done
  return 1
}
assert_arg() { has_arg "$1" || fail "$2 (missing argument: $1)"; }
assert_no_arg() { has_arg "$1" && fail "$2 (unexpected argument: $1)" || :; }

# ---- Tests ----

test_preflight_auth_dpapi() {
  invoke_args preflight
  assert_status 0 "$LAST_STATUS" "DPAPI auth preflight"
  assert_contains "$LAST_OUTPUT" 'Junie 26.11.1' "Junie version"
}

test_preflight_api_key() {
  rm -rf "$HOME/.junie/dpapi_credentials"
  export JUNIE_API_KEY=fake-api-key
  invoke_args preflight
  assert_status 0 "$LAST_STATUS" "JUNIE_API_KEY preflight"
}

test_preflight_no_auth() {
  rm -rf "$HOME/.junie/dpapi_credentials"
  unset JUNIE_API_KEY
  invoke_args preflight
  assert_status 70 "$LAST_STATUS" "Missing-auth preflight"
  assert_contains "$LAST_OUTPUT" 'sign in' "Login guidance"
}

test_preflight_model() {
  invoke_args preflight --model gemini-3.7-flash
  assert_status 0 "$LAST_STATUS" "Preflight with model"
  assert_contains "$LAST_OUTPUT" 'model: gemini-3.7-flash' "Model shown"
}

test_node_missing() {
  PATH="$HOME/bin"
  export PATH
  # preflight doesn't require node; run does (for JSON parsing)
  invoke_text 'task' run
  assert_status 127 "$LAST_STATUS" "Missing Node run"
  assert_contains "$LAST_OUTPUT" 'node' "Node guidance"
  PATH=$BASE_TEST_PATH
  export PATH
}

test_preflight_cwd_home_refused() {
  invoke_args preflight -C "$HOME"
  assert_status 64 "$LAST_STATUS" "Home -C refusal"
  assert_contains "$LAST_OUTPUT" 'not permitted' "Home refusal message"
}

test_preflight_cwd_missing() {
  invoke_args preflight -C /nonexistent-dir-xyz
  assert_status 64 "$LAST_STATUS" "Missing -C directory"
  assert_contains "$LAST_OUTPUT" 'not found' "Missing directory message"
}

test_preflight_cwd_no_value() {
  invoke_args preflight -C
  assert_status 64 "$LAST_STATUS" "Missing -C value"
  assert_contains "$LAST_OUTPUT" '-C needs a directory' "Missing value message"
}

test_fixed_flags_present() {
  invoke_text 'specific task' run
  assert_status 0 "$LAST_STATUS" "Fixed flags run"
  load_call_args 1
  for fixed in --project --skip-update-check --output-format json \
    --skill-default-locations=false --command-default-location=false \
    --agent-default-location=false --mcp-default-locations=false \
    --config-default-locations=false --share-anonymous-statistics=false \
    --json-output-file --model; do
    assert_arg "$fixed" "Fixed flag present: $fixed"
  done
}

test_task_on_stdin_not_argv() {
  invoke_text 'my secret task' run
  assert_status 0 "$LAST_STATUS" "Task on stdin"
  # The task text should be in the stdin file, not in argv
  local stdin_content
  stdin_content=$(cat "$FAKE_JUNIE_CALLS/1.stdin")
  assert_contains "$stdin_content" 'my secret task' "Task in stdin"
  assert_contains "$stdin_content" 'Constraints:' "Constraints suffix in stdin"
}

test_default_model_junie_lite() {
  invoke_text 'task' run
  assert_status 0 "$LAST_STATUS" "Default model"
  load_call_args 1
  assert_equal "junie-lite" "$(arg_value --model)" "Default model is junie-lite"
  assert_no_arg --effort "No --effort with junie-lite"
}

test_model_with_effort() {
  invoke_text 'task' run --model gemini-3.7-flash --effort high
  assert_status 0 "$LAST_STATUS" "Model with effort"
  load_call_args 1
  assert_equal "gemini-3.7-flash" "$(arg_value --model)" "Model value"
  assert_equal "high" "$(arg_value --effort)" "Effort value"
}

test_junie_lite_no_effort() {
  invoke_text 'task' run --model junie-lite --effort high
  assert_status 0 "$LAST_STATUS" "Junie-lite ignores effort"
  load_call_args 1
  assert_equal "junie-lite" "$(arg_value --model)" "Model is junie-lite"
  assert_no_arg --effort "No --effort for junie-lite"
}

test_invalid_model_slug() {
  invoke_text 'task' run --model 'bad model!'
  assert_status 64 "$LAST_STATUS" "Invalid model slug"
  assert_contains "$LAST_OUTPUT" 'invalid model slug' "Slug error message"
}

test_invalid_effort() {
  invoke_text 'task' run --model gemini-3.7-flash --effort extreme
  assert_status 64 "$LAST_STATUS" "Invalid effort"
  assert_contains "$LAST_OUTPUT" 'invalid effort' "Effort error message"
}

test_skills_valid() {
  mkdir -p "$HOME/skills/skill1" "$HOME/skills/skill2"
  export JUNIE_RESCUE_SKILLS="$HOME/skills/skill1;$HOME/skills/skill2"
  invoke_text 'task' run
  assert_status 0 "$LAST_STATUS" "Valid skills run"
  load_call_args 1
  assert_arg --skill-location "Skill location flag"
  assert_arg "$HOME/skills/skill1" "Skill1 path"
  assert_arg "$HOME/skills/skill2" "Skill2 path"
}

test_skills_invalid() {
  export JUNIE_RESCUE_SKILLS="$HOME/skills/nonexistent"
  invoke_text 'task' run
  assert_status 1 "$LAST_STATUS" "Invalid skill dir"
  assert_contains "$LAST_OUTPUT" 'skill location not found' "Skill error"
}

test_cwd_workspace() {
  mkdir -p "$HOME/other-repo"
  (
    cd "$HOME/other-repo" || exit 1
    git init -q &&
      printf '%s\n' 'other workspace' >README.md &&
      git add README.md &&
      git commit -q -m initial
  ) || exit 1
  invoke_text 'task' run -C "$HOME/other-repo"
  assert_status 0 "$LAST_STATUS" "-C run"
  load_call_args 1
  local expected_workspace
  expected_workspace=$(cd "$HOME/other-repo" && pwd -P)
  if command -v cygpath >/dev/null 2>&1; then expected_workspace=$(cygpath -w "$expected_workspace"); fi
  assert_equal "$expected_workspace" "$(arg_value --project)" "-C project argument"
}

test_read_only_worktree() {
  export FAKE_JUNIE_MODE=edit-file
  invoke_text 'review this' run --read-only
  assert_status 0 "$LAST_STATUS" "Read-only run"
  # The original repo should be untouched
  assert_not_contains "$(git -C "$HOME/repo" status --porcelain)" 'junie-edited' "Original repo untouched"
  # Stdin should have read-only constraints
  local stdin_content
  stdin_content=$(cat "$FAKE_JUNIE_CALLS/1.stdin")
  assert_contains "$stdin_content" 'read-only run' "Read-only constraints"
}

test_noauth_error() {
  export FAKE_JUNIE_MODE=noauth
  invoke_text 'task' run
  assert_status 70 "$LAST_STATUS" "Noauth exit code"
  assert_contains "$LAST_OUTPUT" 'sign-in missing' "Noauth message"
}

test_quota_error() {
  export FAKE_JUNIE_MODE=quota
  invoke_text 'task' run
  assert_status 69 "$LAST_STATUS" "Quota exit code"
  assert_contains "$LAST_OUTPUT" 'quota or credit limit' "Quota message"
}

test_quota_words_in_a_successful_run() {
  export FAKE_JUNIE_MODE=quota-words
  invoke_text 'task' run
  assert_status 0 "$LAST_STATUS" "Successful run that mentions quotas"
  assert_not_contains "$LAST_OUTPUT" 'quota or credit limit' "No false quota signal"
}

test_json_errors() {
  export FAKE_JUNIE_MODE=json-errors
  invoke_text 'task' run --model gemini-3.7-flash
  assert_status 1 "$LAST_STATUS" "JSON errors exit code"
  assert_contains "$LAST_OUTPUT" 'Lite-only access' "JSON error printed"
  assert_contains "$LAST_OUTPUT" 'free Junie Lite plan' "Lite plan hint"
}

test_detached_read_only_removes_worktree() {
  export FAKE_JUNIE_MODE=edit-file
  start_job --read-only
  invoke_args wait "$JOB_ID"
  assert_status 0 "$LAST_STATUS" "Detached read-only job"
  assert_contains "$LAST_OUTPUT" 'edits it attempted were discarded' "Discard report"
  assert_equal 1 "$(git -C "$HOME/repo" worktree list | wc -l | tr -d ' ')" "Throwaway worktree removed"
  assert_not_contains "$(git -C "$HOME/repo" status --porcelain)" 'junie-edited' "Original repo untouched"
}

test_detached_quota_keeps_its_exit_code() {
  export FAKE_JUNIE_MODE=quota
  start_job
  invoke_args wait "$JOB_ID"
  assert_status 69 "$LAST_STATUS" "Detached quota exit code"
  invoke_args wait "$JOB_ID"
  assert_status 69 "$LAST_STATUS" "Second wait repeats the quota exit code"
}

test_nojson_error() {
  export FAKE_JUNIE_MODE=nojson
  invoke_text 'task' run
  assert_status 1 "$LAST_STATUS" "No-json exit code"
  assert_contains "$LAST_OUTPUT" 'no result JSON' "No-json message"
}

test_result_summary() {
  invoke_text 'task' run
  assert_status 0 "$LAST_STATUS" "Result summary"
  assert_contains "$LAST_OUTPUT" 'STATUS: DONE' "Result text"
  assert_contains "$LAST_OUTPUT" 'usage:' "Usage line"
  assert_contains "$LAST_OUTPUT" 'session session-test-' "Session id"
}

test_ansi_stripped() {
  invoke_text 'task' run
  assert_status 0 "$LAST_STATUS" "ANSI stripped"
  assert_not_contains "$LAST_OUTPUT" '\033[' "ANSI codes removed"
}

test_edit_file_mode() {
  export FAKE_JUNIE_MODE=edit-file
  invoke_text 'edit a file' run
  assert_status 0 "$LAST_STATUS" "Edit-file run"
  # The file should exist in the workspace
  [ -f "$HOME/repo/junie-edited.txt" ] || fail "Edited file not created"
}

test_empty_task() {
  invoke_text '   ' run
  assert_status 64 "$LAST_STATUS" "Empty task"
  assert_contains "$LAST_OUTPUT" 'no task on stdin' "Empty task message"
}

test_unknown_option() {
  invoke_text 'task' run --unknown
  assert_status 64 "$LAST_STATUS" "Unknown option"
  assert_contains "$LAST_OUTPUT" 'unknown option' "Unknown option message"
}

# ---- Detached job tests ----

await_file() {
  local attempt=0
  while [ ! -f "$1" ] && [ "$attempt" -lt 100 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  [ -f "$1" ] || fail "Fake launcher did not create $1"
}

start_job() {
  invoke_text 'detached task' start "$@"
  assert_status 0 "$LAST_STATUS" "Detached start"
  JOB_ID=$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^\[junie-rescue\] started job //p')
  [ -n "$JOB_ID" ] || fail "Start returned no job id"
  JOB_DIR="$JUNIE_RESCUE_HOME/jobs/$JOB_ID"
}

assert_child_stopped() {
  local child_pid attempt=0
  child_pid=$(cat "$FAKE_JUNIE_CHILD_PID_FILE")
  while kill -0 "$child_pid" 2>/dev/null && [ "$attempt" -lt 30 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  kill -0 "$child_pid" 2>/dev/null && fail "Child process $child_pid survived termination" || :
}

test_start_metadata() {
  export FAKE_JUNIE_MODE=sleep FAKE_JUNIE_SLEEP=30
  start_job --model gemini-3.7-flash --effort high --read-only
  assert_not_contains "$LAST_OUTPUT" 'exit' "Start returns before completion"
  for file in pid workspace started deadline git-before task; do
    [ -s "$JOB_DIR/$file" ] || fail "Missing job metadata $file"
  done
  [ ! -e "$JOB_DIR/exit" ] || fail "Start waited for sleeping job"
  assert_equal 2700 "$(( $(cat "$JOB_DIR/deadline") - $(cat "$JOB_DIR/started") ))" "Default job deadline"
  await_file "$FAKE_JUNIE_CALLS/1.env"
  load_call_args 1
  assert_arg --skip-update-check "Detached fixed flag"
  assert_equal gemini-3.7-flash "$(arg_value --model)" "Detached model"
  assert_equal high "$(arg_value --effort)" "Detached effort"
  invoke_args cancel "$JOB_ID"
  assert_status 130 "$LAST_STATUS" "Metadata job cleanup"
}

test_start_cwd() {
  mkdir -p "$HOME/other-repo"
  (
    cd "$HOME/other-repo" || exit 1
    git init -q &&
      printf '%s\n' 'other workspace' >README.md &&
      git add README.md &&
      git commit -q -m initial
  ) || exit 1
  start_job -C "$HOME/other-repo"
  expected_workspace=$(cd "$HOME/other-repo" && pwd -P)
  if command -v cygpath >/dev/null 2>&1; then expected_workspace=$(cygpath -w "$expected_workspace"); fi
  assert_equal "$expected_workspace" "$(cat "$JOB_DIR/workspace")" "Detached -C workspace metadata"
  invoke_args wait "$JOB_ID" --slice 10
  assert_status 0 "$LAST_STATUS" "Detached -C completion"
}

test_wait_deadline() {
  export FAKE_JUNIE_MODE=sleep FAKE_JUNIE_SLEEP=30 JUNIE_RESCUE_MAX_SECONDS=2
  export FAKE_JUNIE_CHILD_PID_FILE="$HOME/child.pid"
  start_job
  assert_equal 2 "$(( $(cat "$JOB_DIR/deadline") - $(cat "$JOB_DIR/started") ))" "Configured deadline"
  await_file "$FAKE_JUNIE_CHILD_PID_FILE"
  invoke_args wait "$JOB_ID" --slice 10
  assert_status 124 "$LAST_STATUS" "Detached deadline"
  assert_contains "$LAST_OUTPUT" 'timed out after 2s' "Deadline notice"
  assert_child_stopped
}

test_cancel() {
  export FAKE_JUNIE_MODE=sleep FAKE_JUNIE_SLEEP=30
  export FAKE_JUNIE_CHILD_PID_FILE="$HOME/child.pid"
  start_job
  await_file "$FAKE_JUNIE_CHILD_PID_FILE"
  invoke_args cancel "$JOB_ID"
  assert_status 130 "$LAST_STATUS" "Detached cancel"
  assert_contains "$LAST_OUTPUT" '[junie-rescue] exit 130' "Cancelled exit"
  assert_child_stopped
}

test_windows_cancel_tree() {
  export JUNIE_RESCUE_FORCE_WINDOWS=1 JUNIE_RESCUE_KILL="$HOME/bin/fake-kill"
  export FAKE_JUNIE_MODE=sleep FAKE_JUNIE_SLEEP=30 FAKE_JUNIE_CHILD_PID_FILE="$HOME/child.pid"
  start_job
  await_file "$FAKE_JUNIE_CHILD_PID_FILE"
  invoke_args cancel "$JOB_ID"
  assert_status 130 "$LAST_STATUS" "Windows cancel"
  assert_child_stopped
}

test_windows_deadline_tree() {
  export JUNIE_RESCUE_FORCE_WINDOWS=1 JUNIE_RESCUE_KILL="$HOME/bin/fake-kill"
  export FAKE_JUNIE_MODE=sleep FAKE_JUNIE_SLEEP=30 FAKE_JUNIE_CHILD_PID_FILE="$HOME/child.pid"
  export JUNIE_RESCUE_MAX_SECONDS=2
  start_job
  await_file "$FAKE_JUNIE_CHILD_PID_FILE"
  invoke_args wait "$JOB_ID" --slice 10
  assert_status 124 "$LAST_STATUS" "Windows deadline"
  assert_child_stopped
}

test_detached_invalid_arguments() {
  for command in wait cancel; do
    invoke_args "$command" unknown-job
    assert_status 64 "$LAST_STATUS" "Unknown $command id"
    invoke_args "$command"
    assert_status 64 "$LAST_STATUS" "Missing $command id"
    invoke_args "$command" ../escape
    assert_status 64 "$LAST_STATUS" "Unsafe $command id"
  done
  invoke_text 'task' start --model 'bad model!'
  assert_status 64 "$LAST_STATUS" "Detached invalid model"
  invoke_text 'task' start --unknown
  assert_status 64 "$LAST_STATUS" "Detached unknown option"
  for seconds in 0 invalid -1; do
    export JUNIE_RESCUE_MAX_SECONDS=$seconds
    invoke_text 'task' start
    assert_status 64 "$LAST_STATUS" "Invalid deadline $seconds"
  done
  unset JUNIE_RESCUE_MAX_SECONDS
}

test_manifests() {
  plugin_version=$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$ROOT/.claude-plugin/plugin.json" | head -n 1)
  marketplace_versions=$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$ROOT/.claude-plugin/marketplace.json")
  changelog_version=$(sed -n 's/^## \([^ ]*\).*/\1/p' "$ROOT/CHANGELOG.md" | head -n 1)
  assert_equal 0.1.0 "$plugin_version" "Plugin version"
  assert_equal "$plugin_version" "$changelog_version" "Changelog version"
  assert_equal "$plugin_version" "$(printf '%s\n' "$marketplace_versions" | sed -n '1p')" "Marketplace metadata version"
  assert_equal "$plugin_version" "$(printf '%s\n' "$marketplace_versions" | sed -n '2p')" "Marketplace plugin version"
}

# ---- Run all tests ----

run_case() {
  local name=$1 function=$2
  if [ -n "$FILTER" ] && [ "$FILTER" != "$name" ] && [ "$FILTER" != "$function" ]; then return; fi
  RUN_COUNT=$((RUN_COUNT + 1))
  TOTAL=$((TOTAL + 1))
  TEST_FAILED=0
  new_sandbox
  "$function"
  if [ "$TEST_FAILED" -eq 0 ]; then printf 'PASS %s\n' "$name"
  else printf 'FAIL %s\n' "$name"; FAILED=$((FAILED + 1)); fi
  rm -rf "$SANDBOX"
}

run_case preflight-auth-dpapi test_preflight_auth_dpapi
run_case preflight-api-key test_preflight_api_key
run_case preflight-no-auth test_preflight_no_auth
run_case preflight-model test_preflight_model
run_case node-missing test_node_missing
run_case preflight-cwd-home-refused test_preflight_cwd_home_refused
run_case preflight-cwd-missing test_preflight_cwd_missing
run_case preflight-cwd-no-value test_preflight_cwd_no_value
run_case fixed-flags test_fixed_flags_present
run_case task-on-stdin test_task_on_stdin_not_argv
run_case default-model test_default_model_junie_lite
run_case model-with-effort test_model_with_effort
run_case junie-lite-no-effort test_junie_lite_no_effort
run_case invalid-model test_invalid_model_slug
run_case invalid-effort test_invalid_effort
run_case skills-valid test_skills_valid
run_case skills-invalid test_skills_invalid
run_case cwd-workspace test_cwd_workspace
run_case read-only-worktree test_read_only_worktree
run_case noauth-error test_noauth_error
run_case quota-error test_quota_error
run_case quota-words-ok test_quota_words_in_a_successful_run
run_case json-errors test_json_errors
run_case detached-read-only-cleanup test_detached_read_only_removes_worktree
run_case detached-quota-exit test_detached_quota_keeps_its_exit_code
run_case nojson-error test_nojson_error
run_case result-summary test_result_summary
run_case ansi-stripped test_ansi_stripped
run_case edit-file test_edit_file_mode
run_case empty-task test_empty_task
run_case unknown-option test_unknown_option
run_case start-metadata test_start_metadata
run_case start-cwd test_start_cwd
run_case wait-deadline test_wait_deadline
run_case cancel test_cancel
run_case windows-cancel-tree test_windows_cancel_tree
run_case windows-deadline-tree test_windows_deadline_tree
run_case detached-invalid-args test_detached_invalid_arguments
run_case manifests test_manifests

[ "$RUN_COUNT" -gt 0 ] || printf 'FAIL no test matched filter: %s\n' "$FILTER"
printf '%s/%s tests passed\n' "$((TOTAL - FAILED))" "$TOTAL"
[ "$RUN_COUNT" -gt 0 ] && [ "$FAILED" -eq 0 ]
