FROM debian:stable-slim

ENV DEBIAN_FRONTEND=noninteractive

# Packages:
# - tor
# - geoip db
# - obfs4proxy
# - tini/gosu for clean PID1 + drop privileges
# - gettext-base for envsubst templating
# - netcat-openbsd + curl for healthcheck + debugging
# - iptables for future use (not enabled by default)
RUN apt-get update && apt-get install -y --no-install-recommends \
    tor tor-geoipdb \
    obfs4proxy \
    ca-certificates curl \
    tini gosu \
    gettext-base \
    netcat-openbsd \
    iptables \
  && rm -rf /var/lib/apt/lists/*

# Create config dirs
RUN mkdir -p /etc/tor/torrc.d /var/lib/tor /var/log/tor \
  && chown -R debian-tor:debian-tor /var/lib/tor /var/log/tor \
  && chmod 700 /var/lib/tor

COPY torrc /etc/tor/torrc
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/entrypoint.sh"]
