# SPDX-License-Identifier: Apache-2.0
SHELL := /usr/bin/env bash
# homelab-stacks/Makefile
# -------------------------------------------------------------------
# Root Makefile for homelab-stacks
# - Validates compose files
# - Starts/stops stacks (delegates to helper if present)
# - Monitoring helpers (Prometheus/Grafana)
# - Backup helpers (Restic + Nextcloud)
# -------------------------------------------------------------------

# -------- Common vars --------
STACK ?= $(stack)
# Allow PROFILES=monitoring (or multiple: "monitoring debug"); also profiles=... alias
PROFILES ?= $(profiles)
MAKEFILE_PATH := $(abspath $(firstword $(MAKEFILE_LIST)))
MAKEFILE_DIR  := $(patsubst %/,%,$(dir $(MAKEFILE_PATH)))
STACKS_DIR ?= $(MAKEFILE_DIR)
STACKS_REPO ?= $(STACKS_DIR)
RUNTIME_ROOT ?=
RUNTIME_DIR ?= $(if $(RUNTIME_ROOT),$(RUNTIME_ROOT)/stacks/$(STACK),)
STACK_DIR := $(STACKS_REPO)/stacks/$(STACK)
PROJECT_DIR := $(STACK_DIR)
ENV_FILE     ?= $(if $(RUNTIME_DIR),$(RUNTIME_DIR)/.env,)
DB_ENV_FILE  ?= $(if $(RUNTIME_DIR),$(RUNTIME_DIR)/db.env,)
existing_files = $(foreach f,$(strip $(1)),$(if $(wildcard $(f)),$(f),))
ENV_FILES ?= $(ENV_FILE)

ifeq ($(STACK),nextcloud)
ENV_FILES = $(ENV_FILE) $(DB_ENV_FILE)
endif

ENV_FILES_EXISTING := $(call existing_files,$(ENV_FILES))

BASE_FILE := $(STACK_DIR)/compose.yaml
OVERRIDE_CANDIDATES := $(RUNTIME_DIR)/compose.override.yaml $(RUNTIME_DIR)/compose.override.yaml
OVERRIDE_FILE := $(firstword $(call existing_files,$(OVERRIDE_CANDIDATES)))

# Docker Compose invocations (base vs base+override)
# Inject --profile <name> for each item in $(PROFILES). No-op if empty.
compose_base = docker compose --project-directory $(PROJECT_DIR) \
  -f $(BASE_FILE) \
  $(foreach f,$(ENV_FILES_EXISTING),--env-file $(f)) \
  $(foreach p,$(PROFILES),--profile $(p))
compose_all = $(compose_base) $(if $(strip $(OVERRIDE_FILE)),-f $(OVERRIDE_FILE),)

# Helper detection (e.g., stacks/nextcloud/tools/nc)
STACK_HELPER := $(STACKS_REPO)/stacks/$(STACK)/tools/nc
USE_HELPER   := $(and $(STACK),$(wildcard $(STACK_HELPER)))

.PHONY: help lint validate check-abs-paths         up down ps pull logs install post status reset-db echo-vars         backup backup-verify restore         up-mon down-mon ps-mon         restic restic-list restic-check restic-stats restic-forget-dry restic-forget restic-diff restic-restore restic-restore-full restic-mount restic-env restic-show-env restic-exclude-show         check-prom reload-prom         bb-ls bb-add bb-rm print-mon         nc-help nc-up nc-down nc-ps nc-logs nc-install nc-post nc-status nc-reset-db nc-up-mon nc-down-mon nc-ps-mon         check-prom-demo check-am-demo check-demo

# ------------------------------------------------------------
# Human-friendly help
# ------------------------------------------------------------
help:
	@echo "Available targets:"
	@echo "  make lint                         - Lint YAML and shell scripts"
	@echo "  make validate                     - Validate all compose files"
	@echo "  make up stack=<name>              - Launch stack (delegates to helper if present)"
	@echo "       (add PROFILES=monitoring to include exporters, if the stack defines them)"
	@echo "  make down stack=<name>            - Stop stack"
	@echo "  make ps stack=<name>              - Show stack status (project name = stack)"
	@echo "  make pull stack=<name>            - Pull images for the stack"
	@echo "  make logs stack=<name> [follow=true]- Show/follow logs (if helper present uses it)"
	@echo "  make install|post|status|reset-db - Extra ops (only if the stack ships a helper)"
	@echo "  make backup stack=restic          - Run Restic infra backup via systemd (root)"
	@echo "  make backup stack=nextcloud BACKUP_DIR=...</path> [BACKUP_ENV=\${RUNTIME_ROOT}/ops/backups/nc-backup.env]"
	@echo "  make backup-verify stack=nextcloud BACKUP_DIR=...</path>"
	@echo "  make restore stack=nextcloud BACKUP_DIR=...</path> [BACKUP_TS=YYYY-MM-DD_HHMMSS] [TARGET=/path]"
	@echo "       (in-place requires RUNTIME_DIR=... ALLOW_INPLACE=1)"
	@echo ""
	@echo "Shortcuts with monitoring profile:"
	@echo "  make up-mon|down-mon|ps-mon stack=<name>  - Same as up/down/ps with PROFILES=monitoring"
	@echo ""
	@echo "Nextcloud shortcuts (friendly aliases):"
	@echo "  make nc-help                      - Show Nextcloud-specific commands"
	@echo ""
	@echo "Monitoring (Prometheus/Grafana) helpers:"
	@echo "  make check-prom                   - promtool check config (mon)"
	@echo "  make reload-prom                  - send HUP to prometheus (monitoring stack)"
	@echo "  make bb-ls  [JOB=blackbox-http] BB_TARGETS_MAP=... - List targets in mon (runtime only)"
	@echo "  make bb-add JOB=... TARGET=... BB_TARGETS_MAP=...  - Add target in mon (runtime only)"
	@echo "  make bb-rm  JOB=... TARGET=... BB_TARGETS_MAP=...  - Remove target in mon (runtime only)"
	@echo ""
	@echo "Restic (infra dual-repo) helpers:"
	@echo "  make backup stack=restic          - Run Restic backup via systemd (uses $(RESTIC_ENV_FILE))"
	@echo "  make restic-list                  - Show snapshots"
	@echo "  make restic-check                 - Check repository integrity"
	@echo "  make restic-stats                 - Show repository stats"
	@echo "  make restic-forget                - Apply retention now (delete & prune)"
	@echo "  make restic-forget-dry            - Preview retention (no changes)"
	@echo "  make restic-diff [A=.. B=..]      - Diff between two snapshots"
	@echo "  make restic-restore INCLUDE=\"/path ...\" [TARGET=dir] - Selective restore"
	@echo "  make restic-restore-full          - Restore exactly BACKUP_PATHS to TARGET (default staging dir); TARGET=/ requires ALLOW_INPLACE=1"
	@echo "  make restic-mount [MOUNTPOINT=dir]- Mount repository via FUSE"

# ------------------------------------------------------------
# Lint YAML and shell scripts
# ------------------------------------------------------------
lint:
	@echo "Linting YAML and shell scripts..."
	yamllint -d "{extends: default, rules: {line-length: disable, document-start: disable, comments-indentation: disable}}" stacks
	@find stacks -type f -name "*.sh" -print0 | xargs -0 -r -n1 shellcheck || true

# ------------------------------------------------------------
# Guardrail: avoid hardcoded homelab paths under /opt in runtime
# ------------------------------------------------------------
check-abs-paths:
	@echo "Checking for hardcoded /opt homelab paths..."
	@pat="/opt/homelab"'-'; \
	if command -v rg >/dev/null 2>&1; then \
	  if rg -n --hidden --no-ignore-vcs "$$pat" Makefile ops stacks .github \
	    -g "Makefile" -g "*.sh" -g "*.yaml" -g "*.yaml"; then \
	    echo "error: hardcoded /opt homelab paths found (see matches above)"; \
	    exit 1; \
	  fi; \
	else \
	  if grep -R -n -E "$$pat" Makefile ops stacks .github \
	    --include "Makefile" --include "*.sh" --include "*.yaml" --include "*.yaml"; then \
	    echo "error: hardcoded /opt homelab paths found (see matches above)"; \
	    exit 1; \
	  fi; \
	fi; \
	echo "OK: no hardcoded /opt homelab paths found."

# ------------------------------------------------------------
# Validate all docker-compose files
# ------------------------------------------------------------
validate:
	@echo "Validating compose files..."
	@set -eu; \
	for f in $$(find stacks -type f \( -name "compose.yaml" -o -name "compose.yaml" \)); do \
		echo " - $$f"; \
		docker compose -f "$$f" config -q; \
	done; \
	echo "All compose files validated successfully."

# ------------------------------------------------------------
# Stack operations
# - If the stack provides tools/nc, delegate to it for richer flow
# - Otherwise, use generic compose (base + override if present)
# ------------------------------------------------------------

# Guard: require STACK for ops
require-stack:
	@if [ -z "$(STACK)" ]; then echo "error: set stack=<name>"; exit 1; fi

require-runtime-root:
	@if [ -z "$(RUNTIME_ROOT)" ] && [ -z "$(RUNTIME_DIR)" ]; then \
		echo "error: set RUNTIME_ROOT=/abs/path/to/homelab-runtime (required for runtime ops)"; \
		exit 1; \
	fi

# -------- Delegated path (helper present) --------
ifeq ($(USE_HELPER),$(STACK_HELPER))

up: require-stack require-runtime-root
	@STACKS_REPO=$(STACKS_REPO) RUNTIME_DIR=$(RUNTIME_DIR) PROFILES="$(PROFILES)" ENV_FILES="$(ENV_FILES)" "$(STACK_HELPER)" up

down: require-stack require-runtime-root
	@STACKS_REPO=$(STACKS_REPO) RUNTIME_DIR=$(RUNTIME_DIR) PROFILES="$(PROFILES)" ENV_FILES="$(ENV_FILES)" "$(STACK_HELPER)" down

ps: require-stack require-runtime-root
	@$(compose_all) ps

pull: require-stack require-runtime-root
	@$(compose_base) pull

logs: require-stack require-runtime-root
	@STACKS_REPO=$(STACKS_REPO) RUNTIME_DIR=$(RUNTIME_DIR) PROFILES="$(PROFILES)" ENV_FILES="$(ENV_FILES)" "$(STACK_HELPER)" logs

install: require-stack require-runtime-root
	@STACKS_REPO=$(STACKS_REPO) RUNTIME_DIR=$(RUNTIME_DIR) PROFILES="$(PROFILES)" ENV_FILES="$(ENV_FILES)" "$(STACK_HELPER)" install

post: require-stack require-runtime-root
	@STACKS_REPO=$(STACKS_REPO) RUNTIME_DIR=$(RUNTIME_DIR) PROFILES="$(PROFILES)" ENV_FILES="$(ENV_FILES)" "$(STACK_HELPER)" post

status: require-stack require-runtime-root
	@STACKS_REPO=$(STACKS_REPO) RUNTIME_DIR=$(RUNTIME_DIR) PROFILES="$(PROFILES)" ENV_FILES="$(ENV_FILES)" "$(STACK_HELPER)" status

reset-db: require-stack require-runtime-root
	@STACKS_REPO=$(STACKS_REPO) RUNTIME_DIR=$(RUNTIME_DIR) PROFILES="$(PROFILES)" ENV_FILES="$(ENV_FILES)" "$(STACK_HELPER)" reset-db

# -------- Generic path (no helper) --------
else

up: require-stack require-runtime-root
	@$(compose_all) up -d

down: require-stack require-runtime-root
	@$(compose_all) down

ps: require-stack require-runtime-root
	@$(compose_all) ps

pull: require-stack require-runtime-root
	@$(compose_base) pull

logs: require-stack require-runtime-root
	@if [ "$(follow)" = "true" ]; then \
		$(compose_all) logs -f; \
	else \
		$(compose_all) logs --tail=100; \
	fi

# No-op extras when there is no helper
install post status reset-db: require-stack require-runtime-root
	@echo "info: '$(STACK)' has no helper; nothing to do."

endif

# ------------------------------------------------------------
# Shortcuts with monitoring profile (generic)
# ------------------------------------------------------------
up-mon: require-stack
	@PROFILES="monitoring" $(MAKE) up stack=$(STACK)
down-mon: require-stack
	@PROFILES="monitoring" $(MAKE) down stack=$(STACK)
ps-mon: require-stack
	@PROFILES="monitoring" $(MAKE) ps stack=$(STACK)

# ------------------------------------------------------------
# Backups
# - Unified entrypoint for infra (Restic) + app (Nextcloud)
# - Validation & restore helpers for Nextcloud backups
# ------------------------------------------------------------
backup: require-stack
	@if [ -z "$(STACK)" ]; then \
		echo "error: set stack=restic|nextcloud"; \
		exit 1; \
	fi; \
	if [ "$(STACK)" = "restic" ]; then \
		echo "→ [backup] Running Restic backup via systemd (stack=restic)"; \
		$(MAKE) restic; \
	elif [ "$(STACK)" = "nextcloud" ]; then \
		if [ -z "$(BACKUP_DIR)" ]; then \
			echo "error: set BACKUP_DIR=/path/to/backups (e.g. /mnt/backups/nextcloud)"; \
			exit 1; \
		fi; \
		script="$(STACKS_REPO)/stacks/nextcloud/backup/nc-backup.sh"; \
		[ -n "$(BACKUP_TRACE)" ] && { \
		  printf '→ Using script: %s\n' "$$script"; \
		  printf '→ Using BACKUP_DIR: %s\n' "$(BACKUP_DIR)"; \
		  [ -n "$(BACKUP_ENV)" ] && printf '→ Using BACKUP_ENV: %s\n' "$(BACKUP_ENV)"; \
		}; \
		chmod +x "$$script" 2>/dev/null || true; \
		if [ -n "$(BACKUP_ENV)" ]; then \
		  BACKUP_DIR="$(BACKUP_DIR)" ENV_FILE="$(BACKUP_ENV)" bash "$$script"; \
		else \
		  BACKUP_DIR="$(BACKUP_DIR)" bash "$$script"; \
		fi; \
	else \
		echo "error: unsupported stack=$(STACK) (expected restic|nextcloud)"; \
		exit 1; \
	fi

backup-verify: require-stack
	@if [ "$(STACK)" != "nextcloud" ]; then \
		echo "info: 'backup-verify' is only supported for stack=nextcloud"; \
		exit 0; \
	fi; \
	if [ -z "$(BACKUP_DIR)" ]; then \
		echo "error: set BACKUP_DIR=/path/to/backups"; \
		exit 1; \
	fi; \
	latest=$$(find "$(BACKUP_DIR)" -maxdepth 1 -type f -name 'nc-*.sha256' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-); \
	if [ -z "$$latest" ]; then \
		echo "No *.sha256 found in $(BACKUP_DIR)"; \
		exit 1; \
	fi; \
	printf '→ Verifying %s\n' "$$latest"; \
	( cd "$(BACKUP_DIR)" && sha256sum -c "$$([ -n "$$latest" ] && basename "$$latest")" )

restore: require-stack
	@if [ "$(STACK)" != "nextcloud" ]; then \
		echo "info: 'restore' is only supported for stack=nextcloud"; \
		exit 0; \
	fi; \
	if [ -z "$(BACKUP_DIR)" ]; then \
		echo "error: set BACKUP_DIR=/path/to/backups"; \
		exit 1; \
	fi; \
	script="$(STACKS_REPO)/stacks/nextcloud/backup/nc-restore.sh"; \
	compose="$(BASE_FILE)"; \
	[ -n "$(BACKUP_TRACE)" ] && { \
	  printf '→ Using script: %s\n' "$$script"; \
	  printf '→ Using compose: %s\n' "$$compose"; \
	  printf '→ Using BACKUP_DIR: %s\n' "$(BACKUP_DIR)"; \
	  [ -n "$(BACKUP_TS)" ] && printf '→ Using BACKUP_TS: %s\n' "$(BACKUP_TS)"; \
	  [ -n "$(TARGET)" ] && printf '→ Using TARGET: %s\n' "$(TARGET)"; \
	  [ -n "$(RUNTIME_DIR)" ] && printf '→ Using RUNTIME_DIR: %s\n' "$(RUNTIME_DIR)"; \
	  [ -n "$(ALLOW_INPLACE)" ] && printf '→ Using ALLOW_INPLACE: %s\n' "$(ALLOW_INPLACE)"; \
	}; \
	chmod +x "$$script" 2>/dev/null || true; \
	COMPOSE_FILE="$$compose" \
	RUNTIME_DIR="$(RUNTIME_DIR)" \
	BACKUP_DIR="$(BACKUP_DIR)" \
	BACKUP_TS="$(BACKUP_TS)" \
	TARGET="$(TARGET)" \
	ALLOW_INPLACE="$(ALLOW_INPLACE)" \
	bash "$$script"

# ------------------------------------------------------------
# Restic helpers (dual-repo infra backups via ops/backups/restic-backup.sh)
# ------------------------------------------------------------

# restic — shared config for all restic targets
RESTIC_ENV_FILE        ?= $(if $(RUNTIME_ROOT),$(RUNTIME_ROOT)/ops/backups/restic.env,)
RESTIC_SCRIPT          ?= $(STACKS_REPO)/ops/backups/restic-backup.sh
RESTIC_SYSTEMD_SERVICE ?= homelab-restic-backup.service

# restic — Run full backup via systemd as root (oneshot service)
restic: require-runtime-root
	@test -f "$(RESTIC_ENV_FILE)" || { echo "error: missing RESTIC_ENV_FILE=$(RESTIC_ENV_FILE)"; exit 1; }
	@echo "→ [restic] Launching backup via systemd as root: $(RESTIC_SYSTEMD_SERVICE)"
	@sudo systemctl start "$(RESTIC_SYSTEMD_SERVICE)"

# restic-list — List snapshots in the configured repository (root)
restic-list: require-runtime-root
	@sudo bash -lc 'set -ae; . "$(RESTIC_ENV_FILE)"; set +a; restic snapshots'

# restic-check — Verify repository integrity (root)
restic-check: require-runtime-root
	@sudo bash -lc 'set -ae; . "$(RESTIC_ENV_FILE)"; set +a; restic check'

# restic-stats — Show repository statistics (root)
restic-stats: require-runtime-root
	@sudo bash -lc 'set -ae; . "$(RESTIC_ENV_FILE)"; set +a; restic stats'

# restic-forget — Apply retention policy (delete & prune) as defined in .env (root)
restic-forget: require-runtime-root
	@sudo bash -lc 'set -euo pipefail; set -a; . "$(RESTIC_ENV_FILE)"; set +a; \
	  args=(--prune); \
	  [[ -n "$${RESTIC_GROUP_BY:-}"    ]] && args+=(--group-by "$$RESTIC_GROUP_BY"); \
	  [[ -n "$${RESTIC_KEEP_DAILY:-}"   ]] && args+=(--keep-daily   "$$RESTIC_KEEP_DAILY"); \
	  [[ -n "$${RESTIC_KEEP_WEEKLY:-}"  ]] && args+=(--keep-weekly  "$$RESTIC_KEEP_WEEKLY"); \
	  [[ -n "$${RESTIC_KEEP_MONTHLY:-}" ]] && args+=(--keep-monthly "$$RESTIC_KEEP_MONTHLY"); \
	  echo "→ restic forget: $${args[*]}"; \
	  restic forget "$${args[@]}"'

# restic-forget-dry — Simulate retention (no deletions), for safety review (root)
restic-forget-dry: require-runtime-root
	@sudo bash -lc 'set -euo pipefail; set -a; . "$(RESTIC_ENV_FILE)"; set +a; \
	  args=(--prune --dry-run); \
	  [[ -n "$${RESTIC_GROUP_BY:-}"    ]] && args+=(--group-by "$$RESTIC_GROUP_BY"); \
	  [[ -n "$${RESTIC_KEEP_DAILY:-}"   ]] && args+=(--keep-daily   "$$RESTIC_KEEP_DAILY"); \
	  [[ -n "$${RESTIC_KEEP_WEEKLY:-}"  ]] && args+=(--keep-weekly  "$$RESTIC_KEEP_WEEKLY"); \
	  [[ -n "$${RESTIC_KEEP_MONTHLY:-}" ]] && args+=(--keep-monthly "$$RESTIC_KEEP_MONTHLY"); \
	  echo "→ restic forget (dry-run): $${args[*]}"; \
	  restic forget "$${args[@]}"'

# restic-diff — Compare two snapshots (or last two if jq present) (root)
restic-diff: require-runtime-root
	@A="$(A)" B="$(B)" sudo bash -lc 'set -euo pipefail; set -a; . "$(RESTIC_ENV_FILE)"; set +a; \
	  A_ID="$${A:-}"; B_ID="$${B:-}"; \
	  if command -v jq >/dev/null 2>&1 && [ -z "$$A_ID" ] && [ -z "$$B_ID" ]; then \
	    ids=$$(restic snapshots --json | jq -r "sort_by(.time) | map(.short_id) | .[-2:] | @tsv"); \
	    read -r A_ID B_ID <<< "$$ids"; \
	  fi; \
	  if [ -z "$$A_ID" ] || [ -z "$$B_ID" ]; then \
	    echo "error: set A=<id> and B=<id> (or install jq for auto-detection)"; exit 1; \
	  fi; \
	  echo "→ restic diff $$A_ID $$B_ID"; \
	  restic diff "$$A_ID" "$$B_ID"'

# restic-restore — Selective restore from latest snapshot into target dir (root)
# Usage: make restic-restore INCLUDE="/path1 /path2" [TARGET=/path/to/dir]
restic-restore: require-runtime-root
	@INCLUDE="$(INCLUDE)" TARGET="$(TARGET)" sudo bash -lc 'set -euo pipefail; set -a; . "$(RESTIC_ENV_FILE)"; set +a; \
	  target="$${TARGET:-}"; includes="$${INCLUDE:-}"; \
	  if [ -z "$$includes" ]; then echo "error: set INCLUDE=\"/path /path2 ...\""; exit 1; fi; \
	  if [ -z "$$target" ]; then target=$$(mktemp -d -t restic-restore.XXXXXX); echo "→ TARGET not set; using $$target"; fi; \
	  IFS=" " read -r -a arr <<< "$$includes"; \
	  args=(); for p in "$${arr[@]}"; do args+=(--include "$$p"); done; \
	  echo "→ Restoring from latest into: $$target"; \
	  restic restore latest --target "$$target" "$${args[@]}"; \
	  echo "→ Done. Restored to: $$target"'

# restic-restore-full — Restore all paths in BACKUP_PATHS into a target dir (root)
# Usage: make restic-restore-full [SNAPSHOT=latest] [TARGET=/path/to/dir] [ALLOW_INPLACE=1]
restic-restore-full: require-runtime-root
	@SNAPSHOT="$(SNAPSHOT)" TARGET="$(TARGET)" ALLOW_INPLACE="$(ALLOW_INPLACE)" sudo bash -lc 'set -euo pipefail; set -a; . "$(RESTIC_ENV_FILE)"; set +a; \
	  snap="$${SNAPSHOT:-latest}"; \
	  target="$${TARGET:-}"; \
	  if ! declare -p BACKUP_PATHS >/dev/null 2>&1; then \
	    echo "error: BACKUP_PATHS not defined in $$RESTIC_ENV_FILE"; exit 1; \
	  fi; \
	  if ! declare -p BACKUP_PATHS 2>/dev/null | grep -q "declare -a"; then \
	    echo "error: BACKUP_PATHS must be a bash array in $$RESTIC_ENV_FILE"; exit 1; \
	  fi; \
	  if [ -z "$$target" ]; then \
	    target=$$(mktemp -d -t restic-restore-full.XXXXXX); \
	    echo "→ TARGET not set; using $$target"; \
	  fi; \
	  if [ "$$target" = "/" ] && [ "$${ALLOW_INPLACE:-}" != "1" ]; then \
	    echo "error: TARGET=/ requires ALLOW_INPLACE=1"; exit 1; \
	  fi; \
	  args=(); includes=(); \
	  for p in "$${BACKUP_PATHS[@]}"; do \
	    [ -n "$$p" ] || continue; \
	    orig="$$p"; \
	    p="$${p#/}"; \
	    if [ "$$orig" != "$$p" ]; then \
	      echo "→ warn: stripped leading slash: $$orig -> $$p"; \
	    fi; \
	    includes+=("$$p"); \
	    args+=(--include "$$p"); \
	  done; \
	  if [ "$${#includes[@]}" -eq 0 ]; then \
	    echo "error: BACKUP_PATHS is empty"; exit 1; \
	  fi; \
	  echo "→ restic restore plan:"; \
	  echo "  snapshot: $$snap"; \
	  echo "  target: $$target"; \
	  echo "  includes:"; \
	  printf "    - %s\n" "$${includes[@]}"; \
	  restic restore "$$snap" --target "$$target" "$${args[@]}"; \
	  echo "→ Done. Restored to: $$target"'

# restic-mount — FUSE-mount repository for browsing (background) (root)
# Usage: make restic-mount [MOUNTPOINT=~/mnt/restic]
restic-mount: require-runtime-root
	@set -euo pipefail; \
	mp="$${MOUNTPOINT:-$$HOME/mnt/restic}"; \
	mkdir -p "$$mp"; \
	echo "Mounting repository on $$mp (background). Unmount with: sudo fusermount -u $$mp"; \
	sudo bash -lc 'set -euo pipefail; set -a; . "$(RESTIC_ENV_FILE)"; set +a; \
	  mp='"'"'"$$mp"'"'"'; \
	  nohup bash -lc '"'"'set -ae; . "$(RESTIC_ENV_FILE)"; set +a; exec restic mount "'"'"'"$$mp"'"'"'"'"'"' >/dev/null 2>&1 & \
	  echo "PID=$$!"'

# restic-env — Alias for restic-show-env (root)
restic-env: restic-show-env

# restic-show-env — Print effective repo, policy and Kuma URL (root)
restic-show-env: require-runtime-root
	@sudo bash -lc 'set -ae; . "$(RESTIC_ENV_FILE)"; set +a; \
	  ef="$${EXCLUDE_FILE:-$${RESTIC_EXCLUDE_FILE:-$${RESTIC_EXCLUDES_FILE:-$(STACKS_REPO)/ops/backups/exclude.txt}}}"; \
	  printf "RESTIC_REPOSITORY=%s\n" "$$RESTIC_REPOSITORY"; \
	  printf "RESTIC_GROUP_BY=%s\n" "$${RESTIC_GROUP_BY:-<unset>}"; \
	  printf "KEEP: daily=%s weekly=%s monthly=%s\n" "$${RESTIC_KEEP_DAILY:-}" "$${RESTIC_KEEP_WEEKLY:-}" "$${RESTIC_KEEP_MONTHLY:-}"; \
	  printf "KUMA_PUSH_URL=%s\n" "$${KUMA_PUSH_URL:-<unset>}"; \
	  printf "EXCLUDE_FILE=%s\n" "$$ef"; '

# restic-exclude-show — Print active exclude file contents (root)
restic-exclude-show: require-runtime-root
	@sudo bash -lc 'ef="$${EXCLUDE_FILE:-$${RESTIC_EXCLUDE_FILE:-$${RESTIC_EXCLUDES_FILE:-$(STACKS_REPO)/ops/backups/exclude.txt}}}"; \
	  if [ -f "$$ef" ]; then echo "→ Exclude file: $$ef"; cat "$$ef"; else echo "No exclude file found at: $$ef"; fi'

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
PROM_FILE_MON_REL  := prometheus/prometheus.yaml
promtool = docker run --rm -v "$(MON_STACK_DIR)":/workdir -w /workdir --entrypoint /bin/promtool prom/prometheus:latest

# ---- promtool checks (mon) ----
# ---- promtool checks (mon) ----
check-prom:
	@cd "$(MON_STACK_DIR)" && \
	  f="prometheus/prometheus.yaml"; [ -f "$$f" ] || f="prometheus/prometheus.yaml"; \
	  [ -f "$$f" ] || { echo "error: no prometheus.(yml|yaml) in $(MON_STACK_DIR)/prometheus"; exit 1; }; \
	  $(promtool) check config "$$f"

# ---- reload via HUP (mon) ----
reload-prom: STACK=monitoring
reload-prom: require-runtime-root
reload-prom:
	@STACK=monitoring $(compose_all) exec -T prometheus kill -HUP 1 >/dev/null 2>&1 || \
	  { echo "warn: could not send HUP to prometheus (is it running?)"; exit 1; }
	@echo "Reload sent to prometheus"

# ---- blackbox targets (wrappers over stacks/monitoring/scripts/blackbox-targets.sh) ----
# Variables: JOB (defaults to blackbox-http), TARGET (required for add/rm)
JOB ?= blackbox-http
TARGET ?=
BB_TARGETS_MAP ?=

bb-ls:
	@if [ -z "$(BB_TARGETS_MAP)" ]; then echo "error: set BB_TARGETS_MAP with --targets-file job=path (runtime targets required)"; exit 1; fi
	@f="$(MON_STACK_DIR)/prometheus/prometheus.yaml"; [ -f "$$f" ] || f="$(MON_STACK_DIR)/prometheus/prometheus.yaml"; \
	  [ -f "$$f" ] || { echo "error: no prometheus.(yml|yaml) in $(MON_STACK_DIR)/prometheus"; exit 1; }; \
	  "$(MON_STACK_DIR)/scripts/blackbox-targets.sh" --file "$$f" $(BB_TARGETS_MAP) ls "$(JOB)"

bb-add:
	@if [ -z "$(TARGET)" ]; then echo "error: set TARGET=..."; exit 1; fi
	@if [ -z "$(BB_TARGETS_MAP)" ]; then echo "error: set BB_TARGETS_MAP with --targets-file job=path (runtime targets required)"; exit 1; fi
	@f="$(MON_STACK_DIR)/prometheus/prometheus.yaml"; [ -f "$$f" ] || f="$(MON_STACK_DIR)/prometheus/prometheus.yaml"; \
	  [ -f "$$f" ] || { echo "error: no prometheus.(yml|yaml) in $(MON_STACK_DIR)/prometheus"; exit 1; }; \
	  "$(MON_STACK_DIR)/scripts/blackbox-targets.sh" --file "$$f" $(BB_TARGETS_MAP) add "$(JOB)" "$(TARGET)"

bb-rm:
	@if [ -z "$(TARGET)" ]; then echo "error: set TARGET=..."; exit 1; fi
	@if [ -z "$(BB_TARGETS_MAP)" ]; then echo "error: set BB_TARGETS_MAP with --targets-file job=path (runtime targets required)"; exit 1; fi
	@f="$(MON_STACK_DIR)/prometheus/prometheus.yaml"; [ -f "$$f" ] || f="$(MON_STACK_DIR)/prometheus/prometheus.yaml"; \
	  [ -f "$$f" ] || { echo "error: no prometheus.(yml|yaml) in $(MON_STACK_DIR)/prometheus"; exit 1; }; \
	  "$(MON_STACK_DIR)/scripts/blackbox-targets.sh" --file "$$f" $(BB_TARGETS_MAP) rm "$(JOB)" "$(TARGET)"

print-mon:
	@printf 'STACKS_REPO=%s\nMON_STACK_DIR=%s\n' '$(STACKS_REPO)' '$(MON_STACK_DIR)'

# -------------------------------------------------------------------
# Nextcloud namespaced aliases (discoverable & grouped)
# -------------------------------------------------------------------
nc-help:
	@echo "Nextcloud shortcuts:"
	@echo "  make nc-up              - Start Nextcloud (db, redis, app, web, cron)"
	@echo "  make nc-up-mon          - Start Nextcloud + monitoring exporters"
	@echo "  make nc-down            - Stop Nextcloud (auto-includes monitoring if running)"
	@echo "  make nc-down-mon        - Stop Nextcloud, explicitly including monitoring"
	@echo "  make nc-ps              - Show Nextcloud containers"
	@echo "  make nc-ps-mon          - Show Nextcloud containers with monitoring profile"
	@echo "  make nc-logs [follow=true] - Tail app logs"
	@echo "  make nc-install         - One-off post-deploy install/seed"
	@echo "  make nc-post            - Post configuration (cron, trusted_domains, etc.)"
	@echo "  make nc-status          - Print Nextcloud status and HTTP checks"
	@echo "  make nc-reset-db        - Drop DB volume only (app data remains)"
	@echo "  make backup stack=nextcloud BACKUP_DIR=/path [BACKUP_ENV=\${RUNTIME_ROOT}/ops/backups/nc-backup.env] - Backup (db + data) with checksum"
	@echo "  make backup-verify stack=nextcloud BACKUP_DIR=/path - Verify last backup checksum"
	@echo "  make restore stack=nextcloud BACKUP_DIR=/path [BACKUP_TS=YYYY-MM-DD_HHMMSS] [TARGET=/path]"
	@echo "       (in-place requires RUNTIME_DIR=\${RUNTIME_ROOT}/stacks/nextcloud ALLOW_INPLACE=1)"

# Core lifecycle
nc-up:          ; @$(MAKE) up          stack=nextcloud
nc-down:        ; @$(MAKE) down        stack=nextcloud
nc-ps:          ; @$(MAKE) ps          stack=nextcloud
nc-logs:        ; @$(MAKE) logs        stack=nextcloud follow=$(follow)
nc-install:     ; @$(MAKE) install     stack=nextcloud
nc-post:        ; @$(MAKE) post        stack=nextcloud
nc-status:      ; @$(MAKE) status      stack=nextcloud
nc-reset-db:    ; @$(MAKE) reset-db    stack=nextcloud

# With monitoring profile
nc-up-mon:      ; @PROFILES=monitoring $(MAKE) up   stack=nextcloud
nc-down-mon:    ; @PROFILES=monitoring $(MAKE) down stack=nextcloud
nc-ps-mon:      ; @PROFILES=monitoring $(MAKE) ps   stack=nextcloud


# CI compatibility: demo config checks are implemented in stacks/monitoring/Makefile.demo
check-prom-demo check-am-demo:
	@$(MAKE) -f stacks/monitoring/Makefile.demo demo-check

# Convenience meta-target
check-demo: check-prom-demo
