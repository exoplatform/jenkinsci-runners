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
readonly MVN_JOB_DIR=${MVN_JOB_DIR:-/tmp/.mvnjob}                # state of the detached mvn build
readonly MVN_WRAPPER_DIR=${MVN_WRAPPER_DIR:-/usr/bin}
readonly ABANDON_TIMEOUT=${ABANDON_TIMEOUT:-300}                 # no SSH session for this long while mvn runs: Jenkins is gone
# Host key policy for the Jenkins agent host: yes (known_hosts entry required), auto (verify
# when the host is in known_hosts, warn and accept otherwise), no
readonly STRICT_HOST_KEY_CHECKING=${STRICT_HOST_KEY_CHECKING:-auto}
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

# Timeline written to the GitHub job summary
EVENTS=()
record_event() {
  EVENTS+=("$(date '+%H:%M:%S')|$*")
}

write_summary() {
  [[ -n "${GITHUB_STEP_SUMMARY:-}" && ${#EVENTS[@]} -gt 0 ]] || return 0
  {
    echo "### Jenkins agent ${AGENT_HOST}:${AGENT_FORWARD_PORT}"
    echo "| Time (UTC) | Event |"
    echo "| --- | --- |"
    local e
    for e in "${EVENTS[@]}"; do
      echo "| ${e%%|*} | ${e#*|} |"
    done
  } >>"$GITHUB_STEP_SUMMARY" || true
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

  write_summary
  log_info "Cleanup complete"
  exit $exit_code
}

# SSH options for the Jenkins agent host. The tunnel carries the build and the signing
# setup, so the host must be the expected one: use the known_hosts the ssh-key action wrote.
HOSTKEY_OPTS=()
configure_host_key_checking() {
  local known_hosts=~/.ssh/known_hosts port name
  port=$(ssh -G "$AGENT_HOST" 2>/dev/null | awk '$1 == "port" {print $2; exit}')
  name="$AGENT_HOST"
  [[ -n "$port" && "$port" != 22 ]] && name="[${AGENT_HOST}]:${port}"

  if [[ "$STRICT_HOST_KEY_CHECKING" != no ]] && ssh-keygen -F "$name" -f "$known_hosts" >/dev/null 2>&1; then
    log_info "Verifying the host key of ${name} against known_hosts"
    HOSTKEY_OPTS=(-o "UserKnownHostsFile=${known_hosts}" -o StrictHostKeyChecking=yes)
  elif [[ "$STRICT_HOST_KEY_CHECKING" == yes ]]; then
    log_error "${name} is not in known_hosts (KNOWN_HOSTS secret) and STRICT_HOST_KEY_CHECKING=yes"
    return 1
  else
    log_error "WARNING: host key of ${name} is not verified (add it to the KNOWN_HOSTS secret, then set STRICT_HOST_KEY_CHECKING=yes)"
    HOSTKEY_OPTS=(-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no)
  fi
}

# Install the mvn wrapper Jenkins runs over SSH. The build runs detached (own session, log
# and exit code kept in MVN_JOB_DIR) so a lost SSH session or tunnel does not kill it:
# calling the wrapper again with the same arguments re-attaches to the running build.
# Exit code 255 is reserved for ssh itself, so Jenkins can tell "connection lost" from a build failure.
install_mvn_wrapper() {
  local real_mvn target="${MVN_WRAPPER_DIR}/mvn" tmp
  real_mvn=$(command -v mvn) || { log_error "mvn not found in PATH"; return 1; }
  tmp=$(mktemp)
  sed "s|__REAL_MVN__|${real_mvn}|; s|__JOB_DIR__|${MVN_JOB_DIR}|; s|__PID_FILE__|${MVN_PID_FILE}|" >"$tmp" <<'WRAPPER'
#!/usr/bin/env bash
[[ -r /etc/profile ]] && . /etc/profile
REAL_MVN='__REAL_MVN__'
JOB_DIR='__JOB_DIR__'
PID_FILE='__PID_FILE__'

fingerprint=$(printf '%s\0' "$PWD" "$@" | sha256sum | cut -d' ' -f1)
job_pid() { cat "$JOB_DIR/pid" 2>/dev/null; }
# Same directory and arguments as the build already started on this runner: never start a
# second build (Jenkins runs mvn once per runner), re-attach, or report the stored result.
if [[ "$(cat "$JOB_DIR/fingerprint" 2>/dev/null)" == "$fingerprint" ]]; then
  tail_from=200
  echo "[mvn-wrapper] re-attaching to the build (last $tail_from lines may repeat)" >&2
else
  rm -rf "$JOB_DIR"
  mkdir -m 700 "$JOB_DIR"
  echo "$fingerprint" >"$JOB_DIR/fingerprint"
  : >"$JOB_DIR/log"
  setsid bash -c '
    echo $$ >"$0/pid.tmp" && mv "$0/pid.tmp" "$0/pid" && cp "$0/pid" "$1"
    shift; real_mvn=$1; shift
    "$real_mvn" -V "$@"
    rc=$?
    echo "$rc" >"$0/rc.tmp" && mv "$0/rc.tmp" "$0/rc"
  ' "$JOB_DIR" "$PID_FILE" "$REAL_MVN" "$@" >"$JOB_DIR/log" 2>&1 </dev/null &
  for _ in $(seq 1 50); do [[ -f "$JOB_DIR/pid" ]] && break; sleep 0.2; done
  tail_from=+1
fi

pid=$(job_pid)
[[ -n "$pid" ]] || { echo "[mvn-wrapper] build did not start" >&2; exit 254; }
tail -n "$tail_from" -f --pid="$pid" "$JOB_DIR/log"
for _ in $(seq 1 20); do [[ -f "$JOB_DIR/rc" ]] && break; sleep 0.5; done
# 137: the build died without leaving an exit code
rc=$(cat "$JOB_DIR/rc" 2>/dev/null || echo 137)
(( rc == 255 )) && rc=254
exit "$rc"
WRAPPER
  chmod 755 "$tmp"
  if [[ -w "$MVN_WRAPPER_DIR" ]]; then mv "$tmp" "$target"; else sudo mv "$tmp" "$target"; fi
  log_info "Installed mvn wrapper ${target} (real mvn: ${real_mvn})"
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

    ssh "${HOSTKEY_OPTS[@]}" \
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
      record_event "SSH tunnel up (attempt ${attempt})"
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

# Monitor Maven process. If Jenkins disappears (aborted build, lost for good) the detached
# build would run for hours: stop it when no SSH session was open for ABANDON_TIMEOUT.
monitor_maven() {
  local mvn_pid idle=0
  mvn_pid=$(cat "$MVN_PID_FILE")

  log_info "Monitoring Maven process (PID: $mvn_pid)"
  record_event "Maven started"

  while kill -0 "$mvn_pid" 2>/dev/null; do
    sleep 10
    ensure_tunnel || return 1
    if (($(ssh_sessions) > 0)); then
      idle=0
    else
      ((idle += 10))
      if ((idle >= ABANDON_TIMEOUT)); then
        log_error "No SSH session for ${idle}s, Jenkins is gone: stopping the build"
        record_event "Build stopped: Jenkins gone for ${idle}s"
        pkill -TERM -s "$mvn_pid" 2>/dev/null || true
        sleep 5
        pkill -KILL -s "$mvn_pid" 2>/dev/null || true
        return 1
      fi
    fi
    log_info "Maven process still running (PID: $mvn_pid)"
  done

  log_info "Maven build completed"
  record_event "Maven build completed"
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
  record_event "Jenkins finished (waited ${elapsed}s)"
}

# Main execution
main() {
  trap cleanup EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT

  setup_ssh || exit 1
  configure_host_key_checking || exit 1
  install_mvn_wrapper || exit 1
  start_ssh_tunnel
  wait_for_maven || exit 1
  monitor_maven

  drain_ssh_sessions
}

main "$@"
