#!/usr/bin/env bash
set -euo pipefail

# Constants
readonly MVN_PID_FILE="/tmp/.mvnpid"
readonly DEFAULT_MAVEN_WAIT_TIMEOUT=300
readonly SSH_SLEEP_BEFORE_EXIT=30
readonly SSH_KEY_GLOB=~/.ssh/id_*
readonly AUTHORIZED_KEYS=~/.ssh/authorized_keys

# Configuration (with validation)
: "${AGENT_FORWARD_PORT:?Error: AGENT_FORWARD_PORT must be set}"
: "${AGENT_HOST:?Error: AGENT_HOST must be set}"
readonly MAVEN_WAIT_TIMEOUT=${MAVEN_WAIT_TIMEOUT:-$DEFAULT_MAVEN_WAIT_TIMEOUT}

# Logging functions
log_info() {
  echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_error() {
  echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

# Cleanup function
cleanup() {
  local exit_code=$?
  log_info "Starting cleanup process"

  if [[ -n "${SSH_PID:-}" && -d "/proc/$SSH_PID" ]]; then
    log_info "Stopping SSH tunnel (PID: $SSH_PID)"
    kill -TERM "$SSH_PID" 2>/dev/null || true
    # Wait for process to terminate
    sleep 2
    if kill -0 "$SSH_PID" 2>/dev/null; then
      log_info "Force killing SSH tunnel"
      kill -KILL "$SSH_PID" 2>/dev/null || true
    fi
  fi

  if [[ -f "$MVN_PID_FILE" ]]; then
    log_info "Removing PID file: $MVN_PID_FILE"
    rm -f "$MVN_PID_FILE"
  fi

  log_info "Cleanup complete"
  exit $exit_code
}

# Setup SSH keys
setup_ssh() {
  log_info "Setting up SSH keys"

  if ! [[ -f $AUTHORIZED_KEYS ]]; then
    touch "$AUTHORIZED_KEYS"
    chmod 600 "$AUTHORIZED_KEYS"
  fi

  for key in $SSH_KEY_GLOB; do
    if [[ -f "$key" ]]; then
      if ! ssh-keygen -y -f "$key" >>"$AUTHORIZED_KEYS"; then
        log_error "Failed to process SSH key: $key"
        return 1
      fi
      log_info "Added public key from: $key"
    fi
  done

  chmod 600 "$AUTHORIZED_KEYS"
}

# Start SSH tunnel
start_ssh_tunnel() {
  log_info "Starting SSH tunnel to ${AGENT_HOST} forwarding port ${AGENT_FORWARD_PORT}"

  ssh -o UserKnownHostsFile=/dev/null \
    -o StrictHostKeyChecking=no \
    -o LogLevel=ERROR \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=60 \
    -o ServerAliveCountMax=3 \
    -g -N "$AGENT_HOST" \
    -R "${AGENT_FORWARD_PORT}:localhost:22" &

  SSH_PID=$!
  log_info "SSH tunnel established (PID: $SSH_PID)"
}

# Wait for Maven process
wait_for_maven() {
  local count=0
  local sleep_interval=5
  local max_attempts=$((MAVEN_WAIT_TIMEOUT / sleep_interval))

  log_info "Waiting for Maven process (timeout: ${MAVEN_WAIT_TIMEOUT}s)"

  while ((count++ < max_attempts)); do
    if [[ -f "$MVN_PID_FILE" ]]; then
      local mvn_pid
      mvn_pid=$(cat "$MVN_PID_FILE")

      if pgrep -P "$mvn_pid" >/dev/null; then
        log_info "Maven process detected (Wrapper PID: $mvn_pid)"
        return 0
      fi
    fi

    sleep "$sleep_interval"
    log_info "Waiting... ($((count * sleep_interval))s/${MAVEN_WAIT_TIMEOUT}s)"
  done

  log_error "Timeout waiting for Maven process to start"
  return 1
}

# Monitor Maven process
monitor_maven() {
  local mvn_pid
  mvn_pid=$(cat "$MVN_PID_FILE")

  log_info "Monitoring Maven process (PID: $mvn_pid)"

  while kill -0 "$mvn_pid" 2>/dev/null; do
    sleep 10
    log_info "Maven process still running (PID: $mvn_pid)"
  done

  log_info "Maven build completed"
}

# Main execution
main() {
  trap cleanup EXIT TERM INT

  setup_ssh || exit 1
  start_ssh_tunnel
  wait_for_maven || exit 1
  monitor_maven

  log_info "Build finished. Waiting ${SSH_SLEEP_BEFORE_EXIT}s before cleanup..."
  sleep "$SSH_SLEEP_BEFORE_EXIT"
}

main "$@"
