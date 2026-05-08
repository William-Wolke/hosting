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

# Helper: list services that mount a config matching <base_name> or <base_name>_<hex>.
# Output lines: "service|config_name|target_path"
_services_using_config() {
    local base_name="$1"
    local svc cfgs line cur tgt
    while read -r svc; do
        [ -z "$svc" ] && continue
        cfgs=$($DOCKER service inspect "$svc" --format \
            '{{range .Spec.TaskTemplate.ContainerSpec.Configs}}{{.ConfigName}}={{.File.Name}}{{"\n"}}{{end}}' 2>/dev/null) || continue
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            cur="${line%%=*}"
            tgt="${line#*=}"
            if [[ "$cur" == "$base_name" ]] || [[ "$cur" =~ ^${base_name}_[0-9a-f]+$ ]]; then
                printf '%s|%s|%s\n' "$svc" "$cur" "$tgt"
            fi
        done <<< "$cfgs"
    done < <($DOCKER service ls --format '{{.Name}}')
}

# Update a config without requiring `stack rm`. Creates a content-hashed versioned
# config (caddyfile_<sha>), rolls each dependent service onto it via
# `service update --config-rm/--config-add`, then refreshes the canonical alias so
# future `docker stack deploy` from compose still resolves the bare name. Old
# versioned configs are garbage-collected.
update_config() {
    local config_name="$1"
    local config_path="$2"
    local full_path="$HOSTING_DIR/$config_path"

    if [ ! -f "$full_path" ]; then
        echo "File not found: $config_path"
        return 1
    fi

    local sha versioned services_data svc cur tgt old any_swap=false
    sha=$(sha256sum "$full_path" | awk '{print substr($1,1,12)}')
    versioned="${config_name}_${sha}"
    services_data=$(_services_using_config "$config_name")

    # 1. Create the versioned config (idempotent — same file → same name)
    if ! $DOCKER config inspect "$versioned" &>/dev/null; then
        $DOCKER config create "$versioned" "$full_path" >/dev/null
        echo "$config_name: created versioned config $versioned"
    fi

    # 2. Swap every dependent service onto the versioned config
    if [ -n "$services_data" ]; then
        while IFS='|' read -r svc cur tgt; do
            [ -z "$svc" ] && continue
            if [ "$cur" = "$versioned" ]; then
                continue
            fi
            any_swap=true
            echo "$config_name: rotating $svc ($cur → $versioned, target=$tgt)"
            $DOCKER service update --quiet \
                --config-rm "$cur" \
                --config-add "source=$versioned,target=$tgt" \
                "$svc" >/dev/null
        done <<< "$services_data"
        if [ "$any_swap" = "false" ]; then
            echo "$config_name: services already on version ${sha:0:8}, no rotation needed"
        fi
    fi

    # 3. Refresh the canonical alias so `docker stack deploy` from compose still works.
    # After step 2, no service references the canonical name, so rm is safe.
    if $DOCKER config inspect "$config_name" &>/dev/null; then
        if $DOCKER config rm "$config_name" 2>/dev/null; then
            $DOCKER config create "$config_name" "$full_path" >/dev/null
            echo "$config_name: refreshed canonical alias"
        else
            echo "$config_name: WARNING canonical still in use, alias not refreshed"
        fi
    else
        $DOCKER config create "$config_name" "$full_path" >/dev/null
        echo "$config_name: created canonical alias"
    fi

    # 4. Garbage-collect old versioned configs
    while read -r old; do
        [ -z "$old" ] && continue
        [ "$old" = "$versioned" ] && continue
        if $DOCKER config rm "$old" 2>/dev/null; then
            echo "$config_name: removed orphaned $old"
        fi
    done < <($DOCKER config ls --format '{{.Name}}' | grep -E "^${config_name}_[0-9a-f]+$" || true)
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
                printf '%s' "$value" | $DOCKER secret create "$secret" -
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
    echo "Dependent services will be rolled onto the new config automatically."
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
