#!/usr/bin/env bash
# shellcheck shell=bash
#set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
SCRIPTS_DIR="$PROJECT_ROOT/scripts"
META_DIR="$PROJECT_ROOT/meta"
RUNTIME_DIR="$PROJECT_ROOT/.ovscode_plug"
RUNTIME_ENV="$RUNTIME_DIR/.env.runtime"
WORKSPACE_FILE="$META_DIR/project.code-workspace"
CONTAINER_WORKSPACE_ROOT="/home/workspace"

mkdir -p "$META_DIR" "$RUNTIME_DIR"

ENV_FILE="$PROJECT_ROOT/.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a
  . "$ENV_FILE"
  set +a
fi

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

CONTAINER_ENGINE="${CONTAINER_ENGINE:-}"
CONTAINER_NAME="${CONTAINER_NAME:-ovscode_plug}"
IMAGE="${IMAGE:-gitpod/openvscode-server:latest}"
USERMAP="${USERMAP:-}"
OFFLINE_MODE="$(to_lower "${OFFLINE_MODE:-false}")"
READONLY_CONTAINER="$(to_lower "${READONLY_CONTAINER:-false}")"
BASE_PATH="${BASE_PATH:-}"
MOUNT_LABEL="${MOUNT_LABEL:-}"
PORT_STRATEGY="$(to_lower "${PORT_STRATEGY:-strict}")"
DRY_RUN="$(to_lower "${DRY_RUN:-false}")"
LOG_FILE="${LOG_FILE:-}"
INTERFACE="${INTERFACE:-}"
PORT="${PORT:-}"
SOURCE_PATHS="${SOURCE_PATHS:-}"
CONNECTION_TOKEN="${CONNECTION_TOKEN:-}"

if [[ -n "$BASE_PATH" ]]; then
  if [[ "$BASE_PATH" != /* ]]; then
    printf 'Error: BASE_PATH must start with "/". Got "%s".\n' "$BASE_PATH" >&2
    exit 1
  fi
  BASE_PATH="${BASE_PATH%/}"
  if [[ -z "$BASE_PATH" ]]; then
    BASE_PATH=""
  fi
fi

if [[ "$PORT_STRATEGY" != "strict" && "$PORT_STRATEGY" != "auto" ]]; then
  printf 'Error: PORT_STRATEGY must be "strict" or "auto". Got "%s".\n' "$PORT_STRATEGY" >&2
  exit 1
fi

if [[ -n "$CONTAINER_ENGINE" ]]; then
  if ! command -v "$CONTAINER_ENGINE" >/dev/null 2>&1; then
    printf 'Error: CONTAINER_ENGINE is set to "%s" but it is not executable.\n' "$CONTAINER_ENGINE" >&2
    exit 1
  fi
  ENGINE="$CONTAINER_ENGINE"
else
  ENGINE="$("$SCRIPTS_DIR/detect_engine.sh")"
fi

"$SCRIPTS_DIR/validate_env.sh"

PARSED_ENV="$META_DIR/parsed.env"
if [[ ! -f "$PARSED_ENV" ]]; then
  printf 'Error: Expected %s to exist after validation.\n' "$PARSED_ENV" >&2
  exit 1
fi

# shellcheck disable=SC1090
. "$PARSED_ENV"

IFS=';' read -r -a parsed_entries <<< "${PARSED_ENTRIES:-}"
if [[ ${#parsed_entries[@]} -eq 0 ]]; then
  printf 'Error: No mount entries parsed; aborting.\n' >&2
  exit 1
fi

is_port_free() {
  local host_ip="$1"
  local port_number="$2"
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PYCODE' "$host_ip" "$port_number"
import socket
import sys
ip = sys.argv[1]
port = int(sys.argv[2])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    sock.bind((ip, port))
except OSError:
    sys.exit(1)
finally:
    sock.close()
PYCODE
    return $?
  fi

  # Fallback: use bash and /dev/tcp
  if exec {fd}<>"/dev/tcp/$host_ip/$port_number" 2>/dev/null; then
    exec {fd}>&-
    return 1
  fi
  return 0
}

requested_port="$PORT"
effective_port="$PORT"
if [[ "$PORT_STRATEGY" == "auto" ]]; then
  while ! is_port_free "$INTERFACE" "$effective_port"; do
    effective_port=$((effective_port + 1))
    if (( effective_port > 65535 )); then
      printf 'Error: Failed to find free port when starting from %s.\n' "$requested_port" >&2
      exit 1
    fi
  done
  if [[ "$effective_port" != "$requested_port" ]]; then
    printf 'Info: Requested port %s was busy. Using port %s instead.\n' "$requested_port" "$effective_port"
  fi
else
  if ! is_port_free "$INTERFACE" "$effective_port"; then
    printf 'Error: Port %s is already in use on interface %s.\n' "$effective_port" "$INTERFACE" >&2
    exit 1
  fi
fi

choose_usermap() {
  local entry path_info
  if [[ -n "$USERMAP" ]]; then
    printf '%s' "$USERMAP"
    return
  fi
  for entry in "${parsed_entries[@]}"; do
    IFS='|' read -r _alias _mode path_info <<< "$entry"
    if [[ -n "$path_info" ]]; then
      if stat -c '%u:%g' "$path_info" >/dev/null 2>&1; then
        USERMAP="$(stat -c '%u:%g' "$path_info")"
        printf '%s' "$USERMAP"
        return
      elif stat -f '%u:%g' "$path_info" >/dev/null 2>&1; then
        USERMAP="$(stat -f '%u:%g' "$path_info")"
        printf '%s' "$USERMAP"
        return
      fi
    fi
  done
  printf '1000:1000'
}

USERMAP="$(choose_usermap)"

if [[ -z "$CONNECTION_TOKEN" ]]; then
  if [[ -f "$RUNTIME_ENV" ]]; then
    # shellcheck disable=SC1091
    . "$RUNTIME_ENV"
    CONNECTION_TOKEN="${CONNECTION_TOKEN:-}"
  fi
fi

if [[ -z "$CONNECTION_TOKEN" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    CONNECTION_TOKEN="$(openssl rand -hex 24)"
  else
    CONNECTION_TOKEN="$(head -c 24 /dev/urandom | base64 | tr -d '=+/[:space:]')"
  fi
fi

{
  printf 'CONNECTION_TOKEN=%s\n' "$CONNECTION_TOKEN"
  printf 'GENERATED_AT=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "$RUNTIME_ENV"

workspaces_json_content() {
  local items=()
  local entry alias mode path

  for entry in "${parsed_entries[@]}"; do
    IFS='|' read -r alias mode path <<< "$entry"
    items+=("    { \"name\": \"${alias}\", \"path\": \"${CONTAINER_WORKSPACE_ROOT}/${alias}\" }")
  done

  printf '{\n'
  printf '  "folders": [\n'
  local idx=0
  for line in "${items[@]}"; do
    if (( idx > 0 )); then
      printf ',\n'
    fi
    printf '%s' "$line"
    ((idx++))
  done
  printf '\n  ],\n'
  printf '  "settings": {\n'
  printf '    "workbench.startupEditor": "none",\n'
  printf '    "security.workspace.trust.startupPrompt": "never",\n'
  printf '    "remote.downloadExtensionsLocally": false\n'
  printf '  }\n'
  printf '}\n'
}

workspaces_json_content > "$WORKSPACE_FILE"

mount_args=()
folders_report=()
for entry in "${parsed_entries[@]}"; do
  IFS='|' read -r alias mode path <<< "$entry"
  mount_suffix=":$mode"
  if [[ -n "$MOUNT_LABEL" ]]; then
    mount_label_adjusted="$MOUNT_LABEL"
    if [[ "$mount_label_adjusted" != :* ]]; then
      mount_label_adjusted=":$mount_label_adjusted"
    fi
    mount_suffix="${mount_suffix}${mount_label_adjusted}"
  fi
  mount_args+=("-v" "${path}:${CONTAINER_WORKSPACE_ROOT}/${alias}${mount_suffix}")
  folders_report+=("$alias|$mode|$path")
done

mount_args+=("-v" "${WORKSPACE_FILE}:/wsmeta/project.code-workspace:ro")

container_args=(
  "$ENGINE" run
  "--name" "$CONTAINER_NAME"
  "--detach"
  "--restart" "unless-stopped"
  "--user" "$USERMAP"
  "-p" "${INTERFACE}:${effective_port}:3000"
)

if [[ "$ENGINE" == "podman" ]]; then
  container_args+=("--tz" "UTC")
fi

if [[ "$OFFLINE_MODE" == "true" ]]; then
  container_args+=("--network" "none")
fi

if [[ "$READONLY_CONTAINER" == "true" ]]; then
  container_args+=("--read-only")
  container_args+=("--tmpfs" "/tmp:rw,exec,nosuid,size=64m")
  container_args+=("--tmpfs" "/var/tmp:rw,nosuid,size=16m")
  container_args+=("--tmpfs" "/home/workspace/.cache:rw,size=128m")
fi

container_args+=("${mount_args[@]}")
container_args+=("-e" "CONNECTION_TOKEN=${CONNECTION_TOKEN}")
container_args+=("$IMAGE")

if [[ -n "$BASE_PATH" ]]; then
  container_args+=("--server-base-path" "$BASE_PATH")
fi

container_args+=("/wsmeta/project.code-workspace")

join_command() {
  local joined="" arg
  for arg in "$@"; do
    if [[ "$arg" == *[[:space:]\"]* ]]; then
      joined+=" \"${arg//\"/\\\"}\""
    else
      joined+=" $arg"
    fi
  done
  printf '%s' "${joined# }"
}

full_command="$(join_command "${container_args[@]}")"

if [[ "$DRY_RUN" == "true" ]]; then
  export DRY_RUN="$DRY_RUN"
  export VALIDATION_COMMAND_PREVIEW="$full_command"
  "$SCRIPTS_DIR/validate_env.sh" --dry-run-summary
  exit 0
fi

if "$ENGINE" ps -a --format '{{.Names}}' | grep -Fqx "$CONTAINER_NAME"; then
  printf 'Info: Container "%s" already exists. Stopping and removing.\n' "$CONTAINER_NAME"
  "$ENGINE" rm -f "$CONTAINER_NAME" >/dev/null
fi

"${container_args[@]}" >/dev/null

if [[ -n "$LOG_FILE" ]]; then
  printf 'Info: Tailing logs to %s (background).\n' "$LOG_FILE"
  (
    set +e
    "$ENGINE" logs -f "$CONTAINER_NAME" 2>&1 | tee -a "$LOG_FILE"
  ) &
fi

printf '\nOpenVSCode Server is ready!\n'
printf 'URL:    http://%s:%s%s\n' "$INTERFACE" "$effective_port" "${BASE_PATH:-}"
printf 'Token:  %s\n' "$CONNECTION_TOKEN"
printf 'Engine: %s   Container: %s\n' "$ENGINE" "$CONTAINER_NAME"
printf 'User:   %s\n' "$USERMAP"
printf 'Folders:\n'
for line in "${folders_report[@]}"; do
  IFS='|' read -r alias mode path <<< "$line"
  printf '  - %s  %s  %s\n' "$alias" "$mode" "$path"
done
