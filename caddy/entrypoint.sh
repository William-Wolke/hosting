#!/bin/sh
# Read Docker secrets into environment variables for Caddy

# Function to read secret file if it exists
read_secret() {
    local var_name="$1"
    local file_path="$2"
    if [ -f "$file_path" ]; then
        export "$var_name"="$(cat "$file_path" | tr -d '\n')"
    fi
}

# Load secrets
read_secret "CADDY_DOMAIN" "/run/secrets/caddy_domain"
read_secret "CADDY_EMAIL" "/run/secrets/caddy_email"
read_secret "CADDY_DDNS_TOKEN" "/run/secrets/caddy_ddns_token"
read_secret "CROWDSEC_API_KEY" "/run/secrets/crowdsec_api_key"

# Execute the main command
exec "$@"