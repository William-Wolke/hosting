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
        mealie searxng caddy caddy-build caddy-reload caddy-env redbot vaultwarden \
        gluetun-qb gluetun-qb-up gluetun-qb-down copyparty technitium \
        tasks crafty uptime uptime-kuma tech coredns authentik homeassistant \
	podman-volume-backup-install immich immich-env immich-pull immich-status immich-gpu-info \
	mealie mealie-env mealie-migrate mealie-status \
	wg-easy wg-easy-env wg-easy-status \
	duckdns duckdns-env duckdns-status
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
	@echo "  caddy            Deploy Quadlet units for caddy + crowdsec"
	@echo "  caddy-build      Build caddy image on remote host, then deploy"
	@echo "  caddy-reload     Reload caddy config without full restart"
	@echo "  caddy-env        Upload remotes .env file for caddy"
	@echo "  redbot           Discord bot"
	@echo "  vaultwarden      Password manager"
	@echo "  wg-easy          WireGuard VPN management UI"
	@echo "  gluetun-qb       VPN + qBittorrent + Prowlarr (docker-compose, not swarm)"
	@echo "  duckdns          Dynamic DNS updater"
	@echo "  copyparty        File sharing"
	@echo "  uptime-kuma      Uptime monitoring"
	@echo "  tasks            Task management"
	@echo "  crafty           Minecraft server manager"
	@echo "  authentik        Identity provider / SSO"
	@echo "  immich           Deploy Quadlet units for immich (server, ML, postgres, valkey)"
	@echo "  immich-env       Upload immich/.immich.env to /etc/immich/.immich.env"
	@echo "  immich-pull      Pre-pull immich images"
	@echo "  immich-status    Show status of all immich units"
	@echo "  immich-gpu-info  Show AMD GPU devices + gfx target for HSA_OVERRIDE_GFX_VERSION"
	@echo "  mealie           Deploy Quadlet units for mealie"
	@echo "  mealie-env       Upload /etc/mealie/.mealie.env"
	@echo "  mealie-migrate   Backup and migrate old Docker volume to Podman volume"
	@echo "  mealie-status    Show Mealie service status"
	@echo "  wg-easy          Deploy Quadlet units for wg-easy"
	@echo "  wg-easy-env      Upload wg-easy/.wg-easy.env to /etc/wg-easy/.wg-easy.env"
	@echo "  wg-easy-status   Show wg-easy service status"
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
	@$(DOCKER) network create --driver overlay --attachable wg-easy 2>/dev/null && \
		echo "Created: wg-easy" || \
		echo "Exists:  wg-easy"

	@$(DOCKER) network create --driver overlay --attachable caddy_crowdsec 2>/dev/null && \
		echo "Created: caddy_crowdsec" || \
		echo "Exists:  caddy_crowdsec"
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
	scp ./caddy/caddy.container ./caddy/crowdsec.container \
		./caddy/caddy-data.volume ./caddy/caddy-config.volume ./caddy/caddy-logs.volume \
		./caddy/proxy-net.network ./caddy/crowdsec-db.volume ./caddy/crowdsec.network \
		./caddy/conf/Caddyfile ./caddy/crowdsec/acquis.yaml \
		william@192.168.0.129:/tmp/
	ssh -t william@192.168.0.129 '\
		sudo mkdir -p /etc/caddy /etc/crowdsec /etc/containers/systemd && \
		sudo install -Dm644 /tmp/caddy.container /etc/containers/systemd/caddy.container && \
		sudo install -Dm644 /tmp/crowdsec.container /etc/containers/systemd/crowdsec.container && \
		sudo install -Dm644 /tmp/caddy-data.volume /etc/containers/systemd/caddy-data.volume && \
		sudo install -Dm644 /tmp/caddy-config.volume /etc/containers/systemd/caddy-config.volume && \
		sudo install -Dm644 /tmp/caddy-logs.volume /etc/containers/systemd/caddy-logs.volume && \
		sudo install -Dm644 /tmp/crowdsec-db.volume /etc/containers/systemd/crowdsec-db.volume && \
	sudo install -Dm644 /tmp/crowdsec.network /etc/containers/systemd/crowdsec.network && \
	sudo install -Dm644 /tmp/proxy-net.network /etc/containers/systemd/proxy-net.network && \
		sudo install -Dm644 /tmp/Caddyfile /etc/caddy/Caddyfile && \
		sudo install -Dm644 /tmp/acquis.yaml /etc/crowdsec/acquis.yaml && \
		sudo systemctl daemon-reload && \
		sudo systemctl restart crowdsec.service && \
		sudo systemctl restart caddy.service && \
		sudo systemctl status crowdsec.service --no-pager && \
		sudo systemctl status caddy.service --no-pager \
	'

# Build custom caddy image on the remote host, then deploy Quadlet units
caddy-build:
	scp ./caddy/Dockerfile ./caddy/entrypoint.sh william@192.168.0.129:/tmp/
	ssh -t william@192.168.0.129 '\
		rm -rf /tmp/caddy-build && \
		mkdir -p /tmp/caddy-build && \
		mv /tmp/Dockerfile /tmp/caddy-build/Dockerfile && \
		mv /tmp/entrypoint.sh /tmp/caddy-build/entrypoint.sh && \
		sudo podman build -t localhost/caddy-custom:latest /tmp/caddy-build \
	'
	@$(MAKE) caddy

caddy-env:
	@test -s ./caddy/.caddy.env || { echo "Missing or empty caddy/.caddy.env"; exit 1; }
	@chmod 600 ./caddy/.caddy.env
	@set -eu; \
	host=william@192.168.0.129; \
	stage=$$(ssh "$$host" 'mktemp -d "$$HOME/.caddy-env.XXXXXXXX"'); \
	trap 'ssh "$$host" "rm -rf \"$$stage\"" || true' EXIT; \
	scp ./caddy/.caddy.env "$$host:$$stage/.caddy.env"; \
	ssh -t "$$host" "sudo install -d -m 0755 /etc/caddy && \
		sudo install -o root -g root -m 0600 \
		'$$stage/.caddy.env' /etc/caddy/.caddy.env"
	@echo "Environment uploaded. Run make caddy to recreate the container with the new values."

crowdsec-env:
	@test -s ./caddy/.crowdsec.env || { echo "Missing or empty caddy/.crowdsec.env"; exit 1; }
	@chmod 600 ./caddy/.crowdsec.env
	@set -eu; \
	host=william@192.168.0.129; \
	stage=$$(ssh "$$host" 'mktemp -d "$$HOME/.crowdsec-env.XXXXXXXX"'); \
	trap 'ssh "$$host" "rm -rf \"$$stage\"" || true' EXIT; \
	scp ./caddy/.crowdsec.env "$$host:$$stage/.crowdsec.env"; \
	ssh -t "$$host" "sudo install -d -m 0755 /etc/crowdsec && \
		sudo install -o root -g root -m 0600 \
		'$$stage/.crowdsec.env' /etc/crowdsec/.crowdsec.env"
	@echo "Uploaded /etc/crowdsec/.crowdsec.env"
	@echo "Run 'make caddy' to recreate the container with the new values."

# Reload Caddy configuration using the container's existing environment
caddy-reload:
	scp ./caddy/conf/Caddyfile william@192.168.0.129:/tmp/Caddyfile
	ssh -t william@192.168.0.129 '\
		sudo install -Dm644 /tmp/Caddyfile /etc/caddy/Caddyfile && \
		sudo podman exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile \
	'# Identity provider / SSO

authentik:
	$(DOCKER) stack rm authentik || true
	$(DOCKER) stack deploy -c ./authentik/compose.yml authentik

# =============================================================================
# Services - Networking
# =============================================================================

# DNS server (used by WireGuard clients)
tech:
	$(DOCKER) stack rm technitium || true
	$(DOCKER) stack deploy -c ./technitium/compose.yml technitium

# =============================================================================
# Services - Applications
# =============================================================================

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
	sleep 5
	$(DOCKER) stack deploy -c ./redbot/compose.yml redbot

redbot-playlist-sync-install:

	

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
	ssh -t william@192.168.0.129 "sudo mkdir -p /opt/vaultwarden-backup /mnt/storage-box-1/backups/vaultwarden && \
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
	ssh william@192.168.0.129 "DOCKER_CONTEXT=local /opt/vaultwarden-backup/backup.sh /mnt/storage-box-1/backups/vaultwarden"

# List vaultwarden backups
vaultwarden-backup-list:
	ssh william@192.168.0.129 "ls -lht /mnt/storage-box-1/backups/vaultwarden/*.tar.gz 2>/dev/null | head -10 || echo 'No backups found'"

# Restore vaultwarden from backup (usage: make vaultwarden-restore BACKUP=filename.tar.gz)
vaultwarden-restore:
	@if [ -z "$(BACKUP)" ]; then echo "Usage: make vaultwarden-restore BACKUP=vaultwarden-backup-YYYYMMDD-HHMMSS.tar.gz"; exit 1; fi
	ssh william@192.168.0.129 "DOCKER_CONTEXT=local /opt/vaultwarden-backup/restore.sh /mnt/storage-box-1/backups/vaultwarden/$(BACKUP)"

homeassistant:
	scp ./homeassistant/homeassistant.container ./homeassistant/homeassistant-config.volume \
		william@192.168.0.129:/tmp/
	ssh -t william@192.168.0.129 '\
		sudo install -Dm644 /tmp/homeassistant.container /etc/containers/systemd/homeassistant.container && \
		sudo install -Dm644 /tmp/homeassistant-config.volume /etc/containers/systemd/homeassistant-config.volume && \
		sudo systemctl daemon-reload && \
		sudo systemctl restart homeassistant.service && \
		sudo systemctl status homeassistant.service --no-pager \
	'

coredns:
	scp ./coredns/podman-dns.network \
		./coredns/coredns.container \
		./coredns/Corefile \
		./coredns/zones/wolke-lab.duckdns.org.zone \
		william@192.168.0.129:/tmp/
	ssh -t william@192.168.0.129 '\
		sudo install -Dm644 /tmp/podman-dns.network /etc/containers/systemd/podman-dns.network && \
		sudo install -Dm644 /tmp/coredns.container /etc/containers/systemd/coredns.container && \
		sudo install -Dm644 /tmp/Corefile /etc/coredns/Corefile && \
		sudo install -Dm644 /tmp/wolke-lab.duckdns.org.zone /etc/coredns/zones/wolke-lab.duckdns.org.zone && \
		sudo systemctl daemon-reload && \
		sudo systemctl start podman-dns-network.service && \
		sudo systemctl restart coredns.service && \
		sudo podman network inspect podman-dns && \
		sudo systemctl status coredns.service --no-pager \
	'

# =============================================================================
# Immich (Podman Quadlet)
# =============================================================================

IMMICH_UNITS := immich.network immich-postgres.volume immich-model-cache.volume \
	immich-valkey.container immich-postgres.container \
	immich-machine-learning.container immich-server.container
IMMICH_SERVICES := immich-valkey.service immich-postgres.service \
	immich-machine-learning.service immich-server.service

immich:
	scp $(addprefix ./immich/,$(IMMICH_UNITS)) william@192.168.0.129:/tmp/
	ssh -t william@192.168.0.129 '\
		sudo test -s /etc/immich/.immich.env || { echo "Missing /etc/immich/.immich.env - run make immich-env first"; exit 1; } && \
		sudo mkdir -p /etc/containers/systemd /mnt/storage-box-1/immich && \
		for f in $(IMMICH_UNITS); do sudo install -Dm644 /tmp/$$f /etc/containers/systemd/$$f && rm -f /tmp/$$f; done && \
		sudo systemctl daemon-reload && \
		sudo systemctl restart immich-network.service && \
		sudo systemctl restart immich-valkey.service immich-postgres.service && \
		sudo systemctl restart immich-machine-learning.service immich-server.service && \
		sudo systemctl status $(IMMICH_SERVICES) --no-pager \
	'

immich-env:
	@test -s ./immich/.immich.env || { echo "Missing or empty immich/.immich.env (see .immich.env.example)"; exit 1; }
	@chmod 600 ./immich/.immich.env
	@. ./immich/.immich.env; \
		[ -n "$$DB_PASSWORD" ] && [ "$$DB_PASSWORD" = "$$POSTGRES_PASSWORD" ] || \
		{ echo "DB_PASSWORD and POSTGRES_PASSWORD must be set and identical"; exit 1; }
	@set -eu; \
	host=william@192.168.0.129; \
	stage=$$(ssh "$$host" 'mktemp -d "$$HOME/.immich-env.XXXXXXXX"'); \
	trap 'ssh "$$host" "rm -rf \"$$stage\"" || true' EXIT; \
	scp ./immich/.immich.env "$$host:$$stage/.immich.env"; \
	ssh -t "$$host" "sudo install -d -m 0755 /etc/immich && \
		sudo install -o root -g root -m 0600 \
		'$$stage/.immich.env' /etc/immich/.immich.env"
	@echo "Uploaded /etc/immich/.immich.env"
	@echo "Run 'make immich' to recreate the containers with the new values."

immich-pull:
	ssh -t william@192.168.0.129 '\
		for f in $(filter %.container,$(IMMICH_UNITS)); do \
			img=$$(grep -m1 "^Image=" /etc/containers/systemd/$$f | cut -d= -f2-); \
			echo "Pulling $$img"; sudo podman pull "$$img"; \
		done \
	'

immich-status:
	ssh -t william@192.168.0.129 'sudo systemctl status $(IMMICH_SERVICES) --no-pager; sudo podman ps --filter name=immich'

immich-gpu-info:
	ssh -t william@192.168.0.129 '\
		ls -l /dev/dri /dev/kfd; \
		echo "gfx_target_version (e.g. 110003 = gfx1103):"; \
		grep -h gfx_target_version /sys/class/kfd/kfd/topology/nodes/*/properties | grep -v " 0$$"; \
		sudo podman exec immich-server ls -l /dev/dri 2>/dev/null || true \
	'

podman-troubleshoot:
	ssh -t william@192.168.0.129 '\
	sudo /usr/lib/systemd/system-generators/podman-system-generator --dryrun 2>&1 \
	| grep -Ei -C 5 'wg-easy|unsupported|error|failed' \
	'

# Keep backups location updated with script
podman-volume-backup-install:
	@echo "Installing nightly Podman volume backup..."
	scp ./scripts/backup-podman-volumes.sh \
		./backups/podman-volume-backup.service \
		./backups/podman-volume-backup.timer \
		william@192.168.0.129:/tmp/
	ssh -t william@192.168.0.129 '\
		sudo install -Dm755 /tmp/backup-podman-volumes.sh /usr/local/sbin/backup-podman-volumes.sh && \
		sudo install -Dm644 /tmp/podman-volume-backup.service /etc/systemd/system/podman-volume-backup.service && \
		sudo install -Dm644 /tmp/podman-volume-backup.timer /etc/systemd/system/podman-volume-backup.timer && \
		sudo install -d -m700 /mnt/storage-box-1/backups/podman-volumes && \
		sudo podman info >/dev/null && \
		sudo systemctl daemon-reload && \
		sudo systemctl enable --now podman-volume-backup.timer && \
		sudo systemctl restart podman-volume-backup.timer && \
		sudo systemctl status podman-volume-backup.timer --no-pager \
	'
MEALIE_UNITS := mealie.container mealie-data.volume

mealie:
	scp $(addprefix ./mealie/,$(MEALIE_UNITS)) william@192.168.0.129:/tmp/
	ssh -t william@192.168.0.129 '\
		sudo test -s /etc/mealie/.mealie.env || { echo "Missing /etc/mealie/.mealie.env - run make mealie-env first"; exit 1; } && \
		sudo mkdir -p /etc/containers/systemd && \
		for f in $(MEALIE_UNITS); do sudo install -Dm644 /tmp/$$f /etc/containers/systemd/$$f && rm -f /tmp/$$f; done && \
		sudo systemctl daemon-reload && \
		sudo systemctl restart proxy-net-network.service || true && \
		sudo systemctl restart mealie.service && \
		sudo systemctl status mealie.service --no-pager \
	'

mealie-env:
	scp ./mealie/.mealie.env william@192.168.0.129:/tmp/.mealie.env 
	ssh -t william@192.168.0.129 '\
		sudo install -d -m 0755 /etc/mealie && \
		sudo install -Dm600 /tmp/.mealie.env /etc/mealie/.mealie.env \
	'

mealie-migrate:
	./mealie/scripts/migrate-volume.sh migrate

mealie-status:
	ssh -t william@192.168.0.129 '\
		systemctl status mealie.service --no-pager \
	'

wg-easy:
	scp ./wg-easy/wg-easy.container ./wg-easy/wg-easy-data.volume \
		./caddy/proxy-net.network william@192.168.0.129:/tmp/
	ssh -t william@192.168.0.129 '\
		sudo test -s /etc/wg-easy/.wg-easy.env || { echo "Missing /etc/wg-easy/.wg-easy.env - run make wg-easy-env first"; exit 1; } && \
		sudo mkdir -p /etc/containers/systemd /etc/wg-easy && \
		sudo install -Dm644 /tmp/proxy-net.network /etc/containers/systemd/proxy-net.network && \
		sudo install -Dm644 /tmp/wg-easy.container /etc/containers/systemd/wg-easy.container && \
		sudo install -Dm644 /tmp/wg-easy-data.volume /etc/containers/systemd/wg-easy-data.volume && \
		rm -f /tmp/wg-easy.container /tmp/wg-easy-data.volume /tmp/proxy-net.network && \
		sudo systemctl daemon-reload && \
		sudo systemctl restart wg-easy.service && \
		sudo systemctl status wg-easy.service --no-pager \
	'
wg-easy-env:
	@test -s ./wg-easy/.wg-easy.env || { echo "Missing or empty wg-easy/.wg-easy.env (see wg-easy/wg-easy.env.example)"; exit 1; }
	@chmod 600 ./wg-easy/.wg-easy.env
	@set -eu; \
	host=william@192.168.0.129; \
	stage=$$(ssh "$$host" 'mktemp -d "$$HOME/.wg-easy-env.XXXXXXXX"'); \
	trap 'ssh "$$host" "rm -rf \"$$stage\"" || true' EXIT; \
	scp ./wg-easy/.wg-easy.env "$$host:$$stage/.wg-easy.env"; \
	ssh -t "$$host" "sudo install -d -m 0755 /etc/wg-easy && \
		sudo install -o root -g root -m 0600 \
		'$$stage/.wg-easy.env' /etc/wg-easy/.wg-easy.env"
	@echo "Uploaded /etc/wg-easy/.wg-easy.env"
	@echo "Run 'make wg-easy' to recreate the container with the new values."

wg-easy-status:
	ssh -t william@192.168.0.129 '\
		sudo systemctl status wg-easy.service --no-pager && \
		sudo podman ps --filter name=wg-easy \
	'

# Dynamic DNS updater
# Dynamic DNS updater (Podman Quadlet)
duckdns:
	scp ./duckdns/duckdns.container william@192.168.0.129:/tmp/
	ssh -t william@192.168.0.129 '\
		sudo test -s /etc/duckdns/.duckdns.env || { echo "Missing /etc/duckdns/.duckdns.env - run make duckdns-env first"; exit 1; } && \
		sudo mkdir -p /etc/containers/systemd && \
		sudo install -Dm644 /tmp/duckdns.container /etc/containers/systemd/duckdns.container && \
		rm -f /tmp/duckdns.container && \
		sudo systemctl daemon-reload && \
		sudo systemctl restart duckdns.service && \
		sudo systemctl status duckdns.service --no-pager \
	'

duckdns-env:
	@test -s ./duckdns/.duckdns.env || { echo "Missing or empty duckdns/.duckdns.env (see duckdns/duckdns.env.example)"; exit 1; }
	@chmod 600 ./duckdns/.duckdns.env
	@set -eu; \
	host=william@192.168.0.129; \
	stage=$$(ssh "$$host" 'mktemp -d "$$HOME/.duckdns-env.XXXXXXXX"'); \
	trap 'ssh "$$host" "rm -rf \"$$stage\"" || true' EXIT; \
	scp ./duckdns/.duckdns.env "$$host:$$stage/.duckdns.env"; \
	ssh -t "$$host" "sudo install -d -m 0755 /etc/duckdns && \
		sudo install -o root -g root -m 0600 \
		'$$stage/.duckdns.env' /etc/duckdns/.duckdns.env"
	@echo "Uploaded /etc/duckdns/.duckdns.env"
	@echo "Run 'make duckdns' to recreate the container with the new values."

duckdns-status:
	ssh -t william@192.168.0.129 '\
		sudo systemctl status duckdns.service --no-pager && \
		sudo podman ps --filter name=duckdns \
	'
