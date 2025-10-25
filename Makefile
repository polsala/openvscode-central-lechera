SHELL := /bin/bash
.PHONY: help run stop restart logs update ca-init ca-server ca-client ca-revoke nginx-print dry-run clean

HELP_ROWS := \
  "help           Show this help message" \
  "run            Launch OpenVSCode Server container" \
  "stop           Stop and remove the container" \
  "restart        Restart the container" \
  "logs           Follow container logs" \
  "update         Pull the container image" \
  "ca-init        Initialize the local CA (once)" \
  "ca-server      Issue a server certificate (DOMAIN= required)" \
  "ca-client      Issue a client certificate (NAME= required)" \
  "ca-revoke      Revoke a client certificate (NAME= required)" \
  "nginx-print    Print Nginx guidance based on BASE_PATH" \
  "dry-run        Preview container plan without executing" \
  "clean          Remove runtime artifacts (CLEAN_CA=true to wipe CA)" \
  "CA_PATH=/dir   Override CA storage path for all make ca-* targets"

CA_EASY := ./ca/ca-easy.sh
CA_PATH_FLAG := $(if $(CA_PATH),--ca-path "$(CA_PATH)",)

help:
	@printf "Available targets:\n"
	@for row in $(HELP_ROWS); do \
	  printf "  %s\n" "$$row"; \
	done

run:
	@./run.sh

stop:
	@./stop.sh

restart:
	@$(MAKE) stop
	@$(MAKE) run

logs:
	@ENGINE=$$(./scripts/detect_engine.sh); \
	NAME=$${CONTAINER_NAME:-ovscode_plug}; \
	printf "Following logs for %s using %s\n" "$$NAME" "$$ENGINE"; \
	$$ENGINE logs -f "$$NAME"

update:
	@ENGINE=$$(./scripts/detect_engine.sh); \
	IMAGE=$${IMAGE:-gitpod/openvscode-server:latest}; \
	printf "Pulling %s with %s\n" "$$IMAGE" "$$ENGINE"; \
	$$ENGINE pull "$$IMAGE"

ca-init:
	@$(CA_EASY) $(CA_PATH_FLAG) init

ca-server:
	@if [ -z "$(DOMAIN)" ]; then \
		printf "Error: DOMAIN is required. Usage: make ca-server DOMAIN=code.test SAN=\"dns:alt,ip:127.0.0.1\"\n" >&2; \
		exit 1; \
	fi
	@SAN_INPUT="$(SAN)"; \
	IFS=',' read -r -a SAN_LIST <<< "$$SAN_INPUT"; \
	$(CA_EASY) $(CA_PATH_FLAG) server "$(DOMAIN)" "$${SAN_LIST[@]}"

ca-client:
	@if [ -z "$(NAME)" ]; then \
		printf "Error: NAME is required. Usage: make ca-client NAME=alice [P12_PASS=secret]\n" >&2; \
		exit 1; \
	fi
	@$(CA_EASY) $(CA_PATH_FLAG) client "$(NAME)" "$(P12_PASS)"

ca-revoke:
	@if [ -z "$(NAME)" ]; then \
		printf "Error: NAME is required. Usage: make ca-revoke NAME=alice\n" >&2; \
		exit 1; \
	fi
	@$(CA_EASY) $(CA_PATH_FLAG) revoke "$(NAME)"

nginx-print:
	@BASE_PATH_VALUE="$${BASE_PATH:-}"; \
	TEMPLATE="nginx/ovscode_mtls.conf"; \
	SUBST_VARS='$${SERVER_NAME} $${SERVER_CERT} $${SERVER_KEY} $${CA_CRT} $${UPSTREAM_PORT} $${BASE_PATH}'; \
	if [ -z "$$BASE_PATH_VALUE" ]; then \
	  printf 'Use %s (subdomain).\n' "$$TEMPLATE"; \
	  printf 'Placeholders: $${SERVER_NAME} $${SERVER_CERT} $${SERVER_KEY} $${CA_CRT} $${UPSTREAM_PORT}\n'; \
	else \
	  TEMPLATE="nginx/ovscode_mtls_subpath.conf"; \
	  printf 'Use %s (subpath). Set BASE_PATH=%s in .env and replace $${BASE_PATH} accordingly.\n' "$$TEMPLATE" "$$BASE_PATH_VALUE"; \
	  printf 'Placeholders: $${SERVER_NAME} $${SERVER_CERT} $${SERVER_KEY} $${CA_CRT} $${UPSTREAM_PORT} $${BASE_PATH}\n'; \
	fi; \
	printf '\nCurrent values (set env VAR=value make nginx-print to change):\n'; \
	printf '  $${SERVER_NAME}   -> %s\n' "$${SERVER_NAME:-<set SERVER_NAME=code.example.test>}"; \
	printf '  $${SERVER_CERT}   -> %s\n' "$${SERVER_CERT:-<set SERVER_CERT=/opt/certs/server.crt>}"; \
	printf '  $${SERVER_KEY}    -> %s\n' "$${SERVER_KEY:-<set SERVER_KEY=/opt/certs/server.key>}"; \
	printf '  $${CA_CRT}        -> %s\n' "$${CA_CRT:-<set CA_CRT=/opt/certs/ca.crt>}"; \
	printf '  $${UPSTREAM_PORT} -> %s\n' "$${UPSTREAM_PORT:-<set UPSTREAM_PORT=7000>}"; \
	if [ -n "$$BASE_PATH_VALUE" ]; then \
	  printf '  $${BASE_PATH}     -> %s\n' "$$BASE_PATH_VALUE"; \
	fi; \
	printf '\nFill the template with envsubst (edit the destination path as needed):\n'; \
	printf "  env SERVER_NAME=\"%s\" SERVER_CERT=\"%s\" SERVER_KEY=\"%s\" CA_CRT=\"%s\" UPSTREAM_PORT=\"%s\" BASE_PATH=\"%s\" envsubst '%s' < %s > /tmp/ovscode.conf\n" \
	  "$${SERVER_NAME:-code.example.test}" \
	  "$${SERVER_CERT:-/opt/certs/server.crt}" \
	  "$${SERVER_KEY:-/opt/certs/server.key}" \
	  "$${CA_CRT:-/opt/certs/ca.crt}" \
	  "$${UPSTREAM_PORT:-7000}" \
	  "$$BASE_PATH_VALUE" \
	  "$$SUBST_VARS" \
	  "$$TEMPLATE"; \
	printf "\nOpen /tmp/ovscode.conf, review, then copy it into /etc/nginx/conf.d/.\n"

dry-run:
	@DRY_RUN=true ./run.sh

clean:
	@printf "Removing runtime artifacts...\n"
	@rm -f meta/project.code-workspace meta/parsed.env
	@rm -rf .ovscode_plug
	@if [ "$${CLEAN_CA}" = "true" ]; then \
	  printf "CLEAN_CA=true → wiping CA outputs (keep ca-easy.sh).\n"; \
	  find ca -mindepth 1 -maxdepth 1 ! -name 'ca-easy.sh' -exec rm -rf {} +; \
	fi
