#!/usr/bin/env bash
set -euo pipefail

# Constants
readonly MVN_PID_FILE="/tmp/.mvnpid"
readonly DEFAULT_MAVEN_WAIT_TIMEOUT=300
# Timings are overridable for testing
readonly SSH_SLEEP_BEFORE_EXIT=${SSH_SLEEP_BEFORE_EXIT:-30}   # idle time (no SSH session) required after the build
readonly SSH_MAX_DRAIN=${SSH_MAX_DRAIN:-600}                  # upper bound for Jenkins to collect results
readonly SSH_TUNNEL_RETRIES=${SSH_TUNNEL_RETRIES:-8}
readonly SSH_TUNNEL_SETTLE=${SSH_TUNNEL_SETTLE:-3}
readonly SSHD_PORT=22
readonly SSH_KEY_DIR=~/.ssh
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
CLEANED_UP=0
cleanup() {
  local exit_code=$?
  ((CLEANED_UP)) && return 0
  CLEANED_UP=1
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

  for key in "$SSH_KEY_DIR"/id_*; do
    # Skip public keys: ssh-keygen -y only works on private keys
    [[ "$key" == *.pub ]] && continue
    if [[ -f "$key" ]]; then
      local pubkey
      if ! pubkey=$(ssh-keygen -y -f "$key"); then
        log_error "Failed to process SSH key: $key"
        return 1
      fi
      # Avoid duplicate entries on re-runs
      grep -qxF "$pubkey" "$AUTHORIZED_KEYS" || echo "$pubkey" >>"$AUTHORIZED_KEYS"
      log_info "Added public key from: $key"
    fi
  done

  chmod 600 "$AUTHORIZED_KEYS"
}

# True while the SSH tunnel process is alive
tunnel_alive() {
  [[ -n "${SSH_PID:-}" ]] && kill -0 "$SSH_PID" 2>/dev/null
}

# Start SSH tunnel. ExitOnForwardFailure makes ssh die asynchronously (host down,
# remote port taken), so check it is still alive after a short settle time and retry.
start_ssh_tunnel() {
  local attempt
  for ((attempt = 1; attempt <= SSH_TUNNEL_RETRIES; attempt++)); do
    log_info "Starting SSH tunnel to ${AGENT_HOST} forwarding port ${AGENT_FORWARD_PORT} (attempt ${attempt}/${SSH_TUNNEL_RETRIES})"

    ssh -o UserKnownHostsFile=/dev/null \
      -o StrictHostKeyChecking=no \
      -o LogLevel=ERROR \
      -o ConnectTimeout=20 \
      -o ExitOnForwardFailure=yes \
      -o TCPKeepAlive=yes \
      -o ServerAliveInterval=15 \
      -o ServerAliveCountMax=3 \
      -g -N "$AGENT_HOST" \
      -R "${AGENT_FORWARD_PORT}:localhost:${SSHD_PORT}" &

    SSH_PID=$!
    sleep "$SSH_TUNNEL_SETTLE"
    if tunnel_alive; then
      log_info "SSH tunnel established (PID: $SSH_PID)"
      return 0
    fi
    wait "$SSH_PID" 2>/dev/null || true
    # Backoff capped at 10s: after a network drop the Jenkins host may still hold the
    # remote port of the dead session until its own keepalive expires
    local delay=$((attempt * 2))
    ((delay > 10)) && delay=10
    log_error "SSH tunnel exited early, retrying in ${delay}s"
    sleep "$delay"
  done

  log_error "Unable to establish the SSH tunnel after ${SSH_TUNNEL_RETRIES} attempts"
  return 1
}

# Restart the tunnel if it dropped; Jenkins reconnects through the same port
ensure_tunnel() {
  tunnel_alive && return 0
  log_error "SSH tunnel is down, restarting it"
  start_ssh_tunnel
}

# Number of established SSH sessions on this runner (Jenkins uses them to run mvn and fetch results)
ssh_sessions() {
  ss -Htn state established "( sport = :${SSHD_PORT} )" 2>/dev/null | wc -l
}

# Wait for Maven process
wait_for_maven() {
  local count=0
  local sleep_interval=5
  local max_attempts=$((MAVEN_WAIT_TIMEOUT / sleep_interval))

  log_info "Waiting for Maven process (timeout: ${MAVEN_WAIT_TIMEOUT}s)"

  while ((count++ < max_attempts)); do
    ensure_tunnel || return 1
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
    ensure_tunnel || return 1
    log_info "Maven process still running (PID: $mvn_pid)"
  done

  log_info "Maven build completed"
}

# Keep the runner (and the tunnel) up until Jenkins has finished with it: it still
# fetches test reports after mvn exits. Stop once no SSH session has been open for
# SSH_SLEEP_BEFORE_EXIT seconds, or after SSH_MAX_DRAIN seconds in any case.
drain_ssh_sessions() {
  local idle=0 elapsed=0
  log_info "Waiting for Jenkins to finish (idle ${SSH_SLEEP_BEFORE_EXIT}s, max ${SSH_MAX_DRAIN}s)"
  while ((idle < SSH_SLEEP_BEFORE_EXIT && elapsed < SSH_MAX_DRAIN)); do
    sleep 1
    ((++elapsed))
    if (($(ssh_sessions) > 0)); then
      idle=0
    else
      ((++idle))
    fi
  done
  log_info "Jenkins is done (idle: ${idle}s, waited: ${elapsed}s)"
}

# Main execution
main() {
  trap cleanup EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT

  setup_ssh || exit 1
  start_ssh_tunnel
  wait_for_maven || exit 1
  monitor_maven

  drain_ssh_sessions
}

main "$@"
