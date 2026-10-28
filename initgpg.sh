#!/usr/bin/env bash
set -euo pipefail

# Configuration
: "${AGENT_HOST:?Error: AGENT_HOST must be set}"
: "${GPG_PASSPHRASE:?Error: GPG_PASSPHRASE must be set}"
readonly GPG_KEY_FILE="$HOME/.gpg.key"
# Host key policy for the Jenkins agent host (same as daemon.sh): yes (known_hosts entry
# required), auto (verify when the host is in known_hosts, warn otherwise), no
readonly STRICT_HOST_KEY_CHECKING=${STRICT_HOST_KEY_CHECKING:-auto}
SSH_OPTS=(-o "LogLevel=ERROR")
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

configure_host_key_checking() {
    local known_hosts=~/.ssh/known_hosts port name
    port=$(ssh -G "$AGENT_HOST" 2>/dev/null | awk '$1 == "port" {print $2; exit}')
    name="$AGENT_HOST"
    [[ -n "$port" && "$port" != 22 ]] && name="[${AGENT_HOST}]:${port}"

    if [[ "$STRICT_HOST_KEY_CHECKING" != no ]] && ssh-keygen -F "$name" -f "$known_hosts" >/dev/null 2>&1; then
        SSH_OPTS+=(-o "UserKnownHostsFile=${known_hosts}" -o "StrictHostKeyChecking=yes")
    elif [[ "$STRICT_HOST_KEY_CHECKING" == yes ]]; then
        log "${name} is not in known_hosts (KNOWN_HOSTS secret) and STRICT_HOST_KEY_CHECKING=yes" >&2
        exit 1
    else
        log "WARNING: host key of ${name} is not verified (add it to the KNOWN_HOSTS secret)" >&2
        SSH_OPTS+=(-o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no")
    fi
}

# Main execution
main() {
    configure_host_key_checking

    log "Starting GPG key transfer and import"

    # Transfer the key securely
    log "Transferring GPG key from ${AGENT_HOST}"
    local attempt
    for attempt in 1 2 3 4 5; do
        if rsync -q -aP -e "ssh ${SSH_OPTS[*]} -o ConnectTimeout=20" "${AGENT_HOST}:.gpg.key" "$GPG_KEY_FILE"; then
            break
        fi
        if [[ $attempt -eq 5 ]]; then
            log "Failed to transfer GPG key" >&2
            exit 1
        fi
        log "GPG key transfer failed (attempt ${attempt}/5), retrying"
        sleep $((attempt * 2))
    done

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
