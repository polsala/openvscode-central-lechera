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
  "clean          Remove runtime artifacts (CLEAN_CA=true to wipe CA)"

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
	@./ca/ca-easy.sh init

ca-server:
	@if [ -z "$(DOMAIN)" ]; then \
		printf "Error: DOMAIN is required. Usage: make ca-server DOMAIN=code.test SAN=\"dns:alt,ip:127.0.0.1\"\n" >&2; \
		exit 1; \
	fi
	@SAN_INPUT="$(SAN)"; \
	IFS=',' read -r -a SAN_LIST <<< "$$SAN_INPUT"; \
	./ca/ca-easy.sh server "$(DOMAIN)" "$${SAN_LIST[@]}"

ca-client:
	@if [ -z "$(NAME)" ]; then \
		printf "Error: NAME is required. Usage: make ca-client NAME=alice [P12_PASS=secret]\n" >&2; \
		exit 1; \
	fi
	@./ca/ca-easy.sh client "$(NAME)" "$(P12_PASS)"

ca-revoke:
	@if [ -z "$(NAME)" ]; then \
		printf "Error: NAME is required. Usage: make ca-revoke NAME=alice\n" >&2; \
		exit 1; \
	fi
	@./ca/ca-easy.sh revoke "$(NAME)"

nginx-print:
	@BASE_PATH_VALUE="$${BASE_PATH:-}"; \
	if [ -z "$$BASE_PATH_VALUE" ]; then \
	  printf "Use nginx/ovscode_mtls.conf (subdomain). Placeholders:\n"; \
	  printf "  <SERVER_NAME> <SERVER_CERT> <SERVER_KEY> <CA_CRT> <UPSTREAM_PORT>\n"; \
	else \
	  printf "Use nginx/ovscode_mtls_subpath.conf (subpath). Set BASE_PATH=%s in .env and replace <BASE_PATH> accordingly.\n" "$$BASE_PATH_VALUE"; \
	  printf "Placeholders: <SERVER_NAME> <SERVER_CERT> <SERVER_KEY> <CA_CRT> <UPSTREAM_PORT> <BASE_PATH>\n"; \
	fi

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
