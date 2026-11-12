#!/usr/bin/env bash
set -u

readonly USAGE_EXIT=64
readonly PREFLIGHT_FAILED_EXIT=70
# 75 is taken: wait returns it while a job is still running
readonly QUOTA_EXIT=69
readonly NOT_FOUND_EXIT=127
readonly AI_CLIS="claude, codex, copilot, agy, gemini, ollama, cursor-agent, muse, junie"
readonly CONSTRAINTS="Constraints: work directly in this workspace following the instructions above. Do not invoke other AI CLIs ($AI_CLIS). Do not commit, push, reset, checkout, clean, switch branches or delete files. If a command is denied by policy, stop and report it — do not look for another way to run it. Leave your changes in the working tree and end with a short list of the files you touched. Then finish with one final line: STATUS: DONE, or STATUS: DONE_WITH_CONCERNS: <risks to review>, or STATUS: NEEDS_CONTEXT: <the exact question> (information is missing — do not guess), or STATUS: BLOCKED: <reason> (you cannot proceed)."
readonly READ_ONLY_CONSTRAINTS="Constraints: this is a read-only run: do not edit files or run shell commands; report findings and proposed changes as text. Do not invoke other AI CLIs ($AI_CLIS)."
readonly SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
readonly RESCUE_HOME=$(rescue_home=${JUNIE_RESCUE_HOME:-$HOME/.junie-rescue};
  if command -v cygpath >/dev/null 2>&1; then cygpath -au "$rescue_home";
  elif [[ $rescue_home = /* ]]; then printf '%s' "$rescue_home";
  else printf '%s/%s' "$PWD" "$rescue_home"; fi)

OPT_MODEL=""
OPT_EFFORT=""
OPT_READ_ONLY=0
OPT_CWD=""
JUNIE_BIN_RESOLVED=""
RUN_TASK_FILE=""
RUN_STDERR_FILE=""
RUN_JSON_FILE=""

# Read-only worktree state
READ_ONLY_SRC=""
READ_ONLY_REL=""
READ_ONLY_SNAP=""
READ_ONLY_RO=""

usage_error() {
  printf '[junie-rescue] %s\n' "$1" >&2
  exit "$USAGE_EXIT"
}

validate_model() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] ||
    usage_error "invalid model slug: $1"
}

parse_options() {
  while [ $# -gt 0 ]; do
    case $1 in
      --model)
        [ $# -ge 2 ] || usage_error "--model needs a value"
        validate_model "$2"
        OPT_MODEL=$2
        shift 2
        ;;
      --effort)
        [ $# -ge 2 ] || usage_error "--effort needs a value"
        case $2 in
          low|medium|high) OPT_EFFORT=$2 ;;
          *) usage_error "invalid effort: $2" ;;
        esac
        shift 2
        ;;
      --read-only) OPT_READ_ONLY=1; shift ;;
      -C|--cwd)
        [ $# -ge 2 ] || usage_error "-C needs a directory"
        OPT_CWD=$2
        shift 2
        ;;
      *) usage_error "unknown option: $1" ;;
    esac
  done
}

native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s' "$1"
  fi
}

fold_path() {
  local path=$1
  if command -v cygpath >/dev/null 2>&1; then path=$(cygpath -m "$path"); fi
  path=$(printf '%s' "$path" | tr '\\' '/')
  while [ "${#path}" -gt 1 ] && [ "${path%/}" != "$path" ]; do path=${path%/}; done
  case $(uname -s 2>/dev/null || :) in
    MINGW*|MSYS*|CYGWIN*) path=$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]') ;;
  esac
  printf '%s' "$path"
}

path_at_or_under() {
  [ "$1" = "$2" ] && return 0
  case $2 in
    /) case $1 in /*) return 0 ;; *) return 1 ;; esac ;;
    *) case $1 in "$2"/*) return 0 ;; *) return 1 ;; esac ;;
  esac
}

enter_workspace() {
  local dir=$OPT_CWD resolved home physical_home folded folded_home candidate
  [ -n "$dir" ] || return 0
  resolved=$(cd -- "$dir" 2>/dev/null && pwd -P) || usage_error "-C directory not found: $dir"
  [ -n "$resolved" ] || usage_error "-C directory not found: $dir"
  home=${HOME:-}
  [ -n "$home" ] || usage_error "refused -C $dir: not permitted"
  physical_home=$(cd -- "$home" 2>/dev/null && pwd -P) || physical_home=$home
  folded=$(fold_path "$resolved")
  folded_home=$(fold_path "$physical_home")
  path_at_or_under "$folded_home" "$folded" && usage_error "refused -C $dir: not permitted"
  for candidate in .claude .codex .copilot .gemini .ssh .config .junie-rescue .dsh .junie; do
    path_at_or_under "$folded" "$(fold_path "$physical_home/$candidate")" &&
      usage_error "refused -C $dir: not permitted"
  done
  cd -- "$resolved" || usage_error "-C directory not found: $dir"
}

# Resolve Junie binary: JUNIE_BIN override, then JUNIE_DATA_DIR/versions/<current>/junie[junie.exe], then junie on PATH
find_junie() {
  if [ -n "${JUNIE_BIN:-}" ]; then
    JUNIE_BIN_RESOLVED=$JUNIE_BIN
    [ -f "$JUNIE_BIN_RESOLVED" ] && return 0
    return 1
  fi

  local data_dir version bin_path uname_s
  data_dir="${JUNIE_DATA_DIR:-}"
  if [ -z "$data_dir" ]; then
    data_dir="$HOME/.local/share/junie"
  fi

  # Read current version file
  if [ -r "$data_dir/current" ]; then
    IFS= read -r version <"$data_dir/current" || :
    version=${version%$'\r'}
    # Validate version format
    if [[ $version =~ ^[0-9][0-9.]{0,31}$ ]]; then
      uname_s=$(uname -s 2>/dev/null || :)
      case $uname_s in
        MINGW*|MSYS*|CYGWIN*)
          bin_path="$data_dir/versions/$version/junie/junie.exe"
          ;;
        *)
          bin_path="$data_dir/versions/$version/junie/junie"
          ;;
      esac
      if [ -f "$bin_path" ]; then
        JUNIE_BIN_RESOLVED=$bin_path
        return 0
      fi
    fi
  fi

  # Fallback: junie on PATH (Linux/macOS)
  uname_s=$(uname -s 2>/dev/null || :)
  case $uname_s in
    MINGW*|MSYS*|CYGWIN*) return 1 ;;
  esac
  if command -v junie >/dev/null 2>&1; then
    JUNIE_BIN_RESOLVED=$(command -v junie)
    return 0
  fi
  return 1
}

require_junie() {
  find_junie && return 0
  printf '[junie-rescue] junie not found — install JetBrains Junie or set JUNIE_BIN, then run /junie:setup\n' >&2
  return "$NOT_FOUND_EXIT"
}

require_node() {
  command -v node >/dev/null 2>&1 && return 0
  printf '[junie-rescue] node is required on PATH for JSON result parsing\n' >&2
  return "$NOT_FOUND_EXIT"
}

# Auth: JUNIE_API_KEY with a value, or any *.dpapi file in <home>/dpapi_credentials/
# <home> = $JUNIE_HOME or ~/.junie
auth_present() {
  [ -n "${JUNIE_API_KEY:-}" ] && return 0
  local junie_home
  junie_home="${JUNIE_HOME:-$HOME/.junie}"
  # Check for dpapi credentials without reading them
  if [ -d "$junie_home/dpapi_credentials" ]; then
    local found=0
    for f in "$junie_home/dpapi_credentials"/*.dpapi; do
      [ -e "$f" ] && { found=1; break; }
    done
    [ "$found" -eq 1 ] && return 0
  fi
  return 1
}

preflight() {
  require_junie || return $?
  if ! auth_present; then
    printf '[junie-rescue] no Junie credentials — run "junie" once in a normal terminal to sign in, or set JUNIE_API_KEY\n' >&2
    return "$PREFLIGHT_FAILED_EXIT"
  fi
  local version
  # stderr carries the log-file banner; stdout says "Junie version: <v>"
  version=$("$JUNIE_BIN_RESOLVED" --version 2>/dev/null | sed -n 's/^Junie version: //p' | head -1)
  [ -n "$version" ] || version=$("$JUNIE_BIN_RESOLVED" --version 2>/dev/null | head -1)
  [ -n "$version" ] || version="unknown"
  printf '[junie-rescue] preflight: junie %s, authentication ready\n' "${version}"
  [ -n "$OPT_MODEL" ] && printf 'model: %s\n' "$OPT_MODEL"
  return 0
}

git_state() {
  local head branch stash config hooks git_dir common_dir hooks_dir
  git_dir=$(git rev-parse --path-format=absolute --git-dir 2>/dev/null) || return 1
  common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  hooks_dir=$(git rev-parse --path-format=absolute --git-path hooks 2>/dev/null) || return 1
  head=$(git rev-parse -q --verify HEAD 2>/dev/null || printf none)
  branch=$(git symbolic-ref -q --short HEAD 2>/dev/null || printf detached)
  stash=$(git rev-list --walk-reflogs --count refs/stash -- 2>/dev/null || printf 0)
  config=$(cksum "$common_dir/config" "$git_dir/config.worktree" 2>/dev/null | cksum | awk '{print $1 ":" $2}')
  [ -n "$config" ] || config=none
  hooks=$(find "$hooks_dir" -type f -exec cksum {} + 2>/dev/null | LC_ALL=C sort | cksum | awk '{print $1 ":" $2}')
  [ -n "$hooks" ] || hooks=none
  printf 'HEAD\t%s\nbranch\t%s\nstash\t%s\nconfig\t%s\nhooks\t%s\n' "$head" "$branch" "$stash" "$config" "$hooks"
}

warn_git_changes() {
  local before=$1 after key old new
  [ -n "$before" ] || return 0
  after=$(git_state) || {
    printf '[junie-rescue] WARNING: git repository state is no longer readable — review before your next git command\n'
    return 0
  }
  while IFS=$'\t' read -r key old; do
    new=$(printf '%s\n' "$after" | awk -F '\t' -v k="$key" '$1 == k {print $2}')
    [ "$old" = "$new" ] && continue
    printf '[junie-rescue] WARNING: %s changed — review before your next git command\n' "$key"
  done <<<"$before"
}

is_windows() {
  case "${JUNIE_RESCUE_FORCE_WINDOWS:-0}:$(uname -s 2>/dev/null || :)" in
    1:*|*:MINGW*|*:MSYS*|*:CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

invoke_taskkill() {
  local pid=$1 taskkill_bin
  if [ -n "${JUNIE_RESCUE_KILL:-}" ]; then
    MSYS_NO_PATHCONV=1 "$JUNIE_RESCUE_KILL" /T /F /PID "$pid"
    return $?
  fi
  taskkill_bin=$(command -v taskkill) ||
    taskkill_bin=$(cygpath -u "${SYSTEMROOT:-${WINDIR:-C:/Windows}}/System32/taskkill.exe") || return 1
  "$taskkill_bin" //T //F //PID "$pid"
}

positive_seconds() {
  [[ $2 =~ ^[0-9]{1,8}$ ]] || usage_error "$1 needs positive integer seconds"
  [ "$((10#$2))" -gt 0 ] || usage_error "$1 needs positive integer seconds"
}

read_task() {
  local task
  task=$(cat)
  [ -n "${task//[[:space:]]/}" ] || usage_error "no task on stdin"
  printf '%s' "$task"
}

# Strip ANSI escape codes from text
strip_ansi() {
  sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\([0-9;]*[a-zA-Z]\)//g'
}

# Parse Junie JSON result and print summary
print_result_summary() {
  local json_file=$1
  [ -r "$json_file" ] || return 1

  # Extract result, sessionId, llmUsage, changes using node
  node -e '
    const fs = require("fs");
    try {
      const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      
      // Print result field
      if (data.result) {
        console.log(data.result);
      }

      for (const error of data.errors || []) {
        console.log("[junie-rescue] error: " + error);
      }
      
      // Print usage summary
      if (data.llmUsage && Array.isArray(data.llmUsage)) {
        let totalCost = 0;
        let totalInput = 0;
        let totalOutput = 0;
        let models = [];
        for (const u of data.llmUsage) {
          totalCost += (u.cost || 0);
          totalInput += (u.inputTokens || 0);
          totalOutput += (u.outputTokens || 0);
          if (u.model) models.push(u.model + " calls=" + (u.calls || 0));
        }
        if (models.length > 0) {
          console.log("[junie-rescue] usage: " + models.join(", ") + " cost=" + totalCost.toFixed(6) + " input=" + totalInput + " output=" + totalOutput);
        }
      }
      
      // Print session id
      if (data.sessionId) {
        console.log("[junie-rescue] session " + data.sessionId);
      }
      
      // Print changes summary
      if (data.changes && Array.isArray(data.changes) && data.changes.length > 0) {
        const paths = data.changes.map(c => c.afterRelativePath || c.afterAbsolutePath || "?");
        console.log("[junie-rescue] changed " + paths.length + " file(s): " + paths.join(", "));
      }
    } catch (e) {
      console.error("[junie-rescue] could not parse result JSON: " + e.message);
      process.exit(1);
    }
  ' "$json_file"
}

# Classify the output of a run that already failed; never call it on a successful transcript
check_errors() {
  local output=$1
  case "$output" in
    *"Cannot find authorization"*|*"Please authenticate"*)
      printf '[junie-rescue] Junie sign-in missing: run "junie" once in a terminal to sign in, or set JUNIE_API_KEY\n'
      return "$PREFLIGHT_FAILED_EXIT"
      ;;
  esac
  local lower_output
  lower_output=$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')
  case "$lower_output" in
    *"lite-only access"*)
      printf '[junie-rescue] model not available on the free Junie Lite plan: use --model junie-lite\n'
      return 1
      ;;
    *quota*|*credit*|*rate\ limit*|*429*|*too\ many\ requests*|*insufficient*)
      printf '[junie-rescue] Junie quota or credit limit hit\n'
      return "$QUOTA_EXIT"
      ;;
  esac
  return 0
}

json_errors() {
  [ -r "$1" ] || return 0
  node -e 'try { const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); for (const e of d.errors || []) console.log(String(e)); } catch (e) {}' "$1"
}

run_failed() {
  local rc=$1 json=$2
  [ "$rc" -ne 0 ] || [ ! -r "$json" ] || [ -n "$(json_errors "$json")" ]
}

# Exit code of a failed run: sign-in and quota signals first, then Junie's own code, never 0
failure_exit() {
  local rc=$1 json=$2 out=$3 err=$4 code
  check_errors "$(json_errors "$json"; cat "$out" "$err" 2>/dev/null)"
  code=$?
  [ "$code" -eq 0 ] || return "$code"
  [ -r "$json" ] || printf '[junie-rescue] Junie produced no result JSON — the task may not have completed\n'
  [ "$rc" -eq 0 ] && return 1
  return "$rc"
}

# Detached read-only jobs keep the worktree paths in the job dir: the process that created them is gone
discard_job_worktree() {
  local job=$1
  [ -f "$job/ro-path" ] || return 0
  READ_ONLY_SRC=$(cat "$job/ro-src")
  READ_ONLY_RO=$(cat "$job/ro-path")
  printf '[junie-rescue] read-only run in a throwaway worktree of %s; edits it attempted were discarded:\n' "$(cat "$job/ro-snap")"
  git -C "$READ_ONLY_RO" status --short || :
  ( remove_read_only_worktree 2>/dev/null ) || printf '[junie-rescue] could not remove the throwaway worktree %s\n' "$READ_ONLY_RO" >&2
  rm -f "$job/ro-path"
}

# Read-only worktree functions (adapted from agy-forward.sh)
create_read_only_worktree() {
  READ_ONLY_REL=$(git rev-parse --show-prefix)
  # git stash create snapshots staged and unstaged changes to tracked files without touching the caller's tree or stash list.
  READ_ONLY_SNAP=$(git stash create 2>/dev/null)
  READ_ONLY_RO="$(mktemp -d)/ro"
  git -C "$READ_ONLY_SRC" worktree add --detach -q "$READ_ONLY_RO" "${READ_ONLY_SNAP:-HEAD}" || {
    rmdir "$(dirname "$READ_ONLY_RO")" 2>/dev/null || :
    printf '[junie-rescue] could not create the throwaway worktree\n'
    return 1
  }
  cd "$READ_ONLY_RO/$READ_ONLY_REL" || {
    cd "$READ_ONLY_SRC" || :
    git -C "$READ_ONLY_SRC" worktree remove --force "$READ_ONLY_RO" || :
    rmdir "$(dirname "$READ_ONLY_RO")" 2>/dev/null || :
    return 1
  }
}

remove_read_only_worktree() {
  local link rc
  cd "$READ_ONLY_SRC" || return 1
  # Links are unlinked first because removing a worktree that holds a Windows junction can delete the junction's target.
  find "$READ_ONLY_RO" -type l 2>/dev/null | while IFS= read -r link; do
    cmd //c rmdir "$(cygpath -w "$link")" 2>/dev/null || rm -f "$link"
  done
  git -C "$READ_ONLY_SRC" worktree remove --force "$READ_ONLY_RO"
  rc=$?
  rmdir "$(dirname "$READ_ONLY_RO")" 2>/dev/null || :
  return "$rc"
}

junie_env() {
  export GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes'
  unset MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL
}

# Build the Junie command arguments
build_junie_args() {
  local task_file=$1 job_dir=$2 project_dir=$3
  local json_file="$job_dir/result.json"
  local args=()

  args+=(--project "$(native_path "$project_dir")")
  args+=(--skip-update-check)
  args+=(--output-format json)
  args+=(--skill-default-locations=false)
  args+=(--command-default-location=false)
  args+=(--agent-default-location=false)
  args+=(--mcp-default-locations=false)
  args+=(--config-default-locations=false)
  args+=(--share-anonymous-statistics=false)
  args+=(--json-output-file "$(native_path "$json_file")")

  # Model
  local model="${OPT_MODEL:-junie-lite}"
  args+=(--model "$model")

  # Effort (only for non-junie-lite models)
  if [ "$model" != "junie-lite" ] && [ -n "$OPT_EFFORT" ]; then
    args+=(--effort "$OPT_EFFORT")
  fi

  # Skills
  if [ -n "${JUNIE_RESCUE_SKILLS:-}" ]; then
    local IFS=';'
    local skill_dir
    for skill_dir in $JUNIE_RESCUE_SKILLS; do
      if [ -d "$skill_dir" ]; then
        args+=(--skill-location "$skill_dir")
      else
        printf '[junie-rescue] skill location not found: %s\n' "$skill_dir" >&2
        return 1
      fi
    done
  fi

  # Write args to file for job persistence
  printf '%s\0' "${args[@]}" >"$job_dir/argv"
  printf '%s' "$model" >"$job_dir/model"
  return 0
}

# Write task to stdin file
write_task_file() {
  local task=$1 task_file=$2
  local constraints=$CONSTRAINTS
  [ "$OPT_READ_ONLY" -eq 1 ] && constraints=$READ_ONLY_CONSTRAINTS
  printf '%s\n\n%s' "$task" "$constraints" >"$task_file"
}

prepare_run() {
  require_node || return $?
  require_junie || return $?
  if ! auth_present; then
    printf '[junie-rescue] no Junie credentials — run "junie" once in a normal terminal to sign in, or set JUNIE_API_KEY\n' >&2
    return "$PREFLIGHT_FAILED_EXIT"
  fi
}

# Kill tree functions
windows_pid() {
  ps -p "$1" -l 2>/dev/null | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "WINPID") column = i; next } column { print $column; exit }'
}

kill_descendants() {
  local pid=$1 child children
  children=$(ps -e -o pid=,ppid= 2>/dev/null | awk -v parent="$pid" '$2 == parent { print $1 }')
  for child in $children; do kill_descendants "$child"; done
  kill -KILL "$pid" 2>/dev/null || :
}

kill_windows_tree() {
  local pid=$1 children child native_pid
  children=$(ps -e | awk -v parent="$pid" 'NR > 1 && $2 == parent { print $1 }')
  for child in $children; do kill_windows_tree "$child" || return 1; done
  native_pid=$(windows_pid "$pid")
  if [ -z "$native_pid" ] && [ -n "${JUNIE_RESCUE_KILL:-}" ]; then native_pid=$pid; fi
  [ -n "$native_pid" ] || return 0
  if ! invoke_taskkill "$native_pid" >/dev/null 2>&1; then
    kill -0 "$pid" 2>/dev/null && return 1
  fi
  return 0
}

kill_tree() {
  if is_windows; then kill_windows_tree "$1"; else kill_descendants "$1"; fi
}

print_stderr() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] && printf '%s\n' "$line"
  done <"$1"
  return 0
}

# Run task directly (short path)
run_task() {
  local task args=() pid rc start end deadline seconds=${JUNIE_RESCUE_TIMEOUT:-540}
  prepare_run || return $?
  task=$(read_task) || return $?
  positive_seconds JUNIE_RESCUE_TIMEOUT "$seconds"

  local job_dir
  job_dir=$(mktemp -d) || return 1
  local task_file="$job_dir/task.txt"
  local stderr_file="$job_dir/stderr.txt"
  local stdout_file="$job_dir/stdout.txt"
  trap 'rm -rf "$job_dir"' EXIT

  # Read-only worktree setup
  local original_dir="$PWD"
  if [ "$OPT_READ_ONLY" -eq 1 ]; then
    READ_ONLY_SRC=$(git rev-parse --show-toplevel 2>/dev/null) || {
      printf '[junie-rescue] --read-only needs a git repository\n' >&2
      return "$USAGE_EXIT"
    }
    create_read_only_worktree || return $?
  fi

  write_task_file "$task" "$task_file"
  build_junie_args "$task_file" "$job_dir" "$PWD" || return $?

  # Read args from file
  while IFS= read -r -d '' item; do args+=("$item"); done <"$job_dir/argv"

  local before
  before=$(git_state 2>/dev/null || :)

  start=$(date +%s)
  deadline=$((start + 10#$seconds))

  junie_env
  "$JUNIE_BIN_RESOLVED" "${args[@]}" <"$task_file" >"$stdout_file" 2>"$stderr_file"
  rc=$?

  end=$(date +%s)

  # Print stderr (Junie log file info)
  print_stderr "$stderr_file"

  # Print stdout (transcript with ANSI stripped)
  if [ -r "$stdout_file" ]; then
    cat "$stdout_file" | strip_ansi
  fi

  local err_rc
  if run_failed "$rc" "$job_dir/result.json"; then
    [ -r "$job_dir/result.json" ] && print_result_summary "$job_dir/result.json"
    failure_exit "$rc" "$job_dir/result.json" "$stdout_file" "$stderr_file"
    err_rc=$?
    if [ "$OPT_READ_ONLY" -eq 1 ]; then
      ( remove_read_only_worktree 2>/dev/null ) || :
    fi
    printf '[junie-rescue] exit %s\n' "$err_rc"
    return "$err_rc"
  fi

  # Print result summary from JSON
  print_result_summary "$job_dir/result.json" || :

  # Git warnings
  ( warn_git_changes "$before" )

  # Read-only: show what was changed in the worktree
  if [ "$OPT_READ_ONLY" -eq 1 ]; then
    printf '[junie-rescue] read-only run in a throwaway worktree of %s; edits it attempted were discarded:\n' "${READ_ONLY_SNAP:-HEAD}"
    git -C "$READ_ONLY_RO" status --short || :
    ( remove_read_only_worktree 2>/dev/null ) || printf '[junie-rescue] could not remove the throwaway worktree\n' >&2
  fi

  printf '[junie-rescue] exit %s\n' "$rc"
  return "$rc"
}

# ---- Detached job lifecycle ----

job_path() {
  [[ $1 =~ ^[A-Za-z0-9_-]+$ ]] || usage_error "unknown job: $1"
  [ -d "$RESCUE_HOME/jobs/$1" ] || usage_error "unknown job: $1"
  printf '%s/jobs/%s' "$RESCUE_HOME" "$1"
}

detach_job() {
  local job=$1 pid
  printf '%s\n' "$JUNIE_BIN_RESOLVED" >"$job/bin"
  ( junie_env; nohup bash "$SCRIPT_DIR/junie-forward.sh" __job "$job" </dev/null >"$job/wrapper-log" 2>&1 &
    pid=$!
    printf '%s\n' "$pid" >"$job/pid"
    disown "$pid"
  )
}

run_job_wrapper() {
  local job=$1 rc
  local project_dir
  project_dir=$(cat "$job/workspace")
  cd "$project_dir" || { printf '[junie-rescue] job workspace not found\n' >&2; return 1; }

  # Restore the Junie binary from the job directory
  JUNIE_BIN_RESOLVED=$(cat "$job/bin")

  local task_file="$job/task.txt"

  # Read args
  local args=()
  while IFS= read -r -d '' item; do args+=("$item"); done <"$job/argv"

  "$JUNIE_BIN_RESOLVED" "${args[@]}" <"$task_file" >"$job/stdout" 2>"$job/stderr" &
  local pid=$!
  printf '%s\n' "$pid" >"$job/cli-pid"
  wait "$pid"
  rc=$?
  date +%s >"$job/ended"
  printf '%s\n' "$rc" >"$job/exit.tmp"
  mv "$job/exit.tmp" "$job/exit"
  return "$rc"
}

start_task() {
  local task max_seconds=${JUNIE_RESCUE_MAX_SECONDS:-2700} job id started
  task=$(read_task) || return $?
  positive_seconds JUNIE_RESCUE_MAX_SECONDS "$max_seconds"
  prepare_run || return $?

  mkdir -p "$RESCUE_HOME/jobs" || return 1
  id="$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  job="$RESCUE_HOME/jobs/$id"
  mkdir "$job" || return 1
  started=$(date +%s)

  # Read-only worktree for detached jobs
  if [ "$OPT_READ_ONLY" -eq 1 ]; then
    READ_ONLY_SRC=$(git rev-parse --show-toplevel 2>/dev/null) || {
      printf '[junie-rescue] --read-only needs a git repository\n' >&2
      return "$USAGE_EXIT"
    }
    create_read_only_worktree || return $?
    printf '%s\n' "$READ_ONLY_SRC" >"$job/ro-src"
    printf '%s\n' "$READ_ONLY_RO" >"$job/ro-path"
    printf '%s\n' "${READ_ONLY_SNAP:-HEAD}" >"$job/ro-snap"
  fi

  printf '%s\n' "$(native_path "$PWD")" >"$job/workspace"
  printf '%s\n' "$started" >"$job/started"
  printf '%s\n' "$((started + 10#$max_seconds))" >"$job/deadline"
  : >"$job/stdout"
  : >"$job/stderr"
  git_state >"$job/git-before" 2>/dev/null || :
  printf '%s' "$task" >"$job/task"

  write_task_file "$task" "$job/task.txt"
  build_junie_args "$job/task.txt" "$job" "$PWD" || return 1

  detach_job "$job" || return 1
  printf '[junie-rescue] started job %s\n' "$id"
}

finish_job() {
  local job=$1 rc elapsed
  rc=$(cat "$job/exit")
  if [ -f "$job/finished" ]; then cat "$job/summary"; return "$rc"; fi

  # Print stdout transcript (ANSI stripped)
  if [ -r "$job/stdout" ]; then
    cat "$job/stdout" | strip_ansi
  fi

  # Print stderr
  print_stderr "$job/stderr"

  # Timeouts (124) and cancels (130) keep the stopped-job report below
  if [ "$rc" != 124 ] && [ "$rc" != 130 ] && run_failed "$rc" "$job/result.json"; then
    [ -r "$job/result.json" ] && print_result_summary "$job/result.json"
    failure_exit "$rc" "$job/result.json" "$job/stdout" "$job/stderr"
    rc=$?
    discard_job_worktree "$job"
    printf '%s\n' "$rc" >"$job/exit"
    printf '[junie-rescue] exit %s\n' "$rc" | tee -a "$job/summary"
    : >"$job/finished"
    return "$rc"
  fi

  # Print result summary
  if [ -r "$job/result.json" ]; then
    print_result_summary "$job/result.json"
  fi

  elapsed=$(($(cat "$job/ended") - $(cat "$job/started")))

  # Timeout message
  if [ -f "$job/stopped" ]; then
    printf '[junie-rescue] timed out after %ss — edits made until then are in the working tree\n' \
      "$(($(cat "$job/deadline") - $(cat "$job/started")))"
  fi

  # Git warnings
  (
    local workspace
    workspace=$(cat "$job/workspace")
    cd "$workspace" || {
      printf '[junie-rescue] WARNING: job workspace is no longer readable — review before your next git command\n'
      return 0
    }
    warn_git_changes "$(cat "$job/git-before")"
  )
  discard_job_worktree "$job"

  printf '[junie-rescue] exit %s\n' "$rc" | tee -a "$job/summary"

  # Clean up temp files
  rm -f "$job/task.txt" "$job/argv" "$job/model" "$job/stdout" "$job/stderr" \
    "$job/git-before" "$job/wrapper-log" "$job/exit.tmp" "$job/cli-pid"

  : >"$job/finished"
  return "$rc"
}

mark_job_stopped() {
  local job=$1 rc=$2 pid
  pid=$(cat "$job/pid")
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  kill_tree "$pid" || return 1
  date +%s >"$job/ended"
  printf '%s\n' "$rc" >"$job/exit"
  [ "$rc" != 124 ] || printf 'timeout\n' >"$job/stopped"
}

parse_slice() {
  [ $# -eq 0 ] && { printf '480'; return 0; }
  [ $# -eq 2 ] && [ "$1" = --slice ] || usage_error "usage: junie-forward.sh wait <id> [--slice <seconds>]"
  positive_seconds --slice "$2"
  [ "$((10#$2))" -le 540 ] || usage_error "--slice must be at most 540 seconds"
  printf '%s' "$((10#$2))"
}

wait_job() {
  local id=${1:-} job slice slice_end deadline now elapsed
  [ $# -gt 0 ] || usage_error "wait needs a job id"
  shift
  job=$(job_path "$id") || return "$USAGE_EXIT"
  slice=$(parse_slice "$@") || return "$USAGE_EXIT"
  slice_end=$(($(date +%s) + slice))
  deadline=$(cat "$job/deadline")
  while :; do
    [ -f "$job/exit" ] && { finish_job "$job"; return $?; }
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      mark_job_stopped "$job" 124 || return 1
      finish_job "$job"
      return $?
    fi
    if [ "$now" -ge "$slice_end" ]; then
      elapsed=$((now - $(cat "$job/started")))
      printf '[junie-rescue] job %s still running (%ss) — call wait again\n' "$id" "$elapsed"
      return 75
    fi
    sleep 1
  done
}

cancel_job() {
  local job
  [ $# -eq 1 ] || usage_error "cancel needs a job id"
  job=$(job_path "$1") || return "$USAGE_EXIT"
  [ -f "$job/exit" ] || mark_job_stopped "$job" 130 || return 1
  finish_job "$job"
}

main() {
  local command=${1:-}
  [ $# -gt 0 ] && shift
  case $command in
    preflight) parse_options "$@"; enter_workspace; preflight ;;
    run) parse_options "$@"; enter_workspace; run_task ;;
    start) parse_options "$@"; enter_workspace; start_task ;;
    wait) wait_job "$@" ;;
    cancel) cancel_job "$@" ;;
    __job) run_job_wrapper "$@" ;;
    *) usage_error "usage: junie-forward.sh preflight|run|start|wait|cancel [options]" ;;
  esac
}

main "$@"
