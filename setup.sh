#!/usr/bin/env bash
# Deploys and configures the MySQL slow log sink + PMM 3 integration on sink-experiment droplet.
# Run as root on the droplet.  Reads credentials from .env in the same directory.
set -euo pipefail

# Surface *any* unexpected failure with the line/command that caused it,
# instead of dying silently mid-script with just the last "==>" banner
# printed. The explicit checks below still print a more specific, actionable
# message for the failure modes we know about (DB unreachable, missing
# files, PMM registration not showing up).
trap 'echo "ERROR: setup.sh aborted at line $LINENO: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR_LOCAL="$(cd "$(dirname "$0")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR_LOCAL/common.sh"

# Load .env if present
if [ -f "$SCRIPT_DIR_LOCAL/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR_LOCAL/.env"
  set +a
fi

DB_HOST="${DB_HOST:?Set DB_HOST in .env}"
DB_PORT="${DB_PORT:-25060}"
PMM_MONITOR_USER="${PMM_MONITOR_USER:-pmm_monitor}"
DB_PASS="${DB_PASS:?Set DB_PASS in .env}"
PMM_SERVER="${PMM_SERVER:?Set PMM_SERVER in .env}"
PMM_TOKEN="${PMM_TOKEN:-}"
DO_CA_BUNDLE="${DO_CA_BUNDLE:-/etc/mysql_sink/do-ca.crt}"   # destination on the droplet
DO_CA_SRC="${DO_CA_SRC:-$SCRIPT_DIR_LOCAL/certs/do-ca.crt}"  # local copy downloaded from DO control panel

# Public DNS hostname for the sink. certbot issues a publicly-trusted Let's Encrypt
# cert for this name; rsyslog presents it, and DO verifies it against its own system
# CA bundle (so DO's "CA Certificate" log-forwarding field is left BLANK). This name
# MUST resolve publicly to this droplet's IP for the HTTP-01 challenge to succeed, and
# it MUST be the destination configured in DO log forwarding.
SINK_HOSTNAME="${SINK_HOSTNAME:?Set SINK_HOSTNAME in .env - public DNS name for the sink, e.g. logs.example.com}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:?Set LETSENCRYPT_EMAIL in .env - contact address for the ACME account}"
LE_LIVE="/etc/letsencrypt/live/${SINK_HOSTNAME}"

# Percona apt-bootstrap .deb. Pin a versioned URL + its SHA256 in .env for
# reproducible, verified installs. If PERCONA_RELEASE_SHA256 is set, the download
# must match or setup aborts; if unset, the download proceeds with a loud warning.
PERCONA_RELEASE_URL="${PERCONA_RELEASE_URL:-https://repo.percona.com/apt/percona-release_latest.generic_all.deb}"
PERCONA_RELEASE_SHA256="${PERCONA_RELEASE_SHA256:-}"

SCRIPT_DIR="/var/log/mysql_sink/bin"
INCOMING_DIR="/var/log/mysql_sink/incoming"
PROCESSED_DIR="/var/log/mysql_sink/processed"

echo "==> Checking OS compatibility"
# Only Ubuntu 22.04 LTS and 24.04 LTS are supported. Percona has not released
# (or tested) percona-release/pmm-client packages for other versions,
# including 26.04 LTS — getting pmm-client installed there requires manually
# rewriting apt package-source distro codenames to point at an older
# release's repo. That may happen to work, but it's unverified by Percona
# and can break silently on any Percona-side update. This is a warning, not
# a hard stop, so existing unsupported test boxes aren't locked out — but
# don't deploy a real integration this way.
if [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${VERSION_ID:-}" in
    22.04|24.04) : ;;
    *)
      echo "" >&2
      echo "WARNING: this is Ubuntu ${VERSION_ID:-<unknown>}, not 22.04 LTS or 24.04 LTS." >&2
      echo "Percona does not support/test pmm-client packages on this version. See the" >&2
      echo "RUNBOOK 'Supported OS versions' note. Continuing in 5s — Ctrl+C to abort." >&2
      sleep 5
      ;;
  esac
else
  echo "WARNING: /etc/os-release not found — could not verify this is a supported Ubuntu release." >&2
fi

echo "==> Preflight: verifying direct DB connectivity before making any changes"
# Direct to DB_HOST:DB_PORT (not through socat — it doesn't exist yet) using
# the local certs/do-ca.crt copy. Runs before any package installs, cert
# issuance, or PMM work so a bad DB_HOST/DB_PASS/Trusted-Sources setup fails
# fast with a real error instead of burning 5-10 minutes first.
[ -f "$DO_CA_SRC" ] || { echo "ERROR: missing $DO_CA_SRC — download the CA cert from the DO DB control panel (Connection Details -> Download CA certificate) and save it there." >&2; exit 1; }
if ! mysql_probe "$PMM_MONITOR_USER" "$DB_PASS" "$DB_HOST" "$DB_PORT" "$DO_CA_SRC" "SELECT 1;" >/dev/null; then
  echo "" >&2
  echo "ERROR: setup.sh cannot reach/authenticate to the Managed MySQL DB directly at ${DB_HOST}:${DB_PORT}." >&2
  echo "Nothing has been changed on this droplet yet — fix connectivity/credentials and re-run." >&2
  exit 1
fi
echo "  DB reachable, credentials verified (direct, pre-socat)."

if [ -z "$PMM_TOKEN" ]; then
  echo "==> PMM_TOKEN is empty — checking whether PMM server is installed"
  if ! curl -sk --max-time 5 -o /dev/null "https://${PMM_SERVER}/"; then
    cat >&2 <<INSTR
ERROR: PMM_TOKEN is not set, and PMM server at ${PMM_SERVER} is not reachable.

Install PMM server first — SSH into that droplet and run:
  curl -fsSL https://www.percona.com/get/pmm | bash

Then re-run this script. If nobody has logged into the PMM web UI yet (still
on the default admin/admin password), this script will mint an Admin API
token automatically. If the admin password has already been changed, log
into https://${PMM_SERVER}, go to Settings -> API Keys -> Add API Key
(role: Admin), and put the token into .env as PMM_TOKEN instead.
INSTR
    exit 1
  fi

  echo "==> PMM server reachable — attempting to mint an API token (default admin/admin)"
  # PMM 3 ships Grafana 9+, which replaced the legacy /api/auth/keys endpoint with
  # Service Accounts: create a service account, then mint a token for it.
  PMM_MINT_FAIL() {
    cat >&2 <<INSTR
ERROR: Could not auto-mint a PMM API token — default admin/admin credentials
were rejected (the admin password has likely already been changed via the
PMM UI), or the PMM API returned an unexpected response.

Log into https://${PMM_SERVER}, go to Settings -> API Keys -> Add API Key
(role: Admin), and put the resulting token into .env as PMM_TOKEN. Then
re-run this script.
INSTR
    exit 1
  }
  SA_RESPONSE="$(curl -fsSk --max-time 10 -u admin:admin -X POST \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"sink-setup-$(date +%s)\",\"role\":\"Admin\"}" \
    "https://${PMM_SERVER}/graph/api/serviceaccounts" 2>&1)" || PMM_MINT_FAIL
  SA_ID="$(printf '%s' "$SA_RESPONSE" | grep -oP '"id"\s*:\s*\K[0-9]+' | head -1)"
  [ -n "$SA_ID" ] || PMM_MINT_FAIL

  TOKEN_RESPONSE="$(curl -fsSk --max-time 10 -u admin:admin -X POST \
    -H 'Content-Type: application/json' \
    -d '{"name":"sink-setup-token"}' \
    "https://${PMM_SERVER}/graph/api/serviceaccounts/${SA_ID}/tokens" 2>&1)" || PMM_MINT_FAIL
  PMM_TOKEN="$(printf '%s' "$TOKEN_RESPONSE" | grep -oP '"key"\s*:\s*"[^"]*"' | sed -E 's/.*:"//; s/"$//')"
  [ -n "$PMM_TOKEN" ] || PMM_MINT_FAIL

  echo "==> Minted PMM API token — writing PMM_TOKEN into .env"
  if grep -q '^PMM_TOKEN=' "$SCRIPT_DIR_LOCAL/.env" 2>/dev/null; then
    sed -i.bak "s|^PMM_TOKEN=.*|PMM_TOKEN=${PMM_TOKEN}|" "$SCRIPT_DIR_LOCAL/.env" && rm -f "$SCRIPT_DIR_LOCAL/.env.bak"
  else
    printf 'PMM_TOKEN=%s\n' "$PMM_TOKEN" >> "$SCRIPT_DIR_LOCAL/.env"
  fi
  echo "  NOTE: only the .env copy on this host was updated — copy PMM_TOKEN back"
  echo "  into your local repo's .env if you want it to persist for future runs."
fi

echo "==> Creating dedicated unprivileged service user"
useradd --system --no-create-home --shell /usr/sbin/nologin mysqlsink 2>/dev/null || true
usermod -aG adm mysqlsink   # read incoming/ (group adm)

echo "==> Creating directories"
mkdir -p "$SCRIPT_DIR" "$INCOMING_DIR" "$PROCESSED_DIR"

echo "==> Setting ownership (syslog writes incoming; daemon writes processed; pmm-agent reads via adm)"
# Base + incoming owned by syslog:adm; processed owned by the daemon user.
# Mode 750 keeps SQL text in the logs off-limits to other local users.
chown syslog:adm   /var/log/mysql_sink "$INCOMING_DIR"
chown mysqlsink:adm "$PROCESSED_DIR"
chown root:root    "$SCRIPT_DIR"
chmod 750 /var/log/mysql_sink "$INCOMING_DIR" "$PROCESSED_DIR"
chmod 755 "$SCRIPT_DIR"

echo "==> Deploying transform_logs.py"
cp "$(dirname "$0")/transform_logs.py" "$SCRIPT_DIR/transform_logs.py"
chmod +x "$SCRIPT_DIR/transform_logs.py"

echo "==> Installing socat, mysql-client, rsyslog TLS driver, and certbot"
apt-get update -q
# rsyslog-openssl provides lmnsd_ossl (OpenSSL driver) — required because the mTLS
# listener config below uses defaultNetstreamDriver="ossl" (gtls fails the DO
# handshake with "Decryption has failed", see RUNBOOK). rsyslog-gnutls provides a
# DIFFERENT driver (lmnsd_gtls) and does not satisfy this; installing it instead
# leaves imtcp unable to load and the port 6514 listener silently never starts.
apt-get install -y -q socat default-mysql-client rsyslog-openssl certbot

echo "==> Deploying private CA cert for client-cert verification"
CERT_SRC="$SCRIPT_DIR_LOCAL/certs"
[ -f "$CERT_SRC/ca.pem" ] || { echo "ERROR: missing $CERT_SRC/ca.pem — run ./gen-certs.sh first"; exit 1; }
install -d -m 750 -o root -g syslog /etc/rsyslog.d/tls
install -m 644 -o root -g syslog "$CERT_SRC/ca.pem" /etc/rsyslog.d/tls/ca.pem

echo "==> Obtaining Let's Encrypt cert for ${SINK_HOSTNAME}"
# This uses the HTTP-01 challenge (--standalone), which needs public port 80 and
# SINK_HOSTNAME resolving to this droplet. For a private/VPC sink with no inbound
# port 80, issue the cert out-of-band with DNS-01 first (see RUNBOOK "Alternative
# certificate issuance: DNS-01"); this block detects an existing cert and skips
# fresh issuance, so the rest of setup runs unchanged.
if [ -f "${LE_LIVE}/fullchain.pem" ]; then
  # Cert already present (prior run, or pre-issued via DNS-01). Use it as-is; renewal
  # is handled by the certbot timer + deploy hook using each cert's stored method.
  echo "  Certificate already exists for ${SINK_HOSTNAME} — using it"
else
  # Fresh HTTP-01 issuance: requires public port 80 and SINK_HOSTNAME resolving here.
  RESOLVED_IP="$(getent hosts "$SINK_HOSTNAME" | awk '{print $1}' | head -1)"
  MY_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if [ -z "$RESOLVED_IP" ]; then
    echo "ERROR: $SINK_HOSTNAME does not resolve. Point its DNS A record at this droplet, or pre-issue the cert via DNS-01 (see RUNBOOK)." >&2
    exit 1
  fi
  if [ -n "$MY_IP" ] && [ "$RESOLVED_IP" != "$MY_IP" ]; then
    echo "WARNING: $SINK_HOSTNAME resolves to $RESOLVED_IP but this droplet's public IP is $MY_IP; HTTP-01 will fail unless the name points here (or use DNS-01)." >&2
  fi
  # Allow port 80 in ufw if active (needed for the HTTP-01 standalone challenge)
  if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow 80/tcp comment 'certbot ACME challenge' || true
  fi
  certbot certonly --standalone --non-interactive --agree-tos \
    -m "$LETSENCRYPT_EMAIL" -d "$SINK_HOSTNAME"
fi

echo "==> Copying LE cert into rsyslog tls directory"
cp "${LE_LIVE}/fullchain.pem" /etc/rsyslog.d/tls/sink-server-cert.pem
cp "${LE_LIVE}/privkey.pem"   /etc/rsyslog.d/tls/sink-server-key.pem
chown root:syslog /etc/rsyslog.d/tls/sink-server-cert.pem /etc/rsyslog.d/tls/sink-server-key.pem
chmod 640 /etc/rsyslog.d/tls/sink-server-cert.pem /etc/rsyslog.d/tls/sink-server-key.pem

echo "==> Installing certbot deploy hook for auto-renewal"
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/rsyslog-sink.sh << HOOK
#!/bin/bash
set -e
LE_LIVE="/etc/letsencrypt/live/${SINK_HOSTNAME}"
cp "\${LE_LIVE}/fullchain.pem" /etc/rsyslog.d/tls/sink-server-cert.pem
cp "\${LE_LIVE}/privkey.pem"   /etc/rsyslog.d/tls/sink-server-key.pem
chown root:syslog /etc/rsyslog.d/tls/sink-server-cert.pem /etc/rsyslog.d/tls/sink-server-key.pem
chmod 640 /etc/rsyslog.d/tls/sink-server-cert.pem /etc/rsyslog.d/tls/sink-server-key.pem
systemctl restart rsyslog
HOOK
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/rsyslog-sink.sh

echo "==> Deploying DO Managed DB CA cert"
[ -f "$DO_CA_SRC" ] || { echo "ERROR: missing $DO_CA_SRC — download the CA cert from the DO DB control panel (Connection Details → Download CA certificate) and save it there"; exit 1; }
install -d -m 755 "$(dirname "$DO_CA_BUNDLE")"
install -m 644 "$DO_CA_SRC" "$DO_CA_BUNDLE"

echo "==> Configuring rsyslog (mutual TLS, port 6514)"
# Remove any plaintext imtcp listener a previous (pre-TLS) run appended to rsyslog.conf
if grep -qE '^input\(type="imtcp" port="514"\)' /etc/rsyslog.conf; then
  sed -i '/^module(load="imtcp")$/d; /^input(type="imtcp" port="514")$/d' /etc/rsyslog.conf
fi
cat > /etc/rsyslog.d/99-mysql-sink.conf <<'EOF'
# Mutual-TLS syslog receiver for DO Managed MySQL slow-query log forwarding.
#
# Server side: CertFile is the Let's Encrypt cert (publicly trusted). DO verifies
#   it against its own system CA bundle, so the DO "CA Certificate" field is left
#   BLANK. (A private-CA server cert is rejected by DO with certificate_unknown.)
# Client side: CAFile is our private CA. AuthMode x509/certvalid means only peers
#   presenting a cert signed by our CA are accepted — authenticates DO and blocks
#   log injection.
# Driver is ossl (OpenSSL); gtls failed the handshake with DO ("Decryption has failed").
global(
  defaultNetstreamDriver="ossl"
  defaultNetstreamDriverCAFile="/etc/rsyslog.d/tls/ca.pem"
  defaultNetstreamDriverCertFile="/etc/rsyslog.d/tls/sink-server-cert.pem"
  defaultNetstreamDriverKeyFile="/etc/rsyslog.d/tls/sink-server-key.pem"
)

module(load="imtcp"
  StreamDriver.Name="ossl"
  StreamDriver.Mode="1"
  StreamDriver.AuthMode="x509/certvalid")

input(type="imtcp" port="6514")

# Route TLS-received syslog input to the MySQL sink file
if $inputname == 'imtcp' then /var/log/mysql_sink/incoming/combined_mysql.log
& stop
EOF
systemctl restart rsyslog

# Defense-in-depth: allow syslog TLS port if ufw is active
# Port 80 is already opened above for certbot; 6514 for rsyslog.
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow 6514/tcp comment 'mysql-sink syslog mTLS' || true
fi

echo "==> Installing pmm-client (if not already installed)"
if ! command -v pmm-admin &>/dev/null; then
  wget -q "$PERCONA_RELEASE_URL" -O /tmp/percona-release.deb
  if [ -n "$PERCONA_RELEASE_SHA256" ]; then
    echo "$PERCONA_RELEASE_SHA256  /tmp/percona-release.deb" | sha256sum -c - \
      || { echo "ERROR: percona-release.deb checksum mismatch — aborting"; rm -f /tmp/percona-release.deb; exit 1; }
  else
    echo "  WARNING: PERCONA_RELEASE_SHA256 not set — installing unverified .deb. Pin it in .env for production."
  fi
  dpkg -i /tmp/percona-release.deb
  rm -f /tmp/percona-release.deb
  percona-release enable pmm3-client
  apt-get update -q
  apt-get install -y pmm-client
else
  echo "  pmm-client already installed: $(pmm-admin --version 2>&1 | head -1)"
fi

echo "==> Creating socat proxy systemd service"
cat > /etc/systemd/system/socat-mysql-proxy.service <<EOF
[Unit]
Description=TCP proxy – local 25060 -> DO Managed MySQL
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP4-LISTEN:25060,fork,reuseaddr,bind=127.0.0.1 TCP4:${DB_HOST}:${DB_PORT}
Restart=always
RestartSec=5

# Hardening — socat needs only outbound TCP, no filesystem or privileges
DynamicUser=true
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
RestrictAddressFamilies=AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now socat-mysql-proxy.service

echo "==> Removing legacy cron job (replaced by systemd service)"
( crontab -l 2>/dev/null | grep -v transform_logs ) | crontab - || true

echo "==> Installing slow-query-sink systemd service"
cp "$(dirname "$0")/slow-query-sink.service" /etc/systemd/system/slow-query-sink.service
systemctl daemon-reload
systemctl enable --now slow-query-sink.service

echo "==> Installing logrotate config"
cat > /etc/logrotate.d/mysql-sink <<EOF
$PROCESSED_DIR/native_slow_query.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 mysqlsink adm
    sharedscripts
}

$INCOMING_DIR/combined_mysql.log {
    daily
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    create 0640 syslog adm
    sharedscripts
    postrotate
        systemctl kill -s HUP rsyslog
    endscript
}
EOF

echo "==> Configuring PMM 3 client"
# NOTE: pmm-admin has no way to pass the service token outside the URL, so it is
# briefly visible in argv/ps during this one-shot config call (run as root).
# --server-insecure-tls is retained because the PMM server uses a self-signed,
# IP-addressed cert; pin the PMM CA here once the server has a verifiable cert.
pmm-admin config \
  --force \
  --server-insecure-tls \
  --server-url="https://service_token:${PMM_TOKEN}@${PMM_SERVER}:443"

# Allow pmm-agent to read the processed log (group adm, mode 640)
usermod -aG adm pmm-agent
chmod 640 "$PROCESSED_DIR/native_slow_query.log" 2>/dev/null || true
systemctl restart pmm-agent
sleep 3  # give agent time to connect before adding service

echo "==> Resolving slow_query_log_file path from DB (via socat proxy)"
# ssl-mode=VERIFY_CA validates the DB cert chain against DO's CA bundle; it does not
# check hostname, which is correct here since we connect through socat at 127.0.0.1.
# mysql_probe (common.sh) uses a 0600 temp options file — no password in argv/ps —
# and prints the real mysql error plus a troubleshooting checklist on failure
# instead of swallowing it with a blanket 2>/dev/null.
[ -f "$DO_CA_BUNDLE" ] || { echo "ERROR: DO_CA_BUNDLE ($DO_CA_BUNDLE) not found — download the CA cert from the DO DB control panel" >&2; exit 1; }

SLOW_LOG_RESULT=$(mysql_probe "$PMM_MONITOR_USER" "$DB_PASS" "127.0.0.1" "$DB_PORT" "$DO_CA_BUNDLE" "SHOW VARIABLES LIKE 'slow_query_log_file';") || exit 1
SLOW_LOG_PATH="$(printf '%s' "$SLOW_LOG_RESULT" | awk '{print $2}')"

if [ -z "$SLOW_LOG_PATH" ]; then
  echo "ERROR: DB probe succeeded but returned no slow_query_log_file value — unexpected response, investigate manually." >&2
  exit 1
fi
echo "  slow_query_log_file = $SLOW_LOG_PATH"

SLOW_LOG_DIR=$(dirname "$SLOW_LOG_PATH")
mkdir -p "$SLOW_LOG_DIR"
chmod 755 "$SLOW_LOG_DIR"
ln -sf "$PROCESSED_DIR/native_slow_query.log" "$SLOW_LOG_PATH"
echo "  Symlink: $SLOW_LOG_PATH -> $PROCESSED_DIR/native_slow_query.log"

echo "==> Registering MySQL service in PMM"
if pmm-admin list 2>/dev/null | grep -q 'do-managed-mysql'; then
  echo "  Service do-managed-mysql already registered, skipping."
else
  # Residual limitations (pmm-admin tooling, not config choices):
  #  - --password is the only way to supply credentials; briefly visible in argv.
  #  - --tls-skip-verify stays: the agent connects to 127.0.0.1 (socat) while the
  #    DB cert is issued for the DO hostname, so strict verification can't match.
  #    The DB hop is still TLS-encrypted end-to-end through the socat passthrough.
  pmm-admin add mysql \
    --username="$PMM_MONITOR_USER" \
    --password="$DB_PASS" \
    --host=127.0.0.1 \
    --port="$DB_PORT" \
    --query-source=slowlog \
    --tls \
    --tls-skip-verify \
    --skip-connection-check \
    do-managed-mysql
fi

echo "==> Verifying service registration"
if ! pmm-admin list 2>/dev/null | grep -q 'do-managed-mysql'; then
  echo "ERROR: 'do-managed-mysql' does not appear in 'pmm-admin list' after registration." >&2
  echo "Check: pmm-admin status ; journalctl -u pmm-agent -n 50" >&2
  exit 1
fi

echo ""
echo "==> Done. Run 'pmm-admin list' to verify agents are Running."
echo "    Watch incoming: watch -n2 'ls -lh $INCOMING_DIR'"
echo "    Watch processed: tail -f $PROCESSED_DIR/native_slow_query.log"
