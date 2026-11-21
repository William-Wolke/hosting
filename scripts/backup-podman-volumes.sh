#!/bin/bash
set -Eeuo pipefail
umask 077

BACKUP_ROOT="/mnt/storage-box-1/backups/podman-volumes"
ACTIVE_SERVICES=()
PARTIAL_FILE=""
BACKUP_DIR=""
LOG_FILE=""

if (( EUID != 0 )); then
    echo "Run this script as root for rootful Podman and systemd." >&2
    exit 1
fi

exec 9>/run/lock/podman-volume-backup.lock
if ! flock -n 9; then
    echo "Another volume backup is already running." >&2
    exit 1
fi

mkdir -p "$BACKUP_ROOT"
BACKUP_DIR=$(mktemp -d "$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)-XXXXXX")
LOG_FILE="$BACKUP_DIR/backup.log"
touch "$LOG_FILE"

log() {
    printf '%s %s\n' "$(date --iso-8601=seconds)" "$*" |
        tee -a "$LOG_FILE"
}

die() {
    log "ERROR: $*"
    exit 1
}

cleanup() {
    local status=$?
    local unit state

    trap - EXIT
    trap '' INT TERM
    set +e

    if [[ -n "$PARTIAL_FILE" ]]; then
        rm -f -- "$PARTIAL_FILE"
    fi

    if (( ${#ACTIVE_SERVICES[@]} > 0 )); then
        log "Restoring services: ${ACTIVE_SERVICES[*]}"

        if ! systemctl start "${ACTIVE_SERVICES[@]}" >>"$LOG_FILE" 2>&1; then
            log "ERROR: one or more services failed to start."
            status=1
        fi

        for unit in "${ACTIVE_SERVICES[@]}"; do
            state=$(systemctl show "$unit" --property=ActiveState --value)
            if [[ "$state" != active ]]; then
                log "ERROR: $unit is $state; manual recovery required."
                status=1
            fi
        done
    fi

    if (( status == 0 )); then
        log "Backup and service restoration completed."
    else
        log "Backup or service restoration FAILED. Check $LOG_FILE"
    fi

    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

array_add_unique() {
    local needle=$1
    shift
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    printf '%s\n' "$needle"
}

log "Starting backup."

# Only volumes explicitly labeled backup=true are included.
if ! volume_list=$(podman volume ls \
    --filter "label=backup=true" \
    --format '{{.Name}}' 2>>"$LOG_FILE"); then
    die "Cannot list labeled Podman volumes."
fi

VOLUMES=()
while IFS= read -r volume; do
    [[ -n "$volume" ]] || continue
    VOLUMES+=("$volume")
done <<<"$volume_list"

if (( ${#VOLUMES[@]} == 0 )); then
    log "No volumes found with backup=true label."
    exit 0
fi

log "Volumes selected for backup: ${VOLUMES[*]}"

# Map running containers to systemd units and collect services required
# for selected volumes. Podman containers managed by Quadlet commonly
# have a service name recorded in their systemd unit metadata.
CONTAINERS=()
DISCOVERED_SERVICES=()

for volume in "${VOLUMES[@]}"; do
    if ! containers=$(podman ps -q --filter "volume=$volume" 2>>"$LOG_FILE"); then
        die "Cannot find containers using $volume."
    fi

    while IFS= read -r container; do
        [[ -n "$container" ]] || continue
        CONTAINERS+=("$container")

        name=$(podman inspect --format '{{.Name}}' "$container" 2>>"$LOG_FILE") ||
            die "Cannot inspect container $container."

        unit=""

        # Preferred: a container name that corresponds directly to a Quadlet unit.
        candidate="${name#.}"
        if systemctl show "$candidate.service" --property=LoadState --value |
                grep -qx loaded; then
            unit="$candidate.service"
        else
            # Podman/Quadlet commonly expose the unit through container labels.
            unit=$(podman inspect --format \
                '{{ index .Config.Labels "PODMAN_SYSTEMD_UNIT" }}' \
                "$container" 2>>"$LOG_FILE") || unit=""
        fi

        if [[ -n "$unit" && "$unit" != "<no value>" ]]; then
            DISCOVERED_SERVICES+=("$unit")
            log "Volume $volume is used by $name; managing unit: $unit"
        elif [[ -n "$name" ]]; then
            DISCOVERED_SERVICES+=("podman-managed:${name}")
            log "Volume $volume is used by $name; no systemd unit discovered"
        fi
    done <<<"$containers"
done

# Resolve and deduplicate systemd services before stopping anything.
UNIQUE_SERVICES=()
for unit in "${DISCOVERED_SERVICES[@]}"; do
    [[ "$unit" != podman-managed:* ]] || continue
    UNIQUE_SERVICES+=("$unit")
done

# Deduplicate through associative array to preserve predictable behavior.
declare -A seen_services=()
SERVICES=()
for unit in "${UNIQUE_SERVICES[@]}"; do
    [[ -z "${seen_services[$unit]+x}" ]] || continue
    seen_services["$unit"]=1
    SERVICES+=("$unit")
done

# Containers not backed by a discovered systemd unit need explicit handling.
for unit in "${DISCOVERED_SERVICES[@]}"; do
    [[ "$unit" == podman-managed:* ]] || continue
    name=${unit#podman-managed:}
    die "Running container '$name' uses a selected volume but no systemd unit was discovered."
done

# Validate every service before stopping anything.
for unit in "${SERVICES[@]}"; do
    load_state=$(systemctl show "$unit" --property=LoadState --value)
    [[ "$load_state" == loaded ]] ||
        die "$unit is not loaded."

    state=$(systemctl show "$unit" --property=ActiveState --value)
    case "$state" in
        active)
            ACTIVE_SERVICES+=("$unit")
            ;;
        inactive|failed)
            # Leave services that were already stopped alone.
            ;;
        *)
            die "$unit is $state; retry when service operations have finished."
            ;;
    esac
done

# Deduplicate active services.
declare -A seen_active=()
UNIQUE_ACTIVE_SERVICES=()
for unit in "${ACTIVE_SERVICES[@]}"; do
    [[ -z "${seen_active[$unit]+x}" ]] || continue
    seen_active["$unit"]=1
    UNIQUE_ACTIVE_SERVICES+=("$unit")
done
ACTIVE_SERVICES=("${UNIQUE_ACTIVE_SERVICES[@]}")

printf '%s\n' "${ACTIVE_SERVICES[@]}" >"$BACKUP_DIR/services-to-restore.txt"

if (( ${#ACTIVE_SERVICES[@]} > 0 )); then
    log "Stopping services: ${ACTIVE_SERVICES[*]}"
    if ! systemctl stop "${ACTIVE_SERVICES[@]}" >>"$LOG_FILE" 2>&1; then
        die "Service shutdown failed; refusing to back up."
    fi
fi

# Verify that systemctl actually stopped the required units.
for unit in "${ACTIVE_SERVICES[@]}"; do
    state=$(systemctl show "$unit" --property=ActiveState --value)
    result=$(systemctl show "$unit" --property=Result --value)

    [[ "$state" == inactive && "$result" == success ]] ||
        die "$unit did not stop cleanly: state=$state result=$result."
done

check_no_writers() {
    local volume=$1
    local writers

    if ! writers=$(podman ps -q --filter "volume=$volume" 2>>"$LOG_FILE"); then
        die "Cannot check containers using $volume."
    fi

    if [[ -n "$writers" ]]; then
        names=$(podman ps --format '{{.Names}}' --filter "volume=$volume" \
            2>>"$LOG_FILE" | paste -sd, -)
        die "Volume $volume still has running containers: $names"
    fi
}

# Validate every selected volume before creating archives.
for volume in "${VOLUMES[@]}"; do
    check_no_writers "$volume"
done

for volume in "${VOLUMES[@]}"; do
    log "Backing up volume: $volume"
    check_no_writers "$volume"

    archive="$BACKUP_DIR/${volume}.tar.gz"
    PARTIAL_FILE="${archive}.partial"

    if ! podman volume export "$volume" 2>>"$LOG_FILE" |
        gzip >"$PARTIAL_FILE" 2>>"$LOG_FILE"; then
        die "Export failed for $volume."
    fi

    # Catch containers restarted while this export was in progress.
    check_no_writers "$volume"

    if ! gzip -t "$PARTIAL_FILE" 2>>"$LOG_FILE"; then
        die "Archive verification failed for $volume."
    fi

    mv -- "$PARTIAL_FILE" "$archive"
    PARTIAL_FILE=""
    log "Saved: $archive"
done

log "All archives written to $BACKUP_DIR"
# The EXIT trap restores the originally active services.
