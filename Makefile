DOCKER := docker --context envy

.PHONY: mealie searxng caddy caddy-build caddy-reload redbot vaultwarden wg-easy gluetun-qb duckdns copyparty technitium tasks crafty uptime-kuma check-secrets create-secrets create-configs update-configs authentik

# Secret and config management
check-secrets:
	./scripts/manage-secrets.sh check

create-secrets:
	./scripts/manage-secrets.sh create

create-configs:
	./scripts/manage-secrets.sh configs

update-configs:
	./scripts/manage-secrets.sh update-configs

# Services
mealie:
	$(DOCKER) stack rm mealie || true
	$(DOCKER) stack deploy -c ./mealie/compose.yml mealie

searxng:
	$(DOCKER) stack rm searxng || true
	$(DOCKER) stack deploy -c ./searxng/compose.yml searxng

caddy:
	$(DOCKER) stack rm caddy || true
	$(DOCKER) stack deploy -c ./caddy/compose.yml caddy

caddy-build:
	$(DOCKER) compose -f ./caddy/compose.yml build
	$(DOCKER) stack rm caddy || true
	$(DOCKER) stack deploy -c ./caddy/compose.yml caddy

caddy-reload:
	$(DOCKER) exec $$($(DOCKER) ps -q -f name=caddy_caddy) caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile

redbot:
	$(DOCKER) stack rm redbot || true
	$(DOCKER) stack deploy -c ./redbot/compose.yml redbot

vaultwarden:
	$(DOCKER) stack rm vaultwarden || true
	$(DOCKER) stack deploy -c ./vaultwarden/compose.yml vaultwarden

wg-easy:
	$(DOCKER) stack rm wg-easy || true
	$(DOCKER) stack deploy -c ./wg-easy/compose.yml wg-easy

gluetun-qb:
	$(DOCKER) stack rm gluetun-qb || true
	$(DOCKER) stack deploy -c ./gluetun-qb/compose.yml gluetun-qb

duckdns:
	$(DOCKER) stack rm duckdns || true
	$(DOCKER) stack deploy -c ./duckdns/compose.yml duckdns

copyparty:
	$(DOCKER) stack rm copyparty || true
	$(DOCKER) stack deploy -c ./copyparty/compose.yml copyparty

uptime:
	$(DOCKER) stack rm uptime-kuma || true
	$(DOCKER) stack deploy -c ./uptime-kuma/compose.yml uptime-kuma

tech:
	$(DOCKER) stack rm technitium || true
	$(DOCKER) stack deploy -c ./technitium/compose.yml technitium

tasks:
	$(DOCKER) stack rm tasks || true
	$(DOCKER) stack deploy -c ./tasks/compose.yml tasks

crafty:
	$(DOCKER) stack rm crafty || true
	$(DOCKER) stack deploy -c ./crafty/compose.yml crafty

uptime-kuma:
	$(DOCKER) stack rm uptime-kuma || true
	$(DOCKER) stack deploy -c ./uptime-kuma/compose.yml uptime-kuma

authentik:
	$(DOCKER) stack rm authentik || true
	$(DOCKER) stack deploy -c ./authentik/compose.yml authentik
