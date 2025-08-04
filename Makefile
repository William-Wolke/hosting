mealie:
	cd mealie
	docker compose down
	docker compose up -d

searxng:
	cd searxng
	docker compose down
	docker compose up -d

caddy:
	caddy_container_id=$(docker ps | grep caddy | awk '{print $1;}')
	docker exec $caddy_container_id caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile

redbot:
	cd redbot
	docker compose down
	docker compose up -d

vaultwarden:
	cd vaultwarden
	docker compose down
	docker compose up -d

wg-easy:
	cd wg-easy
	docker compose down
	docker compose up -d

gluetun-qb:
	cd gluetun-qb
	docker compose down
	docker compose up -d

duckdns:
	cd duckdns
	docker compose down
	docker compose up -d

