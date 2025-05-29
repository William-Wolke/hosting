FROM caddy:2.10.0-builder AS builder

	# --with github.com/mholt/caddy-l4 \
RUN xcaddy build \
	--with github.com/caddy-dns/duckdns \
	--with github.com/caddyserver/transform-encoder \
	--with github.com/hslatman/caddy-crowdsec-bouncer/crowdsec \
	--with github.com/hslatman/caddy-crowdsec-bouncer/http@main \
	--with github.com/hslatman/caddy-crowdsec-bouncer/layer4@main

FROM caddy:2.9.1

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
