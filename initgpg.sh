#!/usr/bin/env bash
set -euo pipefail

# Configuration
: "${AGENT_HOST:?Error: AGENT_HOST must be set}"
: "${GPG_PASSPHRASE:?Error: GPG_PASSPHRASE must be set}"
readonly GPG_KEY_FILE="$HOME/.gpg.key"
readonly SSH_OPTS=(
    -o "UserKnownHostsFile=/dev/null"
    -o "StrictHostKeyChecking=no"
    -o "LogLevel=ERROR"
)
readonly GPG_OPTS=(
    --batch
    --pinentry-mode=loopback
    --no-tty
    --passphrase-fd 0
    --trust-model always
    --yes
)

# Cleanup function
cleanup() {
    if [[ -f "$GPG_KEY_FILE" ]]; then
        shred -u "$GPG_KEY_FILE" 2>/dev/null || rm -f "$GPG_KEY_FILE"
        echo "Securely removed GPG key file"
    fi
}

# Error handling
trap 'cleanup; exit 1' ERR TERM INT
trap cleanup EXIT

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Main execution
main() {
    log "Starting GPG key transfer and import"

    # Transfer the key securely
    log "Transferring GPG key from ${AGENT_HOST}"
    if ! rsync -q -aP -e "ssh ${SSH_OPTS[*]}" "${AGENT_HOST}:.gpg.key" "$GPG_KEY_FILE"; then
        log "Failed to transfer GPG key" >&2
        exit 1
    fi

    # Set strict permissions
    chmod 600 "$GPG_KEY_FILE"

    # Import the key
    log "Importing GPG key"
    if ! echo "$GPG_PASSPHRASE" | /usr/bin/gpg "${GPG_OPTS[@]}" --import "$GPG_KEY_FILE" &>/dev/null; then
        log "Failed to import GPG key" >&2
        exit 1
    fi

    # Initialize trustdb
    log "Initializing GPG trust database"
    if ! /usr/bin/gpg --list-keys &>/dev/null; then
        log "Failed to initialize GPG trust database" >&2
        exit 1
    fi

    log "GPG key import completed successfully"
}

main "$@"
