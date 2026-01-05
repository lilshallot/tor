#!/usr/bin/env sh
set -eu

: "${TOR_CONTROL_PORT:=9051}"
: "${TOR_COOKIE_FILE:=/var/lib/tor/control_auth_cookie}"

# SOCKS should be listening
nc -z 127.0.0.1 9050

# Cookie exists
[ -s "$TOR_COOKIE_FILE" ]

COOKIE_HEX="$(od -An -tx1 -v "$TOR_COOKIE_FILE" | tr -d ' \n')"

PHASE="$(printf 'AUTHENTICATE %s\r\nGETINFO status/bootstrap-phase\r\nQUIT\r\n' "$COOKIE_HEX" \
  | nc -w 1 127.0.0.1 "$TOR_CONTROL_PORT" 2>/dev/null \
  | tr -d '\r' \
  | sed -n 's/^250-status\/bootstrap-phase=//p' \
  | head -n 1)"

echo "$PHASE" | grep -q 'PROGRESS=100'
