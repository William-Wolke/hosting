# Docker Swarm Hosting Infrastructure
# ====================================
# All commands use the 'envy' docker context to deploy to the remote server.
#
# Initial Setup (run once):
#   1. Configure docker context: docker context create envy --docker "host=ssh://user@host"
#   2. Initialize swarm:         make swarm-init
#   3. Create networks:          make create-networks
#   4. Create secrets:           make create-secrets
#   5. Create configs:           make create-configs
#
# Migration from Docker Compose:
#   1. Backup volumes:           make backup-volumes
#   2. Migrate volume names:     make migrate-volumes
#   3. Stop compose services:    make stop-compose
#   4. Recreate networks:        make recreate-networks
#   5. Deploy as stacks:         make <service>
#
# Usage:
#   make help               Show all available commands
#   make <service>          Deploy/redeploy a service stack
#   make swarm-status       Check swarm and deployed stacks

DOCKER := docker --context envy

.PHONY: help swarm-init swarm-status create-networks stop-compose recreate-networks \
        check-secrets create-secrets create-configs update-configs \
        check-volumes inspect-volumes backup-volumes migrate-volumes \
        mealie searxng caddy caddy-build caddy-reload redbot vaultwarden wg-easy \
        gluetun-qb gluetun-qb-up gluetun-qb-down duckdns copyparty technitium \
        tasks crafty uptime uptime-kuma tech authentik

# =============================================================================
# Help
# =============================================================================

help:
	@echo "Docker Swarm Hosting Infrastructure"
	@echo "===================================="
	@echo ""
	@echo "Swarm Setup (run once):"
	@echo "  swarm-init         Initialize Docker Swarm on remote server"
	@echo "  swarm-status       Check Swarm status and node info"
	@echo "  create-networks    Create overlay networks (proxy-net, wg-easy)"
	@echo ""
	@echo "Migration (compose -> swarm):"
	@echo "  stop-compose       Stop all docker-compose services"
	@echo "  recreate-networks  Remove bridge networks, create overlay networks"
	@echo ""
	@echo "Setup Commands:"
	@echo "  check-secrets    Check which secrets/configs exist vs needed"
	@echo "  create-secrets   Create missing secrets interactively"
	@echo "  create-configs   Create configs from local files"
	@echo "  update-configs   Update all configs (removes and recreates)"
	@echo "  check-volumes    Check volume naming for swarm compatibility"
	@echo "  backup-volumes   Backup volumes before migration"
	@echo "  migrate-volumes  Rename volumes from compose naming to swarm naming"
	@echo ""
	@echo "Service Deployment:"
	@echo "  mealie           Recipe manager"
	@echo "  searxng          Privacy-respecting metasearch engine"
	@echo "  caddy            Reverse proxy (uses existing image)"
	@echo "  caddy-build      Build caddy image and deploy"
	@echo "  caddy-reload     Reload caddy config without restart"
	@echo "  redbot           Discord bot"
	@echo "  vaultwarden      Password manager"
	@echo "  wg-easy          WireGuard VPN management UI"
	@echo "  gluetun-qb       VPN + qBittorrent + Prowlarr (docker-compose, not swarm)"
	@echo "  duckdns          Dynamic DNS updater"
	@echo "  copyparty        File sharing"
	@echo "  uptime-kuma      Uptime monitoring"
	@echo "  tech             Technitium DNS server"
	@echo "  tasks            Task management"
	@echo "  crafty           Minecraft server manager"
	@echo "  authentik        Identity provider / SSO"
	@echo ""
	@echo "Note: gluetun-qb uses docker-compose instead of swarm due to"
	@echo "      network_mode:container dependency (not supported in swarm)"

# =============================================================================
# Swarm Setup (run once during initial setup)
# =============================================================================

# Initialize Docker Swarm on remote server
# Only needs to be run once - idempotent (safe to run multiple times)
swarm-init:
	@echo "Checking Swarm status..."
	@if $(DOCKER) info 2>/dev/null | grep -q "Swarm: active"; then \
		echo "Swarm is already initialized."; \
		$(DOCKER) node ls; \
	else \
		echo "Initializing Swarm..."; \
		$(DOCKER) swarm init; \
		echo "Swarm initialized successfully."; \
	fi

# Check Swarm status and node information
swarm-status:
	@echo "Swarm Status:"
	@$(DOCKER) info 2>/dev/null | grep -E "^(Swarm|NodeID|Is Manager|Managers|Nodes):" || echo "Swarm not initialized"
	@echo ""
	@echo "Nodes:"
	@$(DOCKER) node ls 2>/dev/null || echo "No swarm nodes (swarm not initialized)"
	@echo ""
	@echo "Stacks:"
	@$(DOCKER) stack ls 2>/dev/null || echo "No stacks deployed"

# Create required overlay networks for services
# - proxy-net: shared network for reverse proxy access to services
# - wg-easy: WireGuard VPN network with specific subnet for Technitium DNS
create-networks:
	@echo "Creating overlay networks..."
	@$(DOCKER) network create --driver overlay --attachable proxy-net 2>/dev/null && \
		echo "Created: proxy-net" || \
		echo "Exists:  proxy-net"
	@$(DOCKER) network create --driver overlay --attachable 2>/dev/null && \
		echo "Created: wg-easy" || \
		echo "Exists:  wg-easy"
	@echo ""
	@echo "Networks:"
	@$(DOCKER) network ls --filter driver=overlay

# Stop all docker-compose services before migrating to swarm
# Does NOT stop gluetun-qb (stays on compose)
stop-compose:
	@echo "Stopping all compose services..."
	@echo "(This may show warnings for services not running - that's OK)"
	@echo ""
	-$(DOCKER) compose -f ./caddy/compose.yml down
	-$(DOCKER) compose -f ./authentik/compose.yml down
	-$(DOCKER) compose -f ./searxng/compose.yml down
	-$(DOCKER) compose -f ./vaultwarden/compose.yml down
	-$(DOCKER) compose -f ./uptime-kuma/compose.yml down
	-$(DOCKER) compose -f ./copyparty/compose.yml down
	-$(DOCKER) compose -f ./technitium/compose.yml down
	-$(DOCKER) compose -f ./tasks/compose.yml down
	-$(DOCKER) compose -f ./mealie/compose.yml down
	-$(DOCKER) compose -f ./wg-easy/compose.yml down
	-$(DOCKER) compose -f ./redbot/compose.yml down
	-$(DOCKER) compose -f ./crafty/compose.yml down
	-$(DOCKER) compose -f ./duckdns/compose.yml down
	@echo ""
	@echo "All compose services stopped."
	@echo "Note: gluetun-qb was NOT stopped (stays on docker-compose)"

# Remove old bridge networks and create overlay networks
# Run this after stop-compose and before deploying stacks
recreate-networks:
	@echo "Removing old bridge networks..."
	-$(DOCKER) network rm proxy-net 2>/dev/null && echo "Removed: proxy-net" || echo "proxy-net not found or in use"
	-$(DOCKER) network rm wg-easy 2>/dev/null && echo "Removed: wg-easy" || echo "wg-easy not found or in use"
	@echo ""
	@$(MAKE) create-networks

# =============================================================================
# Secret and Config Management
# =============================================================================

check-secrets:
	./scripts/manage-secrets.sh check

create-secrets:
	./scripts/manage-secrets.sh create

create-configs:
	./scripts/manage-secrets.sh configs

update-configs:
	./scripts/manage-secrets.sh update-configs

# =============================================================================
# Volume Management
# =============================================================================

check-volumes:
	./scripts/migrate-volumes.sh check

inspect-volumes:
	./scripts/migrate-volumes.sh inspect

backup-volumes:
	./scripts/migrate-volumes.sh backup /tmp/volume-backups

migrate-volumes:
	./scripts/migrate-volumes.sh migrate

# =============================================================================
# Services - Core Infrastructure
# =============================================================================

# Reverse proxy - requires caddy-custom:latest image to be built first
caddy:
	$(DOCKER) stack rm caddy || true
	$(DOCKER) stack deploy -c ./caddy/compose.yml caddy

# Build custom caddy image with plugins, then deploy
caddy-build:
	$(DOCKER) build -t caddy-custom:latest ./caddy
	$(DOCKER) stack rm caddy || true
	$(DOCKER) stack deploy -c ./caddy/compose.yml caddy

# Reload caddy configuration without full restart
caddy-reload:
	$(DOCKER) exec $$($(DOCKER) ps -q -f name=caddy_caddy) caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile

# Identity provider / SSO
authentik:
	$(DOCKER) stack rm authentik || true
	$(DOCKER) stack deploy -c ./authentik/compose.yml authentik

# =============================================================================
# Services - Networking
# =============================================================================

# WireGuard VPN with web UI
wg-easy:
	$(DOCKER) stack rm wg-easy || true
	$(DOCKER) stack deploy -c ./wg-easy/compose.yml wg-easy

# DNS server (used by WireGuard clients)
tech:
	$(DOCKER) stack rm technitium || true
	$(DOCKER) stack deploy -c ./technitium/compose.yml technitium

# Dynamic DNS updater
duckdns:
	$(DOCKER) stack rm duckdns || true
	$(DOCKER) stack deploy -c ./duckdns/compose.yml duckdns

# =============================================================================
# Services - Applications
# =============================================================================

# Recipe manager
mealie:
	$(DOCKER) stack rm mealie || true
	$(DOCKER) stack deploy -c ./mealie/compose.yml mealie

# Privacy-respecting search engine
searxng:
	$(DOCKER) stack rm searxng || true
	$(DOCKER) stack deploy -c ./searxng/compose.yml searxng

# Password manager
vaultwarden:
	$(DOCKER) stack rm vaultwarden || true
	$(DOCKER) stack deploy -c ./vaultwarden/compose.yml vaultwarden

# Discord bot
redbot:
	$(DOCKER) stack rm redbot || true
	$(DOCKER) stack deploy -c ./redbot/compose.yml redbot

# File sharing
copyparty:
	$(DOCKER) stack rm copyparty || true
	$(DOCKER) stack deploy -c ./copyparty/compose.yml copyparty

# Uptime monitoring
uptime-kuma:
	$(DOCKER) stack rm uptime-kuma || true
	$(DOCKER) stack deploy -c ./uptime-kuma/compose.yml uptime-kuma

uptime: uptime-kuma

# Task management
tasks:
	$(DOCKER) stack rm tasks || true
	$(DOCKER) stack deploy -c ./tasks/compose.yml tasks

# Minecraft server manager
crafty:
	$(DOCKER) stack rm crafty || true
	$(DOCKER) stack deploy -c ./crafty/compose.yml crafty

# =============================================================================
# Services - Docker Compose (not Swarm compatible)
# =============================================================================

# VPN container with qBittorrent, Prowlarr, FlareSolverr
# Uses network_mode:container which is not supported in Swarm mode
gluetun-qb: gluetun-qb-up

gluetun-qb-up:
	$(DOCKER) compose -f ./gluetun-qb/compose.yml up -d

gluetun-qb-down:
	$(DOCKER) compose -f ./gluetun-qb/compose.yml down

# =============================================================================
# Backup Management
# =============================================================================

# Install vaultwarden backup system on remote server
vaultwarden-backup-install:
	@echo "Installing Vaultwarden backup system..."
	scp ./vaultwarden/scripts/backup.sh william@192.168.0.129:/tmp/
	scp ./vaultwarden/scripts/restore.sh william@192.168.0.129:/tmp/
	scp ./vaultwarden/scripts/vaultwarden-backup.service william@192.168.0.129:/tmp/
	scp ./vaultwarden/scripts/vaultwarden-backup.timer william@192.168.0.129:/tmp/
	ssh -t william@192.168.0.129 "sudo mkdir -p /opt/vaultwarden-backup /var/backups/vaultwarden && \
		sudo mv /tmp/backup.sh /tmp/restore.sh /opt/vaultwarden-backup/ && \
		sudo chmod +x /opt/vaultwarden-backup/*.sh && \
		sudo mv /tmp/vaultwarden-backup.service /tmp/vaultwarden-backup.timer /etc/systemd/system/ && \
		sudo chown -R william:william /var/backups/vaultwarden && \
		sudo systemctl daemon-reload && \
		sudo systemctl enable --now vaultwarden-backup.timer && \
		echo '' && echo 'Backup system installed! Timer status:' && \
		systemctl status vaultwarden-backup.timer --no-pager"

# Run vaultwarden backup manually
vaultwarden-backup:
	ssh william@192.168.0.129 "DOCKER_CONTEXT=local /opt/vaultwarden-backup/backup.sh /var/backups/vaultwarden"

# List vaultwarden backups
vaultwarden-backup-list:
	ssh william@192.168.0.129 "ls -lht /var/backups/vaultwarden/*.tar.gz 2>/dev/null | head -10 || echo 'No backups found'"

# Restore vaultwarden from backup (usage: make vaultwarden-restore BACKUP=filename.tar.gz)
vaultwarden-restore:
	@if [ -z "$(BACKUP)" ]; then echo "Usage: make vaultwarden-restore BACKUP=vaultwarden-backup-YYYYMMDD-HHMMSS.tar.gz"; exit 1; fi
	ssh william@192.168.0.129 "DOCKER_CONTEXT=local /opt/vaultwarden-backup/restore.sh /var/backups/vaultwarden/$(BACKUP)"
