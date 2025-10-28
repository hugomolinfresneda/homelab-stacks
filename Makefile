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
	yamllint -d "{extends: default, rules: {line-length: disable}}" stacks
	@find stacks -type f -name "*.sh" -print0 | xargs -0 -r -n1 shellcheck || true

# ------------------------------------------------------------
# Validate all docker-compose files
# ------------------------------------------------------------

validate:
	@echo "🔍 Validating compose files..."
	@find stacks -type f -name 'compose.yaml' -print0 | while IFS= read -r -d '' f; do \
		echo "  → Validating $$f"; \
		docker compose -f $$f config -q || exit 1; \
	done
	@echo "✅ All compose files validated successfully."

# ------------------------------------------------------------
# Helper: compose base (no env or override)
# ------------------------------------------------------------

define compose-cmd
	@docker compose \
		-f /opt/homelab-stacks/stacks/$(STACK)/compose.yaml \
		$(1)
endef

# ------------------------------------------------------------
# Stack operations
# ------------------------------------------------------------

up:
	@if [ -z "$(STACK)" ]; then echo "❌ Missing stack name: use make up stack=<name>"; exit 1; fi
	@echo "🚀 Starting base stack '$(STACK)'..."
	$(call compose-cmd,up -d)

down:
	@if [ -z "$(STACK)" ]; then echo "❌ Missing stack name: use make down stack=<name>"; exit 1; fi
	@echo "🛑 Stopping base stack '$(STACK)'..."
	$(call compose-cmd,down)

ps:
	@if [ -z "$(STACK)" ]; then echo "❌ Missing stack name: use make ps stack=<name>"; exit 1; fi
	$(call compose-cmd,ps)

pull:
	@if [ -z "$(STACK)" ]; then echo "❌ Missing stack name: use make pull stack=<name>"; exit 1; fi
	@echo "⬇️  Pulling latest image for stack '$(STACK)'..."
	$(call compose-cmd,pull)
