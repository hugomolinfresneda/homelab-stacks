SHELL := /usr/bin/env bash
# ============================================================
# Homelab Stacks — Public repository
# ============================================================

STACK ?= $(stack)
STACKS_DIR := $(PWD)

help:
	@echo "Available targets:"
	@echo "  make lint                   - Lint YAML and shell scripts"
	@echo "  make validate               - Validate all compose files"
	@echo "  make up stack=<name>        - Launch stack (base only)"
	@echo "  make down stack=<name>      - Stop stack"
	@echo "  make ps stack=<name>        - Show stack status"
	@echo "  make pull stack=<name>      - Pull latest image for the stack"

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
# Helper: compose base (no env or override)
# ------------------------------------------------------------

define compose-cmd
endef

# ------------------------------------------------------------
# Stack operations
# ------------------------------------------------------------

up:

down:

ps:

pull:
