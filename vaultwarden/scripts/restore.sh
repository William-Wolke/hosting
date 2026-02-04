#!/bin/bash
# Vaultwarden Restore Script
# Restores a backup created by backup.sh
#
# Usage: ./restore.sh <backup_archive.tar.gz>

set -euo pipefail

# Configuration
DOCKER_CONTEXT="${DOCKER_CONTEXT:-local}"
SERVICE_NAME="vaultwarden_vaultwarden"
DOCKER_CMD="docker"
if [ "${DOCKER_CONTEXT}" != "local" ]; then
    DOCKER_CMD="docker --context ${DOCKER_CONTEXT}"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"; }
error() { echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2; }

if [ $# -lt 1 ]; then
    error "Usage: $0 <backup_archive.tar.gz>"
    echo ""
    echo "Available backups:"
    ls -lht /var/backups/vaultwarden/vaultwarden-backup-*.tar.gz 2>/dev/null | head -10 || echo "No backups found in /var/backups/vaultwarden/"
    exit 1
fi

BACKUP_ARCHIVE="$1"

if [ ! -f "${BACKUP_ARCHIVE}" ]; then
    error "Backup archive not found: ${BACKUP_ARCHIVE}"
    exit 1
fi

# Verify checksum if available
CHECKSUM_FILE="${BACKUP_ARCHIVE}.sha256"
if [ -f "${CHECKSUM_FILE}" ]; then
    log "Verifying backup checksum..."
    if sha256sum -c "${CHECKSUM_FILE}" --quiet; then
        log "Checksum verified successfully"
    else
        error "Checksum verification failed! Backup may be corrupted."
        exit 1
    fi
else
    warn "No checksum file found, skipping verification"
fi

# Extract backup to temp directory
TEMP_DIR=$(mktemp -d)
log "Extracting backup to ${TEMP_DIR}..."
tar -xzf "${BACKUP_ARCHIVE}" -C "${TEMP_DIR}"

# Find the backup subdirectory
BACKUP_SUBDIR=$(find "${TEMP_DIR}" -maxdepth 1 -type d -name "20*" | head -1)
if [ -z "${BACKUP_SUBDIR}" ]; then
    error "Could not find backup data in archive"
    rm -rf "${TEMP_DIR}"
    exit 1
fi

# Verify essential files exist
if [ ! -f "${BACKUP_SUBDIR}/db.sqlite3" ]; then
    error "Database file not found in backup"
    rm -rf "${TEMP_DIR}"
    exit 1
fi

log "Found backup from: $(basename "${BACKUP_SUBDIR}")"

# Confirm with user
echo ""
warn "This will REPLACE all current Vaultwarden data!"
read -p "Are you sure you want to continue? (yes/no): " CONFIRM
if [ "${CONFIRM}" != "yes" ]; then
    log "Restore cancelled"
    rm -rf "${TEMP_DIR}"
    exit 0
fi

# Stop vaultwarden service
log "Scaling down Vaultwarden service..."
${DOCKER_CMD} service scale "${SERVICE_NAME}=0" --detach

# Wait for container to stop
sleep 5

# Clear existing data and restore
log "Restoring database..."
${DOCKER_CMD} run --rm \
    -v vaultwarden_data:/data \
    -v "${BACKUP_SUBDIR}":/backup:ro \
    alpine sh -c '
        rm -f /data/db.sqlite3 /data/db.sqlite3-wal /data/db.sqlite3-shm
        cp /backup/db.sqlite3 /data/
        if [ -f /backup/rsa_key.pem ]; then cp /backup/rsa_key.pem /data/; fi
        if [ -d /backup/attachments ]; then rm -rf /data/attachments; cp -r /backup/attachments /data/; fi
        if [ -d /backup/sends ]; then rm -rf /data/sends; cp -r /backup/sends /data/; fi
        if [ -f /backup/config.json ]; then cp /backup/config.json /data/; fi
        chown -R root:root /data/
        ls -la /data/
    '

# Start vaultwarden service
log "Starting Vaultwarden service..."
${DOCKER_CMD} service scale "${SERVICE_NAME}=1"

# Cleanup
rm -rf "${TEMP_DIR}"

log "Restore completed successfully!"
log "Please verify by logging into Vaultwarden"