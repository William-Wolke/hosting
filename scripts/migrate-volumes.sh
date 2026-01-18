#!/bin/bash
# Volume Migration Script for Docker Compose to Swarm
# ====================================================
# When migrating from docker-compose to swarm, volume names change.
# Docker-compose creates volumes as: <project>_<volume>
# Swarm with explicit names uses: <volume> (as specified in compose.yml)
#
# This script helps identify and migrate volumes to the new naming scheme.
#
# Usage:
#   ./migrate-volumes.sh check    # Show volume name mappings and status
#   ./migrate-volumes.sh migrate  # Interactively migrate volumes
#   ./migrate-volumes.sh list     # List all current volumes

set -e

DOCKER="docker --context envy"

# Define volume mappings: "new_name:old_name"
# Only services using Docker volumes (not bind mounts) are listed here
#
# Services using BIND MOUNTS (no migration needed):
#   - vaultwarden, uptime-kuma, crafty, tasks, redbot, gluetun-qb
#   - authentik media/certs/templates
#
VOLUME_MAPPINGS=(
    # Mealie
    "mealie-data:mealie_mealie-data"
    # SearXNG/Valkey
    "valkey-data:searxng_valkey-data2"
    # Caddy
    "caddy_data:caddy_caddy_data"
    "caddy_config:caddy_caddy_config"
    "caddy_logs:caddy_caddy_logs"
    "crowdsec-db:caddy_crowdsec-db"
    # WireGuard
    "etc_wireguard:wg-easy_etc_wireguard"
    # Technitium
    "technitium-config:technitium_config"
    # Authentik (only database and redis use volumes)
    "authentik-database:authentik_database"
    "authentik-redis:authentik_redis"
)

# Get list of existing volumes
get_existing_volumes() {
    $DOCKER volume ls --format '{{.Name}}' 2>/dev/null || true
}

check_volumes() {
    echo "Volume Migration Status"
    echo "======================="
    echo ""

    existing=$(get_existing_volumes)

    needs_migration=()
    already_correct=()
    missing=()

    for mapping in "${VOLUME_MAPPINGS[@]}"; do
        new_name="${mapping%%:*}"
        old_name="${mapping#*:}"

        has_new=$(echo "$existing" | grep -q "^${new_name}$" && echo "yes" || echo "no")
        has_old=$(echo "$existing" | grep -q "^${old_name}$" && echo "yes" || echo "no")

        if [ "$has_new" = "yes" ]; then
            already_correct+=("$new_name")
        elif [ "$has_old" = "yes" ]; then
            needs_migration+=("$old_name -> $new_name")
        else
            missing+=("$new_name (expected old: $old_name)")
        fi
    done

    if [ ${#already_correct[@]} -gt 0 ]; then
        echo "Already using correct names (${#already_correct[@]}):"
        for v in "${already_correct[@]}"; do
            echo "  ✓ $v"
        done
        echo ""
    fi

    if [ ${#needs_migration[@]} -gt 0 ]; then
        echo "Need migration (${#needs_migration[@]}):"
        for v in "${needs_migration[@]}"; do
            echo "  → $v"
        done
        echo ""
        echo "Run './scripts/migrate-volumes.sh migrate' to rename these volumes."
        echo ""
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        echo "Not found - will be created on first deploy (${#missing[@]}):"
        for v in "${missing[@]}"; do
            echo "  ? $v"
        done
        echo ""
    fi

    # Show any untracked volumes
    echo "---"
    echo "Other volumes on server:"
    for vol in $existing; do
        is_tracked="no"
        for mapping in "${VOLUME_MAPPINGS[@]}"; do
            new_name="${mapping%%:*}"
            old_name="${mapping#*:}"
            if [ "$vol" = "$new_name" ] || [ "$vol" = "$old_name" ]; then
                is_tracked="yes"
                break
            fi
        done
        if [ "$is_tracked" = "no" ]; then
            echo "  - $vol"
        fi
    done
}

migrate_volume() {
    local old_name="$1"
    local new_name="$2"

    echo "Migrating: $old_name -> $new_name"

    # Check if old volume exists
    if ! $DOCKER volume inspect "$old_name" &>/dev/null; then
        echo "  Error: Source volume '$old_name' does not exist"
        return 1
    fi

    # Check if new volume already exists
    if $DOCKER volume inspect "$new_name" &>/dev/null; then
        echo "  Error: Target volume '$new_name' already exists"
        return 1
    fi

    # Create new volume
    echo "  Creating new volume..."
    $DOCKER volume create "$new_name"

    # Copy data using a temporary container
    echo "  Copying data..."
    $DOCKER run --rm \
        -v "${old_name}:/source:ro" \
        -v "${new_name}:/dest" \
        alpine sh -c "cp -av /source/. /dest/"

    echo "  Done! Old volume '$old_name' preserved (remove manually after verification)"
    echo ""
}

migrate_volumes() {
    echo "Volume Migration"
    echo "================"
    echo ""
    echo "WARNING: This will copy data from old volumes to new volumes."
    echo "Old volumes will NOT be deleted automatically - verify and remove manually."
    echo ""

    existing=$(get_existing_volumes)

    to_migrate=()
    for mapping in "${VOLUME_MAPPINGS[@]}"; do
        new_name="${mapping%%:*}"
        old_name="${mapping#*:}"

        has_new=$(echo "$existing" | grep -q "^${new_name}$" && echo "yes" || echo "no")
        has_old=$(echo "$existing" | grep -q "^${old_name}$" && echo "yes" || echo "no")

        if [ "$has_new" = "no" ] && [ "$has_old" = "yes" ]; then
            to_migrate+=("$mapping")
        fi
    done

    if [ ${#to_migrate[@]} -eq 0 ]; then
        echo "No volumes need migration."
        exit 0
    fi

    echo "Volumes to migrate:"
    for mapping in "${to_migrate[@]}"; do
        new_name="${mapping%%:*}"
        old_name="${mapping#*:}"
        echo "  $old_name -> $new_name"
    done
    echo ""

    read -p "Proceed with migration? [y/N] " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "Aborted."
        exit 1
    fi

    echo ""
    for mapping in "${to_migrate[@]}"; do
        new_name="${mapping%%:*}"
        old_name="${mapping#*:}"
        migrate_volume "$old_name" "$new_name"
    done

    echo ""
    echo "Migration complete!"
    echo ""
    echo "Old volumes have been preserved. After verifying services work correctly,"
    echo "you can remove them with:"
    echo ""
    for mapping in "${to_migrate[@]}"; do
        old_name="${mapping#*:}"
        echo "  $DOCKER volume rm $old_name"
    done
}

list_volumes() {
    echo "Current volumes on server:"
    echo ""
    $DOCKER volume ls
}

backup_volume() {
    local vol_name="$1"
    local backup_dir="$2"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${backup_dir}/${vol_name}_${timestamp}.tar.gz"

    echo "Backing up: $vol_name -> $backup_file"

    $DOCKER run --rm \
        -v "${vol_name}:/source:ro" \
        -v "${backup_dir}:/backup" \
        alpine tar czf "/backup/${vol_name}_${timestamp}.tar.gz" -C /source .

    echo "  Done: $backup_file"
}

backup_volumes() {
    local backup_dir="${1:-/tmp/volume-backups}"

    echo "Volume Backup"
    echo "============="
    echo ""
    echo "Backup directory: $backup_dir"
    echo ""

    # Create backup dir on remote
    $DOCKER run --rm -v "${backup_dir}:/backup" alpine mkdir -p /backup 2>/dev/null || true

    existing=$(get_existing_volumes)

    # Get volumes that need migration (have old name, no new name)
    to_backup=()
    for mapping in "${VOLUME_MAPPINGS[@]}"; do
        new_name="${mapping%%:*}"
        old_name="${mapping#*:}"

        has_old=$(echo "$existing" | grep -q "^${old_name}$" && echo "yes" || echo "no")

        if [ "$has_old" = "yes" ]; then
            to_backup+=("$old_name")
        fi
    done

    if [ ${#to_backup[@]} -eq 0 ]; then
        echo "No volumes to backup."
        exit 0
    fi

    echo "Volumes to backup (${#to_backup[@]}):"
    for v in "${to_backup[@]}"; do
        echo "  - $v"
    done
    echo ""

    read -p "Proceed with backup? [y/N] " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "Aborted."
        exit 1
    fi

    echo ""
    for vol in "${to_backup[@]}"; do
        backup_volume "$vol" "$backup_dir"
    done

    echo ""
    echo "Backup complete! Files saved to: $backup_dir"
    echo ""
    echo "To list backups: ls -la $backup_dir"
}

inspect_volumes() {
    echo "Volume Details"
    echo "=============="
    echo ""
    echo "Showing mount points and sizes for all volumes..."
    echo ""

    $DOCKER system df -v 2>/dev/null | grep -A 1000 "VOLUME NAME" || \
        $DOCKER volume ls -q | while read vol; do
            size=$($DOCKER run --rm -v "${vol}:/vol" alpine du -sh /vol 2>/dev/null | cut -f1)
            echo "$vol: $size"
        done
}

case "${1:-}" in
    check)
        check_volumes
        ;;
    migrate)
        migrate_volumes
        ;;
    backup)
        backup_volumes "${2:-/tmp/volume-backups}"
        ;;
    inspect)
        inspect_volumes
        ;;
    list)
        list_volumes
        ;;
    *)
        echo "Usage: $0 {check|migrate|backup|inspect|list}"
        echo ""
        echo "Commands:"
        echo "  check       - Show volume name mappings and migration status"
        echo "  backup      - Backup volumes before migration (recommended!)"
        echo "  migrate     - Interactively migrate volumes to new names"
        echo "  inspect     - Show volume sizes to help identify anonymous volumes"
        echo "  list        - List all volumes on the server"
        echo ""
        echo "Recommended workflow:"
        echo "  1. $0 check              # See what needs migration"
        echo "  2. $0 inspect            # Identify anonymous volumes"
        echo "  3. $0 backup /path       # Backup before changes"
        echo "  4. $0 migrate            # Rename volumes"
        exit 1
        ;;
esac