#!/bin/bash
# Docker Secrets & Configs Management Script
# Run this with docker context set to your remote server
#
# Usage:
#   ./manage-secrets.sh check     # Check which secrets/configs are missing
#   ./manage-secrets.sh create    # Create all secrets (interactive)
#   ./manage-secrets.sh configs   # Create configs from local files
#   ./manage-secrets.sh list      # List existing secrets

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTING_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER="docker --context envy"

# Define all secrets needed by services
SECRETS=(
    # Caddy
    "caddy_email"
    "caddy_domain"
    "caddy_ddns_token"
    "crowdsec_url"
    "crowdsec_api_key"
    "appsec_url"
    # CrowdSec
    "bouncer_key_caddy"
    # Vaultwarden
    "vaultwarden_domain"
    "vaultwarden_admin_token"
    # WireGuard Easy
    "wg_host"
    "wg_password_hash"
    # Gluetun
    "gluetun_wireguard_private_key"
    "gluetun_wireguard_addresses"
    # Discord/Redbot
    "discord_token"
    # Authentik
    "authentik_pg_pass"
    "authentik_secret_key"
    # SearXNG
    "searxng_secret_key"
    # Mealie
    "mealie_base_url"
    "mealie_oidc_config_url"
    "mealie_oidc_client_id"
    "mealie_oidc_client_secret"
    "mealie_oidc_user_group"
    "mealie_oidc_admin_group"
    # DuckDNS
    "duckdns_subdomains"
    "duckdns_token"
)

# Define configs and their local source files
# Format: "config_name:relative_path_from_hosting_dir"
CONFIGS=(
    "caddyfile:caddy/conf/Caddyfile"
    "crowdsec_acquis:caddy/crowdsec/acquis.yaml"
    "searxng_settings:searxng/config/settings.yml"
    "searxng_uwsgi:searxng/config/uwsgi.ini"
    "copyparty_conf:copyparty/copyparty.conf"
)

# Helper to update a config (remove old, create new)
update_config() {
    local config_name="$1"
    local config_path="$2"
    local full_path="$HOSTING_DIR/$config_path"

    if [ ! -f "$full_path" ]; then
        echo "File not found: $config_path"
        return 1
    fi

    if $DOCKER config inspect "$config_name" &>/dev/null; then
        echo "Removing old config: $config_name"
        $DOCKER config rm "$config_name"
    fi

    $DOCKER config create "$config_name" "$full_path"
    echo "Created config: $config_name"
}

check_secrets() {
    echo "=== SECRETS ==="
    existing=$($DOCKER secret ls --format '{{.Name}}' 2>/dev/null || true)

    missing=()
    found=()

    for secret in "${SECRETS[@]}"; do
        if echo "$existing" | grep -q "^${secret}$"; then
            found+=("$secret")
        else
            missing+=("$secret")
        fi
    done

    echo "Found (${#found[@]}/${#SECRETS[@]}):"
    for s in "${found[@]}"; do
        echo "  ✓ $s"
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo ""
        echo "Missing (${#missing[@]}/${#SECRETS[@]}):"
        for s in "${missing[@]}"; do
            echo "  ✗ $s"
        done
    fi

    echo ""
    echo "=== CONFIGS ==="
    existing_configs=$($DOCKER config ls --format '{{.Name}}' 2>/dev/null || true)

    missing_configs=()
    found_configs=()

    for entry in "${CONFIGS[@]}"; do
        config_name="${entry%%:*}"
        if echo "$existing_configs" | grep -q "^${config_name}$"; then
            found_configs+=("$config_name")
        else
            missing_configs+=("$config_name")
        fi
    done

    echo "Found (${#found_configs[@]}/${#CONFIGS[@]}):"
    for c in "${found_configs[@]}"; do
        echo "  ✓ $c"
    done

    if [ ${#missing_configs[@]} -gt 0 ]; then
        echo ""
        echo "Missing (${#missing_configs[@]}/${#CONFIGS[@]}):"
        for c in "${missing_configs[@]}"; do
            echo "  ✗ $c"
        done
    fi

    echo ""
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Run './manage-secrets.sh create' to create missing secrets"
    fi
    if [ ${#missing_configs[@]} -gt 0 ]; then
        echo "Run './manage-secrets.sh configs' to create missing configs"
    fi
}

create_secrets() {
    echo "Creating Docker secrets..."
    echo "You will be prompted to enter each secret value."
    echo "Leave empty to skip. Press Ctrl+C to cancel."
    echo ""

    for secret in "${SECRETS[@]}"; do
        if $DOCKER secret inspect "$secret" &>/dev/null; then
            echo "Secret '$secret' already exists, skipping..."
        else
            echo -n "Enter value for '$secret': "
            read -s value
            echo ""
            if [ -n "$value" ]; then
                echo "$value" | $DOCKER secret create "$secret" -
                echo "Created secret: $secret"
            else
                echo "Skipped: $secret"
            fi
        fi
    done
}

list_secrets() {
    echo "=== SECRETS ==="
    $DOCKER secret ls
    echo ""
    echo "=== CONFIGS ==="
    $DOCKER config ls
}

create_configs() {
    echo "Creating Docker configs from local files..."
    echo ""

    for entry in "${CONFIGS[@]}"; do
        config_name="${entry%%:*}"
        config_path="${entry#*:}"
        full_path="$HOSTING_DIR/$config_path"

        if $DOCKER config inspect "$config_name" &>/dev/null; then
            echo "Config '$config_name' already exists, skipping..."
            echo "  (To update, first run: $DOCKER config rm $config_name)"
        elif [ -f "$full_path" ]; then
            $DOCKER config create "$config_name" "$full_path"
            echo "Created config: $config_name (from $config_path)"
        else
            echo "Skipped: $config_name (file not found: $config_path)"
        fi
    done
}

update_configs() {
    echo "Updating Docker configs from local files..."
    echo "WARNING: This will remove and recreate configs. Services using them must be redeployed."
    echo ""

    for entry in "${CONFIGS[@]}"; do
        config_name="${entry%%:*}"
        config_path="${entry#*:}"
        update_config "$config_name" "$config_path"
    done
}

case "${1:-}" in
    check)
        check_secrets
        ;;
    create)
        create_secrets
        ;;
    configs)
        create_configs
        ;;
    update-configs)
        update_configs
        ;;
    list)
        list_secrets
        ;;
    *)
        echo "Usage: $0 {check|create|configs|update-configs|list}"
        echo ""
        echo "Commands:"
        echo "  check          - Check which secrets/configs exist vs. needed"
        echo "  create         - Create missing secrets interactively"
        echo "  configs        - Create configs from local files (skip existing)"
        echo "  update-configs - Update all configs (remove and recreate)"
        echo "  list           - List all existing secrets and configs"
        exit 1
        ;;
esac
