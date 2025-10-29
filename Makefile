SHELL := /usr/bin/env bash
# ============================================================
# Homelab Stacks — Public repository (homelab-stacks)
# ============================================================

# -------- Common vars --------
STACK ?= $(stack)
STACKS_REPO ?= $(PWD)                               # path to this repo
RUNTIME_DIR  ?= $(abspath $(CURDIR)/stacks/$(STACK))# runtime dir when called from homelab-runtime
ENV_FILE     ?= $(RUNTIME_DIR)/.env

BASE_FILE     = $(STACKS_REPO)/stacks/$(STACK)/compose.yaml
OVERRIDE_FILE = $(RUNTIME_DIR)/compose.override.yml

# Docker Compose invocations (base vs base+override)
compose_base = docker compose --project-directory $(RUNTIME_DIR) --env-file $(ENV_FILE) -f $(BASE_FILE)
compose_all  = $(compose_base) -f $(OVERRIDE_FILE)

# Helper detection (e.g., stacks/nextcloud/tools/nc)
STACK_HELPER := $(STACKS_REPO)/stacks/$(STACK)/tools/nc
USE_HELPER   := $(and $(STACK),$(wildcard $(STACK_HELPER)))

.PHONY: help lint validate up down ps pull logs install post status reset-db

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
	@STACKS_REPO=$(STACKS_REPO) RUNTIME_DIR=$(RUNTIME_DIR) $(STACK_HELPER) up

down: require-stack
	@STACKS_REPO=$(STACKS_REPO) RUNTIME_DIR=$(RUNTIME_DIR) $(STACK_HELPER) down

ps: require-stack
	@$(compose_all) ps

pull: require-stack
	@$(compose_base) pull

logs: require-stack
	@STACKS_REPO=$(STACKS_REPO) RUNTIME_DIR=$(RUNTIME_DIR) $(STACK_HELPER) logs

install: require-stack
	@STACKS_REPO=$(STACKS_REPO) RUNTIME_DIR=$(RUNTIME_DIR) $(STACK_HELPER) install

post: require-stack
	@STACKS_REPO=$(STACKS_REPO) RUNTIME_DIR=$(RUNTIME_DIR) $(STACK_HELPER) post

status: require-stack
	@STACKS_REPO=$(STACKS_REPO) RUNTIME_DIR=$(RUNTIME_DIR) $(STACK_HELPER) status

reset-db: require-stack
	@STACKS_REPO=$(STACKS_REPO) RUNTIME_DIR=$(RUNTIME_DIR) $(STACK_HELPER) reset-db

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
