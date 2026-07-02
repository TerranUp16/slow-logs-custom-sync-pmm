#!/usr/bin/env bash
# Generates a private CA and the DO client cert needed for mutual-TLS syslog
# forwarding between DO Managed MySQL and the sink Droplet.
#
#   ca.pem / ca-key.pem      - private CA (KEEP ca-key.pem OFFLINE, never deploy)
#   do-client-cert.pem/-key  - paste into DO log-forwarding Client Cert/Key;
#                              rsyslog verifies it with ca.pem
#
# The rsyslog server cert is NOT generated here — setup.sh obtains a publicly-
# trusted Let's Encrypt cert for SINK_HOSTNAME via certbot, because DO verifies
# the sink's server cert against its own system CA bundle (a private/self-signed
# server cert is always rejected with certificate_unknown).
#
# DO log-forwarding fields map to:
#   CA Certificate     -> LEAVE BLANK (DO trusts the LE server cert via system bundle)
#   Client Certificate -> certs/do-client-cert.pem
#   Client Key         -> certs/do-client-key.pem
#
# Run locally (not on the droplet). setup.sh deploys ca.pem to the droplet.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$HERE/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$HERE/.env"
  set +a
fi

OUT="$HERE/certs"
DAYS_CA=3650
DAYS_LEAF=825

mkdir -p "$OUT"
chmod 700 "$OUT"

# 1. Private CA (reused on re-run so existing leaves stay valid)
if [ -f "$OUT/ca.pem" ]; then
  echo "==> Reusing existing CA at $OUT/ca.pem"
else
  echo "==> Generating CA"
  openssl genrsa -out "$OUT/ca-key.pem" 4096
  openssl req -x509 -new -nodes -key "$OUT/ca-key.pem" -sha256 -days "$DAYS_CA" \
    -subj "/CN=mysql-sink-ca" -out "$OUT/ca.pem"
fi

# 2. DO client cert (DO presents this to rsyslog; rsyslog requires it to be CA-signed)
echo "==> Generating DO client cert"
openssl genrsa -out "$OUT/do-client-key.pem" 4096
openssl req -new -key "$OUT/do-client-key.pem" -subj "/CN=do-logforward-client" \
  -out "$OUT/do-client.csr"
openssl x509 -req -in "$OUT/do-client.csr" -CA "$OUT/ca.pem" -CAkey "$OUT/ca-key.pem" \
  -CAcreateserial -days "$DAYS_LEAF" -sha256 \
  -extfile <(printf 'extendedKeyUsage=clientAuth\n') \
  -out "$OUT/do-client-cert.pem"

rm -f "$OUT"/*.csr "$OUT"/*.srl
chmod 600 "$OUT"/*-key.pem
chmod 644 "$OUT"/*-cert.pem "$OUT/ca.pem"

cat <<EOF

==> Done. Files in $OUT/

  Deployed automatically by setup.sh: ca.pem (verifies DO's client cert only).
  The rsyslog SERVER cert is a Let's Encrypt cert obtained by setup.sh for
  SINK_HOSTNAME — nothing to generate or paste for that side.

  Paste into DO control panel (Databases -> Logs -> Log Forwarding, TLS):
      CA Certificate     = <LEAVE BLANK>   (DO trusts the LE server cert via its system bundle)
      Client Certificate = certs/do-client-cert.pem
      Client Key         = certs/do-client-key.pem
  Destination endpoint  = ${SINK_HOSTNAME:-<SINK_HOSTNAME from .env>}   (a hostname, NOT a raw IP)

  KEEP OFFLINE, NEVER COMMIT OR DEPLOY: certs/ca-key.pem
EOF
