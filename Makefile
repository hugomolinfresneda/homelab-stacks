SHELL := /usr/bin/env bash
# ============================================================
# Homelab Stacks — Public repository (homelab-stacks)
# ============================================================

# -------- Common vars --------
STACK ?= $(stack)
STACKS_REPO := $(abspath $(CURDIR))# absolute path to this repo
RUNTIME_DIR ?= /opt/homelab-runtime/stacks/$(STACK)# default runtime dir (override if needed)
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
	@echo "  make echo-vars stack=<name>       - Debug key variables (paths)"

# ------------------------------------------------------------
# Lint YAML and shell scripts
# ------------------------------------------------------------
lint:
	@echo "🧹 Linting YAML and shell scripts..."
	yamllint -d "{extends: default, rules: {line-length: disable, document-start: disable, comments-indentation: disable}}" stacks
	@find stacks -type f -name "*.sh" -print0 | xargs -0 -r -n1 shellcheck || true

# ------------------------------------------------------------
# Validate all docker-compose files
# ------------------------------------------------------------
validate:
	@echo "🔍 Validating compose files..."
	@set -euo pipefail; \
	for f in $$(find stacks -type f \( -name "compose.yml" -o -name "compose.yaml" -o -name "compose.*.yml" -o -name "compose.*.yaml" \)); do \
		echo " - $$f"; \
		docker compose -f "$$f" config -q; \
	done; \
	echo "✅ All compose files validated successfully."

# ------------------------------------------------------------
# Stack operations
# - If the stack provides tools/nc, delegate to it for richer flow
# - Otherwise, use generic compose (base + override if present)
# ------------------------------------------------------------

# Guard: require STACK for ops
require-stack:
	@if [ -z "$(STACK)" ]; then echo "✖ set stack=<name>"; exit 1; fi

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
	@echo "ℹ '$(STACK)' has no helper; nothing to do."

endif

# ------------------------------------------------------------
# Backups for Nextcloud (explicit targets; do not depend on helper)
# ------------------------------------------------------------

backup: require-stack
	@if [ "$(STACK)" != "nextcloud" ]; then echo "ℹ️ 'backup' is only supported for stack=nextcloud"; exit 0; fi; \
	if [ -z "$(BACKUP_DIR)" ]; then echo "✖ set BACKUP_DIR=/path/to/backups"; exit 1; fi; \
	script="$(STACKS_REPO)/stacks/nextcloud/backup/nc-backup.sh"; \
	[ -n "$(BACKUP_TRACE)" ] && { printf '→ Using script: %s\n' "$$script"; printf '→ Using BACKUP_DIR: %s\n' "$(BACKUP_DIR)"; [ -n "$(BACKUP_ENV)" ] && printf '→ Using BACKUP_ENV: %s\n' "$(BACKUP_ENV)"; }; \
	chmod +x "$$script" 2>/dev/null || true; \
	if [ -n "$(BACKUP_ENV)" ]; then \
		ENV_FILE="$(BACKUP_ENV)" BACKUP_DIR="$(BACKUP_DIR)" bash "$$script"; \
	else \
		BACKUP_DIR="$(BACKUP_DIR)" bash "$$script"; \
	fi

backup-verify: require-stack
	@if [ "$(STACK)" != "nextcloud" ]; then echo "ℹ️ 'backup-verify' is only supported for stack=nextcloud"; exit 0; fi; \
	if [ -z "$(BACKUP_DIR)" ]; then echo "✖ set BACKUP_DIR=/path/to/backups"; exit 1; fi; \
	latest=$$(find "$(BACKUP_DIR)" -maxdepth 1 -type f -name 'nc-*.sha256' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-); \
	if [ -z "$$latest" ]; then echo "No *.sha256 found in $(BACKUP_DIR)"; exit 1; fi; \
	printf '→ Verifying %s\n' "$$latest"; \
	( cd "$(BACKUP_DIR)" && sha256sum -c "$$(basename "$$latest")" )

restore: require-stack
	@if [ "$(STACK)" != "nextcloud" ]; then echo "ℹ️ 'restore' is only supported for stack=nextcloud"; exit 0; fi; \
	if [ -z "$(BACKUP_DIR)" ]; then echo "✖ set BACKUP_DIR=/path/to/backups"; exit 1; fi; \
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
