#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
SCRIPTS_DIR="$PROJECT_ROOT/scripts"
ENV_FILE="$PROJECT_ROOT/.env"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a
  . "$ENV_FILE"
  set +a
fi

CONTAINER_ENGINE="${CONTAINER_ENGINE:-}"
CONTAINER_NAME="${CONTAINER_NAME:-ovscode_plug}"

if [[ -n "$CONTAINER_ENGINE" ]]; then
  if ! command -v "$CONTAINER_ENGINE" >/dev/null 2>&1; then
    printf 'Error: CONTAINER_ENGINE "%s" is not available.\n' "$CONTAINER_ENGINE" >&2
    exit 1
  fi
  ENGINE="$CONTAINER_ENGINE"
else
  ENGINE="$("$SCRIPTS_DIR/detect_engine.sh")"
fi

if ! "$ENGINE" ps -a --format '{{.Names}}' | grep -Fqx "$CONTAINER_NAME"; then
  printf 'Info: Container "%s" is not running.\n' "$CONTAINER_NAME"
  exit 0
fi

printf 'Stopping container "%s"...\n' "$CONTAINER_NAME"
if "$ENGINE" rm -f "$CONTAINER_NAME" >/dev/null; then
  printf 'Container "%s" stopped and removed.\n' "$CONTAINER_NAME"
else
  printf 'Error: Failed to stop container "%s".\n' "$CONTAINER_NAME" >&2
  exit 1
fi
