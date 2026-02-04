#!/bin/bash
# Vaultwarden Backup Script
# Backs up the database using SQLite backup API and copies essential files
#
# Usage: ./backup.sh [backup_dir]
# Default backup directory: /var/backups/vaultwarden

set -euo pipefail

# Configuration
BACKUP_DIR="${1:-/var/backups/vaultwarden}"
DOCKER_CONTEXT="${DOCKER_CONTEXT:-local}"
CONTAINER_NAME="vaultwarden_vaultwarden"
DOCKER_CMD="docker"
if [ "${DOCKER_CONTEXT}" != "local" ]; then
    DOCKER_CMD="docker --context ${DOCKER_CONTEXT}"
fi
RETENTION_DAYS=30
DATE=$(date '+%Y%m%d-%H%M%S')
BACKUP_SUBDIR="${BACKUP_DIR}/${DATE}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"; }
error() { echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2; }

# Create backup directory
log "Creating backup directory: ${BACKUP_SUBDIR}"
mkdir -p "${BACKUP_SUBDIR}"

# Get container ID (Swarm containers have suffix like .1.xxxxx)
CONTAINER_ID=$(${DOCKER_CMD} ps -q -f "name=${CONTAINER_NAME}" 2>/dev/null | head -1)
if [ -z "${CONTAINER_ID}" ]; then
    # Try with wildcard pattern for Swarm naming
    CONTAINER_ID=$(${DOCKER_CMD} ps --format '{{.ID}}' --filter "name=${CONTAINER_NAME}." 2>/dev/null | head -1)
fi

if [ -z "${CONTAINER_ID}" ]; then
    error "Vaultwarden container not found. Is it running?"
    exit 1
fi

log "Found container: ${CONTAINER_ID}"

# Method 1: Use vaultwarden's built-in backup command (v1.32.1+)
log "Running SQLite backup via vaultwarden backup command..."
if BACKUP_OUTPUT=$(${DOCKER_CMD} exec "${CONTAINER_ID}" /vaultwarden backup 2>&1); then
    # Extract the backup filename from output (format: "Backup to 'data/db_YYYYMMDD_HHMMSS.sqlite3' was successful")
    BACKUP_FILE=$(echo "${BACKUP_OUTPUT}" | grep -oP "Backup to '\K[^']+" || true)
    if [ -n "${BACKUP_FILE}" ]; then
        # Copy the backup out of the container
        ${DOCKER_CMD} cp "${CONTAINER_ID}:/${BACKUP_FILE}" "${BACKUP_SUBDIR}/db.sqlite3"
        ${DOCKER_CMD} exec "${CONTAINER_ID}" rm -f "/${BACKUP_FILE}"
        log "Database backup completed using vaultwarden backup command"
    else
        error "Could not determine backup filename from output: ${BACKUP_OUTPUT}"
        exit 1
    fi
else
    # Fallback: Use sqlite3 directly via a temporary container
    warn "vaultwarden backup command not available, using sqlite3 fallback..."
    ${DOCKER_CMD} run --rm \
        -v vaultwarden_data:/data:ro \
        -v "${BACKUP_SUBDIR}":/backup \
        alpine sh -c 'apk add --no-cache sqlite >/dev/null 2>&1 && sqlite3 /data/db.sqlite3 ".backup /backup/db.sqlite3"'
    log "Database backup completed using sqlite3"
fi

# Backup RSA keys
log "Backing up RSA keys..."
${DOCKER_CMD} cp "${CONTAINER_ID}:/data/rsa_key.pem" "${BACKUP_SUBDIR}/" 2>/dev/null || warn "rsa_key.pem not found"
${DOCKER_CMD} cp "${CONTAINER_ID}:/data/rsa_key.pub.der" "${BACKUP_SUBDIR}/" 2>/dev/null || true

# Backup attachments
log "Backing up attachments..."
${DOCKER_CMD} run --rm \
    -v vaultwarden_data:/data:ro \
    -v "${BACKUP_SUBDIR}":/backup \
    alpine sh -c 'if [ -d /data/attachments ] && [ "$(ls -A /data/attachments 2>/dev/null)" ]; then cp -r /data/attachments /backup/; else echo "No attachments to backup"; fi'

# Backup sends (optional but recommended)
log "Backing up sends..."
${DOCKER_CMD} run --rm \
    -v vaultwarden_data:/data:ro \
    -v "${BACKUP_SUBDIR}":/backup \
    alpine sh -c 'if [ -d /data/sends ] && [ "$(ls -A /data/sends 2>/dev/null)" ]; then cp -r /data/sends /backup/; else echo "No sends to backup"; fi'

# Backup config.json if it exists
log "Backing up config..."
${DOCKER_CMD} cp "${CONTAINER_ID}:/data/config.json" "${BACKUP_SUBDIR}/" 2>/dev/null || true

# Create a compressed archive
log "Creating compressed archive..."
ARCHIVE_NAME="vaultwarden-backup-${DATE}.tar.gz"
tar -czf "${BACKUP_DIR}/${ARCHIVE_NAME}" -C "${BACKUP_DIR}" "${DATE}"

# Calculate checksums
log "Calculating checksums..."
sha256sum "${BACKUP_DIR}/${ARCHIVE_NAME}" > "${BACKUP_DIR}/${ARCHIVE_NAME}.sha256"

# Remove uncompressed backup directory
rm -rf "${BACKUP_SUBDIR}"

# Clean up old backups
log "Cleaning up backups older than ${RETENTION_DAYS} days..."
find "${BACKUP_DIR}" -name "vaultwarden-backup-*.tar.gz*" -mtime +${RETENTION_DAYS} -delete

# Summary
BACKUP_SIZE=$(du -h "${BACKUP_DIR}/${ARCHIVE_NAME}" | cut -f1)
log "Backup completed successfully!"
log "  Archive: ${BACKUP_DIR}/${ARCHIVE_NAME}"
log "  Size: ${BACKUP_SIZE}"
log "  Checksum: ${BACKUP_DIR}/${ARCHIVE_NAME}.sha256"

# List recent backups
echo ""
log "Recent backups:"
ls -lht "${BACKUP_DIR}"/vaultwarden-backup-*.tar.gz 2>/dev/null | head -5