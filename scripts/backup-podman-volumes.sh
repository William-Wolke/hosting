#!/bin/bash
set -Eeuo pipefail
umask 077

# Rootful Quadlet services. Include related application/database services.
SERVICES=(
    caddy.service
    crowdsec.service
    homeassistant.service
    coredns.service
    immich-server.service
    immich-machine-learning.service
    immich-postgres.service
    immich-valkey.service
)
# Keep location updated with makefile
BACKUP_ROOT="/mnt/storage-box-1/backups/podman-volumes"
ACTIVE_SERVICES=()
PARTIAL_FILE=""

if (( EUID != 0 )); then
    echo "Run this script as root for system-level Quadlet services." >&2
    exit 1
fi

# Prevent concurrent runs, including manual invocations.
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

    # Avoid recursive cleanup or interruption during recovery.
    trap - EXIT
    trap '' INT TERM
    set +e

    if [[ -n "$PARTIAL_FILE" ]]; then
        rm -f -- "$PARTIAL_FILE"
    fi

    if (( ${#ACTIVE_SERVICES[@]} > 0 )); then
        log "Restoring services: ${ACTIVE_SERVICES[*]}"

        # Submit together so systemd can apply dependency ordering.
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

# Reject any volume still mounted by a running container.
check_no_writers() {
    local volume=$1
    local writers

    if ! writers=$(podman ps -q --filter "volume=$volume" 2>>"$LOG_FILE"); then
        die "Cannot check containers using $volume."
    fi

    if [[ -n "$writers" ]]; then
        die "Volume $volume has running containers: $writers. Add their managing services to SERVICES."
    fi
}

log "Starting backup."

# Capture command failures instead of hiding them in process substitution.
if ! volume_list=$(podman volume ls -q 2>>"$LOG_FILE"); then
    die "Cannot list Podman volumes."
fi

if [[ -z "$volume_list" ]]; then
    log "No volumes found."
    exit 0
fi

# Filter out certain volumes
VOLUMES=()
while IFS= read -r volume; do
    case "$volume" in
        immich-model-cache)
            log "Skipping excluded volume: $volume"
            continue
            ;;
    esac
    VOLUMES+=("$volume")
done <<<"$volume_list"

if (( ${#VOLUMES[@]} == 0 )); then
    log "No volumes remain after exclusions."
    exit 0
fi
# Validate all units before stopping anything.
for unit in "${SERVICES[@]}"; do
    load_state=$(systemctl show "$unit" --property=LoadState --value)
    [[ "$load_state" == loaded ]] || die "$unit is not loaded."

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

# Recovery reference if the process is killed before its EXIT trap can run.
printf '%s\n' "${ACTIVE_SERVICES[@]}" >"$BACKUP_DIR/services-to-restore.txt"

if (( ${#ACTIVE_SERVICES[@]} > 0 )); then
    log "Stopping services: ${ACTIVE_SERVICES[*]}"
    if ! systemctl stop "${ACTIVE_SERVICES[@]}" >>"$LOG_FILE" 2>&1; then
        die "Service shutdown failed; refusing to back up."
    fi

    for unit in "${ACTIVE_SERVICES[@]}"; do
        state=$(systemctl show "$unit" --property=ActiveState --value)
        result=$(systemctl show "$unit" --property=Result --value)
        [[ "$state" == inactive && "$result" == success ]] ||
            die "$unit did not stop cleanly: state=$state result=$result."
    done
fi

# Validate every volume before creating any archives.
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

    # Catch containers restarted during this export.
    check_no_writers "$volume"
    gzip -t "$PARTIAL_FILE" 2>>"$LOG_FILE" ||
        die "Archive verification failed for $volume."

    mv -- "$PARTIAL_FILE" "$archive"
    PARTIAL_FILE=""
    log "Saved: $archive"
done

log "All archives written to $BACKUP_DIR"
# EXIT trap restores the originally active services.
