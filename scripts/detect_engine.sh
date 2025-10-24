#!/usr/bin/env bash
set -euo pipefail

# Prefer Docker, fall back to Podman. Print selected engine or fail if neither is present.

if command -v docker >/dev/null 2>&1; then
  printf '%s\n' docker
  exit 0
fi

if command -v podman >/dev/null 2>&1; then
  printf '%s\n' podman
  exit 0
fi

printf 'Error: Neither docker nor podman is installed or in PATH.\n' >&2
printf 'Install Docker or Podman to continue.\n' >&2
exit 1
