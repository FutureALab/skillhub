#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage:" >&2
  echo "  $0 status --pid-file <file>" >&2
  echo "  $0 stop --pid-file <file>" >&2
  echo "  $0 start --pid-file <file> --log-file <file> --cwd <dir> -- <command...>" >&2
  exit 2
}

require_value() {
  local flag="$1"
  local value="${2:-}"
  if [[ -z "$value" ]]; then
    echo "Missing value for $flag" >&2
    usage
  fi
}

resolve_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$(pwd)" "$path"
  fi
}

is_running() {
  local pid_file="$1"
  [[ -f "$pid_file" ]] || return 1

  local pid
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  (( pid > 1 )) || {
    rm -f "$pid_file"
    return 1
  }

  if kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  rm -f "$pid_file"
  return 1
}

wait_for_exit() {
  local pid="$1"
  for _ in $(seq 1 50); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# Terminates a process and its descendants, deepest first.
kill_tree() {
  local pid="$1"
  local signal="$2"
  local child
  if command -v pgrep >/dev/null 2>&1; then
    for child in $(pgrep -P "$pid" 2>/dev/null || true); do
      kill_tree "$child" "$signal"
    done
  fi
  kill "-$signal" "$pid" 2>/dev/null || true
}

# Keeps the previous run's log for diagnosis but never lets a runaway process fill the disk.
cap_log_file() {
  local log_file="$1"
  local max_bytes="${DEV_LOG_MAX_BYTES:-67108864}"
  [[ "$max_bytes" =~ ^[0-9]+$ ]] || return 0
  (( max_bytes > 0 )) || return 0
  [[ -f "$log_file" ]] || return 0

  # BSD wc pads the count with spaces, so strip whitespace before the numeric check.
  local size
  size="$(wc -c < "$log_file" 2>/dev/null | tr -d '[:space:]')"
  [[ "$size" =~ ^[0-9]+$ ]] || return 0
  if (( size > max_bytes )); then
    mv -f "$log_file" "${log_file}.1" 2>/dev/null || true
  fi
}

cmd="${1:-}"
[[ -n "$cmd" ]] || usage
shift || true

pid_file=""
log_file=""
cwd=""

case "$cmd" in
  status|stop)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --pid-file)
          require_value "$1" "${2:-}"
          pid_file="$2"
          shift 2
          ;;
        *)
          usage
          ;;
      esac
    done
    [[ -n "$pid_file" ]] || usage
    ;;
  start)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --pid-file)
          require_value "$1" "${2:-}"
          pid_file="$2"
          shift 2
          ;;
        --log-file)
          require_value "$1" "${2:-}"
          log_file="$2"
          shift 2
          ;;
        --cwd)
          require_value "$1" "${2:-}"
          cwd="$2"
          shift 2
          ;;
        --)
          shift
          break
          ;;
        *)
          usage
          ;;
      esac
    done
    [[ -n "$pid_file" && -n "$log_file" && -n "$cwd" && $# -gt 0 ]] || usage
    ;;
  *)
    usage
    ;;
esac

case "$cmd" in
  status)
    is_running "$pid_file"
    ;;
  stop)
    if ! is_running "$pid_file"; then
      rm -f "$pid_file"
      exit 0
    fi

    pid="$(cat "$pid_file")"
    # Wrapper commands (pnpm -> node/vite) can exit before their children, so terminate the whole
    # tree; otherwise an orphan keeps holding the dev port and the next start fails.
    kill_tree "$pid" TERM
    if ! wait_for_exit "$pid"; then
      kill_tree "$pid" KILL
      wait_for_exit "$pid" || true
    fi
    rm -f "$pid_file"
    ;;
  start)
    pid_file="$(resolve_path "$pid_file")"
    log_file="$(resolve_path "$log_file")"
    cwd="$(resolve_path "$cwd")"
    mkdir -p "$(dirname "$pid_file")" "$(dirname "$log_file")"
    cap_log_file "$log_file"
    if is_running "$pid_file"; then
      echo "Process already running with PID $(cat "$pid_file")" >&2
      exit 1
    fi

    (
      cd "$cwd"
      if command -v setsid >/dev/null 2>&1; then
        setsid "$@" >>"$log_file" 2>&1 < /dev/null &
      else
        nohup "$@" >>"$log_file" 2>&1 < /dev/null &
      fi
      child_pid=$!
      disown "$child_pid" 2>/dev/null || true
      echo "$child_pid" >"$pid_file"
    )
    ;;
esac
