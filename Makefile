# ============================================================
# Homelab Stacks — Public repository
# ============================================================

STACK ?= $(stack)

help:
	@echo "Available targets:"
	@echo "  make lint                   - Run all lint checks"
	@echo "  make validate               - Validate compose files"
	@echo "  make up stack=<name>        - Deploy stack"
	@echo "  make down stack=<name>      - Stop and remove stack"
	@echo "  make ps stack=<name>        - Show status of stack"

# ------------------------------------------------------------
# Lint & validation
# ------------------------------------------------------------

lint:
	@echo "🧹 Linting YAML and shell scripts..."
	yamllint -d "{extends: default, rules: {line-length: disable}}" stacks
	find stacks -type f -name "*.sh" -print0 | xargs -0 -r -n1 shellcheck

validate:
	@echo "🔍 Validating compose files..."
	@for f in $$(find stacks -name 'compose*.yaml'); do \
		echo "Validating $$f"; \
		docker compose -f $$f config > /dev/null || exit 1; \
	done

# ------------------------------------------------------------
# Stack management
# ------------------------------------------------------------

define compose-cmd
	@cd stacks/$(STACK) && docker compose $(1)
endef

up:
	@if [ -z "$(STACK)" ]; then echo "❌ Missing stack name: use make up stack=<name>"; exit 1; fi
	@echo "🚀 Starting stack '$(STACK)'..."
	$(call compose-cmd,up -d)

down:
	@if [ -z "$(STACK)" ]; then echo "❌ Missing stack name: use make down stack=<name>"; exit 1; fi
	@echo "🛑 Stopping stack '$(STACK)'..."
	$(call compose-cmd,down)

ps:
	@if [ -z "$(STACK)" ]; then echo "❌ Missing stack name: use make ps stack=<name>"; exit 1; fi
	@$(call compose-cmd,ps)
