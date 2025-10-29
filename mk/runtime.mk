# -------- homelab-stacks/mk/runtime.mk --------------------------------
# Core de operaciones para homelab-runtime: up/down/ps/logs/pull/restart
# con auto-plugin por stack (stacks/<stack>/mk/<stack).mk).
# ----------------------------------------------------------------------

# Normaliza parámetro
STACK := $(or $(stack),$(STACK))

# Bases (puedes override desde runtime si cambian rutas)
STACKS_BASE ?= /opt/homelab-stacks
RUNTIME_BASE ?= /opt/homelab-runtime

# Rutas derivadas
STACKS_DIR := $(STACKS_BASE)/stacks/$(STACK)
RUNTIME_DIR := $(RUNTIME_BASE)/stacks/$(STACK)

# Compose cmds estándar
COMPOSE_BASE   = docker compose \
	--project-directory $(RUNTIME_DIR) \
	--env-file          $(RUNTIME_DIR)/.env \
	-f $(STACKS_DIR)/compose.yaml

COMPOSE_MERGED = $(COMPOSE_BASE) \
	-f $(RUNTIME_DIR)/compose.override.yml

# Plugin auto (si existe)
PLUGIN_FILE := $(STACKS_DIR)/mk/$(STACK).mk
-include $(PLUGIN_FILE)
# El plugin puede definir macros como: stack_up, stack_logs, stack_install, stack_post, stack_status, stack_occ

.PHONY: up down ps logs pull restart install post status occ

up:
ifdef stack_up
	$(call stack_up)
else
	$(COMPOSE_MERGED) up -d
endif

down:
	$(COMPOSE_MERGED) down

ps:
	$(COMPOSE_MERGED) ps

logs:
ifdef stack_logs
	$(call stack_logs)
else
	$(COMPOSE_MERGED) logs -f $(service)
endif

pull:
	$(COMPOSE_MERGED) pull

restart:
	$(COMPOSE_MERGED) up -d --force-recreate

install:
ifdef stack_install
	$(call stack_install)
else
	@echo "No custom install for stack='$(STACK)'."
endif

post:
ifdef stack_post
	$(call stack_post)
else
	@echo "No custom post for stack='$(STACK)'."
endif

status:
ifdef stack_status
	$(call stack_status)
else
	@echo "No custom status for stack='$(STACK)'."
endif

# Uso: make occ stack=nextcloud args="user:list"
occ:
ifdef stack_occ
	$(call stack_occ)
else
	@echo "No custom occ for stack='$(STACK)'."
endif
