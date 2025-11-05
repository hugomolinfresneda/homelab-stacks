SHELL := /usr/bin/env bash
# homelab-stacks/Makefile
# -------------------------------------------------------------------
# Root Makefile for homelab-stacks
# - Validates compose files
# - Starts/stops stacks (delegates to per-stack helper if present)
# - Monitoring helpers (Prometheus/Grafana)
# - Nextcloud backup helpers
# -------------------------------------------------------------------

# -------- Common vars --------
STACK ?= $(stack)
STACKS_REPO := $(abspath $(CURDIR))
RUNTIME_DIR ?= /opt/homelab-runtime/stacks/$(STACK)
ENV_FILE     ?= $(RUNTIME_DIR)/.env

BASE_FILE     := $(STACKS_REPO)/stacks/$(STACK)/compose.yaml
OVERRIDE_FILE := $(RUNTIME_DIR)/compose.override.yml

# Docker Compose invocations (base vs base+override)
compose_base = docker compose --project-directory $(RUNTIME_DIR) --env-file $(ENV_FILE) -f $(BASE_FILE)
compose_all  = $(compose_base) -f $(OVERRIDE_FILE)

# Helper detection (e.g., stacks/nextcloud/tools/nc)
STACK_HELPER := $(STACKS_REPO)/stacks/$(STACK)/tools/nc
USE_HELPER   := $(and $(STACK),$(wildcard $(STACK_HELPER)))

.PHONY: help lint validate up down ps pull logs install post status reset-db backup backup-verify restore echo-vars

help:
	@echo "Available targets:"
	@echo "  make lint                         - Lint YAML and shell scripts"
	@echo "  make validate                     - Validate all compose files"
	@echo "  make up stack=<name>              - Launch stack (delegates to helper if present)"
	@echo "  make down stack=<name>            - Stop stack"
	@echo "  make ps stack=<name>              - Show stack status"
	@echo "  make pull stack=<name>            - Pull images for the stack"
	@echo "  make logs stack=<name>            - Tail logs (if helper present uses it)"
	@echo "  make install|post|status|reset-db - Extra ops (only if the stack ships a helper)"
	@echo "  make backup stack=nextcloud BACKUP_DIR=...</path> [BACKUP_ENV=~/.config/nextcloud/nc-backup.env]"
	@echo "  make backup-verify stack=nextcloud BACKUP_DIR=...</path>"
	@echo "  make restore stack=nextcloud BACKUP_DIR=...</path> [RUNTIME_DIR=/opt/homelab-runtime/stacks/nextcloud]"
	@echo "  make echo-vars stack=<name>       - Print key variables (paths)"
	@echo ""
	@echo "Monitoring (Prometheus/Grafana) helpers:"
	@echo "  make check-prom                   - promtool check config (mon)"
	@echo "  make check-prom-demo              - promtool check config (demo)"
	@echo "  make reload-prom                  - send HUP to mon-prometheus"
	@echo "  make demo-reload-prom             - send HUP to demo-prometheus"
	@echo "  make bb-ls [JOB=blackbox-http]    - List targets in mon"
	@echo "  make bb-ls-demo [JOB=...]         - List targets in demo"
	@echo "  make bb-add JOB=... TARGET=...    - Add target in mon"
	@echo "  make bb-add-demo JOB=... TARGET=... - Add target in demo"
	@echo "  make bb-rm  JOB=... TARGET=...    - Remove target in mon"
	@echo "  make bb-rm-demo JOB=... TARGET=... - Remove target in demo"

# ------------------------------------------------------------
# Lint YAML and shell scripts
# ------------------------------------------------------------
lint:
	@echo "Linting YAML and shell scripts..."
	yamllint -d "{extends: default, rules: {line-length: disable, document-start: disable, comments-indentation: disable}}" stacks
	@find stacks -type f -name "*.sh" -print0 | xargs -0 -r -n1 shellcheck || true

# ------------------------------------------------------------
# Validate all docker-compose files
# ------------------------------------------------------------
validate:
	@echo "Validating compose files..."
	@set -euo pipefail; \
	# 1) Bases: solo compose.(yml|yaml)
	for f in $$(find stacks -type f \( -name "compose.yml" -o -name "compose.yaml" \)); do \
		echo " - $$f"; \
		docker compose -f "$$f" config -q; \
	done; \
	# 2) Bundle demo (monitoring): compose.demo.yaml + overlays
	if [ -f stacks/monitoring/compose.demo.yaml ]; then \
		echo " - stacks/monitoring/demo bundle (compose.demo.yaml + overlays)"; \
		docker compose \
		  -f stacks/monitoring/compose.demo.yaml \
		  -f stacks/monitoring/compose.demo.logs.yaml \
		  -f stacks/monitoring/compose.demo.names.yaml \
		  config -q; \
	fi; \
	echo "All compose files validated successfully."

# ------------------------------------------------------------
# Stack operations
# - If the stack provides tools/nc, delegate to it for richer flow
# - Otherwise, use generic compose (base + override if present)
# ------------------------------------------------------------

# Guard: require STACK for ops
require-stack:
	@if [ -z "$(STACK)" ]; then echo "error: set stack=<name>"; exit 1; fi

# -------- Delegated path (helper present) --------
ifeq ($(USE_HELPER),$(STACK_HELPER))

up: require-stack
	@STACKS_REPO=$(STACKS_REPO) RUNTIME_DIR=$(RUNTIME_DIR) "$(STACK_HELPER)" up

down: require-stack
	@STACKS_REPO=$(STACKS_REPO) RUNTIME_DIR=$(RUNTIME_DIR) "$(STACK_HELPER)" down

ps: require-stack
	@$(compose_all) ps

pull: require-stack
	@$(compose_base) pull

logs: require-stack
	@STACKS_REPO=$(STACKS_REPO) RUNTIME_DIR=$(RUNTIME_DIR) "$(STACK_HELPER)" logs

install: require-stack
	@STACKS_REPO=$(STACKS_REPO) RUNTIME_DIR=$(RUNTIME_DIR) "$(STACK_HELPER)" install

post: require-stack
	@STACKS_REPO=$(STACKS_REPO) RUNTIME_DIR=$(RUNTIME_DIR) "$(STACK_HELPER)" post

status: require-stack
	@STACKS_REPO=$(STACKS_REPO) RUNTIME_DIR=$(RUNTIME_DIR) "$(STACK_HELPER)" status

reset-db: require-stack
	@STACKS_REPO=$(STACKS_REPO) RUNTIME_DIR=$(RUNTIME_DIR) "$(STACK_HELPER)" reset-db

# -------- Generic path (no helper) --------
else

up: require-stack
	@$(compose_all) up -d

down: require-stack
	@$(compose_all) down

ps: require-stack
	@$(compose_all) ps

pull: require-stack
	@$(compose_base) pull

logs: require-stack
	@$(compose_all) logs -f --tail=100

# No-op extras when there is no helper
install post status reset-db: require-stack
	@echo "info: '$(STACK)' has no helper; nothing to do."

endif

# ------------------------------------------------------------
# Backups for Nextcloud (explicit targets; do not depend on helper)
# ------------------------------------------------------------

backup: require-stack
	@if [ "$(STACK)" != "nextcloud" ]; then echo "info: 'backup' is only supported for stack=nextcloud"; exit 0; fi; \
	if [ -z "$(BACKUP_DIR)" ]; then echo "error: set BACKUP_DIR=/path/to/backups"; exit 1; fi; \
	script="$(STACKS_REPO)/stacks/nextcloud/backup/nc-backup.sh"; \
	[ -n "$(BACKUP_TRACE)" ] && { printf '→ Using script: %s\n' "$$script"; printf '→ Using BACKUP_DIR: %s\n' "$(BACKUP_DIR)"; [ -n "$(BACKUP_ENV)" ] && printf '→ Using BACKUP_ENV: %s\n' "$(BACKUP_ENV)"; }; \
	chmod +x "$$script" 2>/dev/null || true; \
	if [ -n "$(BACKUP_ENV)" ]; then \
		ENV_FILE="$(BACKUP_ENV)" BACKUP_DIR="$(BACKUP_DIR)" bash "$$script"; \
	else \
		BACKUP_DIR="$(BACKUP_DIR)" bash "$$script"; \
	fi

backup-verify: require-stack
	@if [ "$(STACK)" != "nextcloud" ]; then echo "info: 'backup-verify' is only supported for stack=nextcloud"; exit 0; fi; \
	if [ -z "$(BACKUP_DIR)" ]; then echo "error: set BACKUP_DIR=/path/to/backups"; exit 1; fi; \
	latest=$$(find "$(BACKUP_DIR)" -maxdepth 1 -type f -name 'nc-*.sha256' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-); \
	if [ -z "$$latest" ]; then echo "No *.sha256 found in $(BACKUP_DIR)"; exit 1; fi; \
	printf '→ Verifying %s\n' "$$latest"; \
	( cd "$(BACKUP_DIR)" && sha256sum -c "$$(basename "$$latest")" )

restore: require-stack
	@if [ "$(STACK)" != "nextcloud" ]; then echo "info: 'restore' is only supported for stack=nextcloud"; exit 0; fi; \
	if [ -z "$(BACKUP_DIR)" ]; then echo "error: set BACKUP_DIR=/path/to/backups"; exit 1; fi; \
	script="$(STACKS_REPO)/stacks/nextcloud/backup/nc-restore.sh"; \
	compose="$(BASE_FILE)"; \
	rt="$(RUNTIME_DIR)"; \
	[ -z "$$rt" ] && rt="/opt/homelab-runtime/stacks/$(STACK)"; \
	[ -n "$(BACKUP_TRACE)" ] && { printf '→ Using script: %s\n' "$$script"; printf '→ Using COMPOSE_FILE: %s\n' "$$compose"; printf '→ Using RUNTIME_DIR: %s\n' "$$rt"; printf '→ Using BACKUP_DIR: %s\n' "$(BACKUP_DIR)"; }; \
	chmod +x "$$script" 2>/dev/null || true; \
	COMPOSE_FILE="$$compose" RUNTIME_DIR="$$rt" BACKUP_DIR="$(BACKUP_DIR)" bash "$$script"

# ------------------------------------------------------------
# Debug helpers
# ------------------------------------------------------------
echo-vars: require-stack
	@printf 'STACKS_REPO = %s\n' '$(STACKS_REPO)'
	@printf 'BASE_FILE   = %s\n' '$(BASE_FILE)'
	@printf 'RUNTIME_DIR = %s\n' '$(RUNTIME_DIR)'
	@printf 'ENV_FILE    = %s\n' '$(ENV_FILE)'

# ------------------------------------------------------------
# Monitoring helpers (Prometheus/Grafana)
# - Use prom/prometheus and the stacks/monitoring/scripts helper
# ------------------------------------------------------------
MON_STACK_DIR := $(STACKS_REPO)/stacks/monitoring
PROM_FILE_MON_REL  := prometheus/prometheus.yml
PROM_FILE_DEMO_REL := prometheus/prometheus.demo.yml
MON_PROM_CONTAINER := mon-prometheus
DEMO_PROM_CONTAINER:= demo-prometheus

promtool = docker run --rm -v "$(MON_STACK_DIR)":/workdir -w /workdir --entrypoint /bin/promtool prom/prometheus:latest

.PHONY: check-prom check-prom-demo reload-prom demo-reload-prom \
        bb-ls bb-ls-demo bb-add bb-add-demo bb-rm bb-rm-demo print-mon

# ---- promtool checks (mon & demo) ----
check-prom:
	@cd "$(MON_STACK_DIR)" && \
	f="prometheus/prometheus.yml"; [ -f "$$f" ] || f="prometheus/prometheus.yaml"; \
	[ -f "$$f" ] || { echo "error: no prometheus.(yml|yaml) in $(MON_STACK_DIR)/prometheus"; exit 1; }; \
	$(promtool) check config "$$f"

check-prom-demo:
	@cd "$(MON_STACK_DIR)" && \
	f="prometheus/prometheus.demo.yml"; [ -f "$$f" ] || f="prometheus/prometheus.demo.yaml"; \
	[ -f "$$f" ] || { echo "error: no prometheus.demo.(yml|yaml) in $(MON_STACK_DIR)/prometheus"; exit 1; }; \
	$(promtool) check config "$$f"

# ---- reload via HUP (mon & demo) ----
reload-prom:
	@docker kill -s HUP $(MON_PROM_CONTAINER) >/dev/null 2>&1 || \
	  { echo "warn: could not send HUP to $(MON_PROM_CONTAINER) (is it running?)"; exit 1; }
	@echo "Reload sent to $(MON_PROM_CONTAINER)"

demo-reload-prom:
	@docker kill -s HUP $(DEMO_PROM_CONTAINER) >/dev/null 2>&1 || \
	  { echo "warn: could not send HUP to $(DEMO_PROM_CONTAINER) (is demo running?)"; exit 1; }
	@echo "Reload sent to $(DEMO_PROM_CONTAINER)"

# ---- blackbox targets (wrappers over stacks/monitoring/scripts/blackbox-targets.sh) ----
# Variables: JOB (defaults to blackbox-http), TARGET (required for add/rm)
JOB ?= blackbox-http

bb-ls:
	@f="$(MON_STACK_DIR)/prometheus/prometheus.yml"; [ -f "$$f" ] || f="$(MON_STACK_DIR)/prometheus/prometheus.yaml"; \
	[ -f "$$f" ] || { echo "error: no prometheus.(yml|yaml) in $(MON_STACK_DIR)/prometheus"; exit 1; }; \
	"$(MON_STACK_DIR)/scripts/blackbox-targets.sh" --file "$$f" ls "$(JOB)"

bb-ls-demo:
	@f="$(MON_STACK_DIR)/prometheus/prometheus.demo.yml"; [ -f "$$f" ] || f="$(MON_STACK_DIR)/prometheus/prometheus.demo.yaml"; \
	[ -f "$$f" ] || { echo "error: no prometheus.demo.(yml|yaml) in $(MON_STACK_DIR)/prometheus"; exit 1; }; \
	"$(MON_STACK_DIR)/scripts/blackbox-targets.sh" --file "$$f" ls "$(JOB)"

bb-add:
	@if [ -z "$(TARGET)" ]; then echo "error: set TARGET=..."; exit 1; fi
	@f="$(MON_STACK_DIR)/prometheus/prometheus.yml"; [ -f "$$f" ] || f="$(MON_STACK_DIR)/prometheus/prometheus.yaml"; \
	[ -f "$$f" ] || { echo "error: no prometheus.(yml|yaml) in $(MON_STACK_DIR)/prometheus"; exit 1; }; \
	"$(MON_STACK_DIR)/scripts/blackbox-targets.sh" --file "$$f" add "$(JOB)" "$(TARGET)"

bb-add-demo:
	@if [ -z "$(TARGET)" ]; then echo "error: set TARGET=..."; exit 1; fi
	@f="$(MON_STACK_DIR)/prometheus/prometheus.demo.yml"; [ -f "$$f" ] || f="$(MON_STACK_DIR)/prometheus/prometheus.demo.yaml"; \
	[ -f "$$f" ] || { echo "error: no prometheus.demo.(yml|yaml) in $(MON_STACK_DIR)/prometheus"; exit 1; }; \
	"$(MON_STACK_DIR)/scripts/blackbox-targets.sh" --file "$$f" add "$(JOB)" "$(TARGET)"

bb-rm:
	@if [ -z "$(TARGET)" ]; then echo "error: set TARGET=..."; exit 1; fi
	@f="$(MON_STACK_DIR)/prometheus/prometheus.yml"; [ -f "$$f" ] || f="$(MON_STACK_DIR)/prometheus/prometheus.yaml"; \
	[ -f "$$f" ] || { echo "error: no prometheus.(yml|yaml) in $(MON_STACK_DIR)/prometheus"; exit 1; }; \
	"$(MON_STACK_DIR)/scripts/blackbox-targets.sh" --file "$$f" rm "$(JOB)" "$(TARGET)"

bb-rm-demo:
	@if [ -z "$(TARGET)" ]; then echo "error: set TARGET=..."; exit 1; fi
	@f="$(MON_STACK_DIR)/prometheus/prometheus.demo.yml"; [ -f "$$f" ] || f="$(MON_STACK_DIR)/prometheus/prometheus.demo.yaml"; \
	[ -f "$$f" ] || { echo "error: no prometheus.demo.(yml|yaml) in $(MON_STACK_DIR)/prometheus"; exit 1; }; \
	"$(MON_STACK_DIR)/scripts/blackbox-targets.sh" --file "$$f" rm "$(JOB)" "$(TARGET)"

print-mon:
	@printf 'STACKS_REPO=%s\nMON_STACK_DIR=%s\n' '$(STACKS_REPO)' '$(MON_STACK_DIR)'
