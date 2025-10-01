mealie:
	docker compose -f ./mealie/compose.yml down
	docker compose -f ./mealie/compose.yml up -d

searxng:
	docker compose -f ./searxng/compose.yml down
	docker compose -f ./searxng/compose.yml up -d

caddy:
	caddy_container_id=$(docker ps | grep caddy | awk '{print $1;}')
	docker exec $caddy_container_id caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile

redbot:
	docker compose -f ./redbot/compose.yml down
	docker compose -f ./redbot/compose.yml up -d

vaultwarden:
	docker compose -f ./vaultwarden/compose.yml down
	docker compose -f ./vaultwarden/compose.yml up -d

wg-easy:
	docker compose -f ./wg-easy/compose.yml down
	docker compose -f ./wg-easy/compose.yml up -d

gluetun-qb:
	docker compose -f ./gluetun-qb/compose.yml down
	docker compose -f ./gluetun-qb/compose.yml up -d

duckdns:
	docker compose -f ./duckdns/compose.yml down
	docker compose -f ./duckdns/compose.yml up -d

copyparty:
	docker compose -f ./copyparty/compose.yml down
	docker compose -f ./copyparty/compose.yml up -d
