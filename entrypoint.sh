#!/usr/bin/env bash
set -euo pipefail

# =========================
# Defaults
# =========================
: "${TOR_DATA_DIR:=/var/lib/tor}"
: "${TOR_CONF_DIR:=/etc/tor/torrc.d}"

: "${TOR_LOG_LEVEL:=notice}"

: "${TOR_SOCKS_BIND_IP:=0.0.0.0}"
: "${TOR_SOCKS_PORT:=9050}"
# Comma-separated CIDRs/IPs for SocksPolicy accept
: "${TOR_SOCKS_ALLOW:=127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16}"

: "${TOR_CONTROL_BIND_IP:=127.0.0.1}"
: "${TOR_CONTROL_PORT:=9051}"
: "${TOR_COOKIE_FILE:=/var/lib/tor/control_auth_cookie}"

# DNSPort is OFF by default to avoid open-proxy problems.
# To enable: TOR_DNSPORT=127.0.0.1:5353 (or LAN IP)
: "${TOR_DNSPORT:=}"
# Bridges
: "${TOR_USE_BRIDGES:=0}"
: "${TOR_BRIDGES:=}"  # multiline "Bridge obfs4 ..." lines
: "${TOR_BRIDGE_TRANSPORT:=obfs4}"  # transport name used in torrc block
: "${TOR_PT_EXEC:=/usr/bin/obfs4proxy}"

# Hidden services
: "${TOR_ENABLE_HS:=0}"
# Provide complete HS config as multiline torrc snippet:
# Example:
#   HiddenServiceDir /var/lib/tor/hs/myservice
#   HiddenServicePort 80 127.0.0.1:8080
: "${TOR_HS_CONF:=}"

# Bootstrap wait (for health / dependent services)
: "${TOR_WAIT_BOOTSTRAP:=1}"
: "${TOR_BOOTSTRAP_TIMEOUT:=120}"
: "${TOR_BOOTSTRAP_POLL:=2}"

# =========================
# Prep
# =========================
mkdir -p "${TOR_DATA_DIR}" "${TOR_CONF_DIR}"
chown -R debian-tor:debian-tor "${TOR_DATA_DIR}"
chmod 700 "${TOR_DATA_DIR}"

# ==================================
# Build config
# ==================================
TOR_DNSPORT_LINE="# DNSPort disabled"
if [[ -n "${TOR_DNSPORT}" ]]; then
  TOR_DNSPORT_LINE="DNSPort ${TOR_DNSPORT}"
fi

TOR_BRIDGES_BLOCK=""
if [[ "${TOR_USE_BRIDGES}" == "1" ]]; then
  if [[ -z "${TOR_BRIDGES}" ]]; then
    echo "ERROR: TOR_USE_BRIDGES=1 but TOR_BRIDGES is empty."
    exit 1
  fi

  # Validate transport exec if using obfs4 by default
  if [[ "${TOR_BRIDGE_TRANSPORT}" == "obfs4" ]]; then
    if [[ ! -x "${TOR_PT_EXEC}" ]]; then
      echo "ERROR: obfs4proxy not found at ${TOR_PT_EXEC}."
      echo "Tip: set TOR_PT_EXEC to the correct path or install the transport."
      exit 1
    fi
  fi

  # Strip leading whitespace from bridge lines (compose multiline often indents)
  CLEAN_BRIDGES="$(printf "%s\n" "${TOR_BRIDGES}" | sed 's/^[[:space:]]*//')"

  TOR_BRIDGES_BLOCK="$(cat <<EOF
UseBridges 1
ClientTransportPlugin ${TOR_BRIDGE_TRANSPORT} exec ${TOR_PT_EXEC}
${CLEAN_BRIDGES}
EOF
)"
fi

TOR_HS_BLOCK=""
if [[ "${TOR_ENABLE_HS}" == "1" ]]; then
  if [[ -z "${TOR_HS_CONF}" ]]; then
    echo "ERROR: TOR_ENABLE_HS=1 but TOR_HS_CONF is empty."
    exit 1
  fi
  CLEAN_HS="$(printf "%s\n" "${TOR_HS_CONF}" | sed 's/^[[:space:]]*//')"
  TOR_HS_BLOCK="${CLEAN_HS}"
fi

export TOR_DNSPORT_LINE TOR_BRIDGES_BLOCK TOR_HS_BLOCK

# =========================
# Render torrc from template
# =========================
if [ ! -s /etc/tor/torrc.template ]; then
  echo "ERROR: /etc/tor/torrc.template missing/empty"
  exit 1
fi
envsubst < /etc/tor/torrc.template > /etc/tor/torrc

# Safety warning if user exposes ControlPort
if [[ "${TOR_CONTROL_BIND_IP}" != "127.0.0.1" && "${TOR_CONTROL_BIND_IP}" != "localhost" ]]; then
  echo "WARNING: ControlPort is exposed on ${TOR_CONTROL_BIND_IP}:${TOR_CONTROL_PORT}."
  echo "This is NOT encrypted. Prefer 127.0.0.1 + no published port."
fi

# Verify config before starting
echo "[tor] verifying config..."
tor --verify-config -f /etc/tor/torrc

# =========================
# Start Tor (drop privileges)
# =========================
echo "[tor] starting..."
gosu debian-tor tor -f /etc/tor/torrc &
TOR_PID=$!

# =========================
# Optional bootstrap wait
# =========================
if [[ "${TOR_WAIT_BOOTSTRAP}" == "1" ]]; then
  echo "[tor] waiting for bootstrap=100..."
  START="$(date +%s)"
  LAST=""

  get_bootstrap() {
    # CookieAuthentication is enabled; query via control port on localhost
    if [[ ! -s "${TOR_COOKIE_FILE}" ]]; then
      return 0
    fi
    COOKIE_HEX="$(od -An -tx1 -v "${TOR_COOKIE_FILE}" | tr -d ' \n')"
    printf 'AUTHENTICATE %s\r\nGETINFO status/bootstrap-phase\r\nQUIT\r\n' "${COOKIE_HEX}" \
      | nc -w 1 127.0.0.1 "${TOR_CONTROL_PORT}" 2>/dev/null \
      | tr -d '\r' \
      | sed -n 's/^250-status\/bootstrap-phase=//p' \
      | head -n 1
  }

  while true; do
    PHASE="$(get_bootstrap || true)"
    if [[ -n "${PHASE}" && "${PHASE}" != "${LAST}" ]]; then
      echo "[tor] ${PHASE}"
      LAST="${PHASE}"
    fi

    if echo "${PHASE}" | grep -q 'PROGRESS=100'; then
      echo "[tor] bootstrap complete."
      break
    fi

    NOW="$(date +%s)"
    if (( NOW - START >= TOR_BOOTSTRAP_TIMEOUT )); then
      echo "ERROR: Tor did not reach bootstrap=100 within ${TOR_BOOTSTRAP_TIMEOUT}s."
      echo "Troubleshoot:"
      echo "  - verify bridges are reachable from this container/network"
      echo "  - ensure transport exec path is correct (TOR_PT_EXEC)"
      echo "  - inspect logs above for timeouts/TLS errors"
      kill "${TOR_PID}" || true
      exit 1
    fi

    sleep "${TOR_BOOTSTRAP_POLL}"
  done
fi

# Reap tor process
wait "${TOR_PID}"
