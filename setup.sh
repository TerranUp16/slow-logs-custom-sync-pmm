#!/usr/bin/env bash
# Deploys and configures the MySQL slow log sink + PMM 3 integration on the sink Droplet.
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

# .env holds DB_PASS and PMM_TOKEN — keep it owner-only regardless of how it
# was created (an editor or `cat >` leaves it at the umask default, 0644).
[ -f "$SCRIPT_DIR_LOCAL/.env" ] && chmod 600 "$SCRIPT_DIR_LOCAL/.env"
# Sources .env and applies defaults for every optional key (common.sh).
load_config "$SCRIPT_DIR_LOCAL"

DB_HOST="${DB_HOST:?Set DB_HOST in .env}"
DB_PASS="${DB_PASS:?Set DB_PASS in .env}"
PMM_SERVER="${PMM_SERVER:?Set PMM_SERVER in .env}"
PMM_SERVER_HOST="${PMM_SERVER%%:*}"   # PMM_SERVER is documented as a bare host/IP; tolerate host:port
PMM_TOKEN="${PMM_TOKEN:-}"
validate_config || { echo "Fix the value(s) above in .env and re-run. Nothing has been changed." >&2; exit 1; }
if [ "$PMM_SERVICE_NAME_DEFAULTED" -eq 1 ]; then
  echo "NOTE: PMM_SERVICE_NAME not set — using the default 'do-managed-mysql'. Set a unique name per endpoint if more than one sink reports to this PMM Server."
fi
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
# Supported: Ubuntu 22.04, 24.04 and 26.04 LTS — the releases Percona's
# pmm3-client apt repo publishes pmm-client for (jammy/noble/resolute), and that
# this pipeline has been validated on. Anything else needs pmm-client installed
# some unsupported way (e.g. pointing apt at another release's repo), which can
# break silently on any Percona-side update. This is a warning, not a hard
# stop, so existing test boxes aren't locked out — but don't deploy a real
# integration this way.
if [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${VERSION_ID:-}" in
    22.04|24.04|26.04) : ;;
    *)
      echo "" >&2
      echo "WARNING: this is Ubuntu ${VERSION_ID:-<unknown>}, not 22.04, 24.04 or 26.04 LTS." >&2
      echo "Percona does not publish pmm-client packages for this version. See the" >&2
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
on the default admin/admin password), this script will mint a token
automatically. Otherwise create one by hand (RUNBOOK Step 1): log into
https://${PMM_SERVER}, go to Administration -> Users and access -> Service
Accounts -> Add service account (role: Admin), add a token to it, and put
the token (glsa_...) into .env as PMM_TOKEN.
INSTR
    exit 1
  fi

  # One service account per sink, named after the node, so each sink's token
  # can be found and revoked on its own (Administration -> Service Accounts).
  SA_NAME="sink-${PMM_NODE_NAME}"
  echo "==> PMM server reachable — attempting to mint a token for service account '${SA_NAME}' (default admin/admin)"
  # PMM 3 ships Grafana 9+, which replaced the legacy /api/auth/keys endpoint with
  # Service Accounts: create (or reuse) a service account, then mint a token.
  if ! PMM_TOKEN="$(pmm_mint_token "$SA_NAME")" || [ -z "$PMM_TOKEN" ]; then
    cat >&2 <<INSTR
ERROR: Could not auto-mint a PMM token — the default admin/admin credentials
were rejected (the admin password has likely already been changed via the
PMM UI), or the PMM API returned an unexpected response (see above).

Create one by hand (RUNBOOK Step 1): log into https://${PMM_SERVER}, go to
Administration -> Users and access -> Service Accounts -> Add service account
(name it ${SA_NAME}, role: Admin), add a token to it, put the token (glsa_...)
into .env as PMM_TOKEN, and re-run this script. Use one service account and
token per sink, so each can be revoked independently.
INSTR
    exit 1
  fi

  echo "==> Minted a token for service account '${SA_NAME}' — writing PMM_TOKEN into .env"
  # awk reads the token from its environment, not its argv (a sed expression
  # would put the token in `ps` output), and the rewrite goes through a 0600
  # mktemp file so .env is never briefly world-readable or half-written.
  ENV_FILE="$SCRIPT_DIR_LOCAL/.env"
  touch "$ENV_FILE" && chmod 600 "$ENV_FILE"
  ENV_TMP="$(mktemp "${ENV_FILE}.XXXXXX")"
  PMM_TOKEN="$PMM_TOKEN" awk '
    BEGIN { t = ENVIRON["PMM_TOKEN"] }
    /^PMM_TOKEN=/ { print "PMM_TOKEN=" t; done = 1; next }
    { print }
    END { if (!done) print "PMM_TOKEN=" t }
  ' "$ENV_FILE" > "$ENV_TMP"
  mv "$ENV_TMP" "$ENV_FILE"
fi

echo "==> Preflight: PMM identity (node '${PMM_NODE_NAME}', service '${PMM_SERVICE_NAME}')"
# `pmm-admin config --force` removes any existing node WITH THIS NAME — and all
# its services and agents — so before registering, make sure a node by that
# name isn't some other machine's (e.g. a second sink with the same hostname),
# and that the service name isn't already taken by another node. Both are
# read-only API lookups; nothing has been changed on the PMM Server yet.
read -r LOCAL_AGENT_ID LOCAL_NODE_ID LOCAL_NODE_NAME LOCAL_SERVER LOCAL_CONNECTED < <(pmm_local_status)
# pmm-admin can't report the agent ID while pmm-agent is stopped; its config
# file still has it, and that's what the ownership check needs.
if [ "$LOCAL_AGENT_ID" = "-" ] && [ -f /usr/local/percona/pmm/config/pmm-agent.yaml ]; then
  LOCAL_AGENT_ID="$(awk '$1 == "id:" { print $2; exit }' /usr/local/percona/pmm/config/pmm-agent.yaml)"
  LOCAL_AGENT_ID="${LOCAL_AGENT_ID:--}"
fi
SKIP_PMM_CONFIG=0
if [ "$LOCAL_CONNECTED" = "true" ] && [ "$LOCAL_SERVER" = "$PMM_SERVER_HOST" ] \
   && [ "$LOCAL_NODE_NAME" = "$PMM_NODE_NAME" ] && [ "$PMM_FORCE_REREGISTER" != "1" ]; then
  # Re-run on an already-registered sink: keep the node (and its IDs) as is.
  SKIP_PMM_CONFIG=1
  echo "  This machine is already registered and connected as node '${PMM_NODE_NAME}' — keeping that registration."
else
  # `|| RC=$?` (not set +e) so the ERR trap doesn't report these expected
  # non-zero verdicts as a crash.
  OWNER_RC=0; OWNER_DETAILS="$(pmm_node_owner "$PMM_NODE_NAME" "${LOCAL_AGENT_ID#-}")" || OWNER_RC=$?
  case "$OWNER_RC" in
    0) echo "  No node named '${PMM_NODE_NAME}' on the PMM Server yet." ;;
    1) echo "  Node '${PMM_NODE_NAME}' exists and belongs to this machine — re-registering it." ;;
    2)
      if [ "$PMM_FORCE_REREGISTER" = "1" ]; then
        echo "WARNING: node '${PMM_NODE_NAME}' belongs to a different pmm-agent (${OWNER_DETAILS});" >&2
        echo "  PMM_FORCE_REREGISTER=1, so it will be REPLACED — with all its services and agents." >&2
      else
        cat >&2 <<MSG
ERROR: a PMM node named '${PMM_NODE_NAME}' already exists and is NOT this machine's:
  ${OWNER_DETAILS}
Registering would remove it, with all of its services and agents (pmm-admin
config --force). Usually this means another sink has the same hostname.
  - Give this sink its own name: set PMM_NODE_NAME=<unique name> in .env, or
  - if that node really is stale (e.g. its Droplet was deleted), re-run with
    PMM_FORCE_REREGISTER=1 to replace it.
Nothing has been changed on this Droplet or the PMM Server.
MSG
        exit 1
      fi
      ;;
    *)
      if [ "$PMM_FORCE_REREGISTER" = "1" ]; then
        echo "WARNING: couldn't verify who owns node '${PMM_NODE_NAME}' (see above); continuing because PMM_FORCE_REREGISTER=1." >&2
      else
        echo "ERROR: couldn't verify whether node '${PMM_NODE_NAME}' belongs to another machine (see above)," >&2
        echo "  so registering could silently remove it. Fix PMM_SERVER/PMM_TOKEN, or re-run with" >&2
        echo "  PMM_FORCE_REREGISTER=1 if you're sure. Nothing has been changed." >&2
        exit 1
      fi
      ;;
  esac
fi
if [ "$PMM_FORCE_REREGISTER" != "1" ]; then
  # The local node ID only counts if it's on this same PMM Server.
  [ "$LOCAL_SERVER" = "$PMM_SERVER_HOST" ] || LOCAL_NODE_ID="-"
  SVC_RC=0; SVC_DETAILS="$(pmm_service_owner "$PMM_SERVICE_NAME" "${LOCAL_NODE_ID#-}")" || SVC_RC=$?
  if [ "$SVC_RC" -eq 2 ]; then
    cat >&2 <<MSG
ERROR: PMM service name '${PMM_SERVICE_NAME}' is already used by another node:
  ${SVC_DETAILS}
PMM service names must be unique per PMM Server. Set PMM_SERVICE_NAME=<unique
name> in .env for this endpoint (RUNBOOK: "Monitoring multiple Managed MySQL
endpoints with one PMM Server"). Nothing has been changed.
MSG
    exit 1
  elif [ "$SVC_RC" -eq 3 ]; then
    echo "WARNING: couldn't check whether service name '${PMM_SERVICE_NAME}' is free (see above); continuing." >&2
  fi
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
chmod 750 /var/log/mysql_sink "$INCOMING_DIR"
# setgid on processed/ so a native_slow_query.log the daemon (re)creates itself
# — e.g. after a rotation, see transform_logs.py — inherits group adm, matching
# what logrotate's `create 0640 mysqlsink adm` produces. The daemon's
# UMask=0027 (slow-query-sink.service) supplies the 0640.
chmod 2750 "$PROCESSED_DIR"
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
# default-mysql-client is listed here too even though the DB preflight above
# already triggered ensure_mysql_client() in common.sh on a box that didn't have
# it yet — this line is then just a fast no-op, kept for a complete/accurate
# install list.
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

# Route TLS-received syslog input to the MySQL sink file.
# The file template is pinned (rather than inheriting the distro's omfile
# default) because transform_logs.py parses each line's source host out of it;
# owner/group/mode match Ubuntu's rsyslog.conf defaults ($FileOwner etc.) so
# pmm-agent and the daemon keep reading it via group adm.
if $inputname == 'imtcp' then {
  action(type="omfile" file="/var/log/mysql_sink/incoming/combined_mysql.log"
         template="RSYSLOG_FileFormat"
         fileOwner="syslog" fileGroup="adm" fileCreateMode="0640")
  stop
}
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

echo "==> Creating socat proxy systemd service (127.0.0.1:${LOCAL_PROXY_PORT} -> ${DB_HOST}:${DB_PORT})"
# LOCAL_PROXY_PORT (default: DB_PORT) is the local side every consumer uses —
# pmm-agent, mysql_probe, verify/diagnose, test_prepared_statements.py.
cat > /etc/systemd/system/socat-mysql-proxy.service <<EOF
[Unit]
Description=TCP proxy – local ${LOCAL_PROXY_PORT} -> DO Managed MySQL
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP4-LISTEN:${LOCAL_PROXY_PORT},fork,reuseaddr,bind=127.0.0.1 TCP4:${DB_HOST}:${DB_PORT}
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
# restart, not just `enable --now`: on a re-run (e.g. new DB_HOST after a DB
# replacement) the proxy is already running and `--now` would leave it pointed
# at the old target.
systemctl enable socat-mysql-proxy.service
systemctl restart socat-mysql-proxy.service

echo "==> Removing legacy cron job (replaced by systemd service)"
( crontab -l 2>/dev/null | grep -v transform_logs ) | crontab - || true

echo "==> Installing slow-query-sink systemd service"
cp "$(dirname "$0")/slow-query-sink.service" /etc/systemd/system/slow-query-sink.service
systemctl daemon-reload
# restart, not just `enable --now`: after `git pull && bash setup.sh` the daemon
# is already running the OLD transform_logs.py, and `--now` wouldn't pick up
# the new code or unit until the next reboot.
systemctl enable slow-query-sink.service
systemctl restart slow-query-sink.service

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

echo "==> Configuring PMM 3 client (node '${PMM_NODE_NAME}')"
if [ "$SKIP_PMM_CONFIG" -eq 1 ]; then
  # Already registered and connected as this node (preflight above). Re-running
  # `pmm-admin config --force` here would delete and recreate the node and every
  # service on it, changing their IDs on every setup.sh run. Set
  # PMM_FORCE_REREGISTER=1 to re-register anyway (e.g. after rotating PMM_TOKEN
  # while the old token still works).
  echo "  Already registered and connected — leaving the node registration as is."
else
  if [ "$LOCAL_CONNECTED" = "true" ] && [ "$LOCAL_SERVER" = "$PMM_SERVER_HOST" ] \
     && [ "$LOCAL_NODE_NAME" != "-" ] && [ "$LOCAL_NODE_NAME" != "$PMM_NODE_NAME" ]; then
    # PMM_NODE_NAME changed: retire this machine's own old node (and its
    # services) first, rather than leaving it orphaned on the PMM Server.
    echo "  Node name changed ('${LOCAL_NODE_NAME}' -> '${PMM_NODE_NAME}') — unregistering this machine's old node first."
    pmm-admin unregister --force
  fi
  # pmm-admin takes the node name only as the 3rd positional argument, after
  # address and type, so they're passed only when PMM_NODE_NAME is explicitly
  # set. Unset, the call is exactly what it always was and pmm-admin
  # autodetects all three (node name = `hostname`).
  NODE_ARGS=()
  if [ "$PMM_NODE_NAME_SET" -eq 1 ]; then
    NODE_ADDRESS="${SINK_IP:-$(hostname -I | awk '{print $1}')}"
    NODE_ARGS=("$NODE_ADDRESS" generic "$PMM_NODE_NAME")
  fi
  # NOTE: pmm-admin has no way to pass the service token outside the URL, so it is
  # briefly visible in argv/ps during this one-shot config call (run as root).
  # --server-insecure-tls is retained because the PMM server uses a self-signed,
  # IP-addressed cert; pin the PMM CA here once the server has a verifiable cert.
  # --force replaces an existing node with this name — the preflight above has
  # already established that it's this machine's own (or PMM_FORCE_REREGISTER=1).
  pmm-admin config \
    --force \
    --server-insecure-tls \
    --server-url="https://service_token:${PMM_TOKEN}@${PMM_SERVER}:443" \
    "${NODE_ARGS[@]}"
fi

# Allow pmm-agent to read the processed log (group adm, mode 640). The file may
# not exist yet (the daemon creates it on first data); if it does, normalize it
# to what a freshly created/rotated one gets.
usermod -aG adm pmm-agent
if [ -f "$PROCESSED_DIR/native_slow_query.log" ]; then
  chown mysqlsink:adm "$PROCESSED_DIR/native_slow_query.log"
  chmod 640 "$PROCESSED_DIR/native_slow_query.log"
fi
systemctl restart pmm-agent
sleep 3  # give agent time to connect before adding service

echo "==> Resolving slow_query_log_file path from DB (via socat proxy)"
# ssl-mode=VERIFY_CA validates the DB cert chain against DO's CA bundle; it does not
# check hostname, which is correct here since we connect through socat at 127.0.0.1.
# mysql_probe (common.sh) uses a 0600 temp options file — no password in argv/ps —
# and prints the real mysql error plus a troubleshooting checklist on failure
# instead of swallowing it with a blanket 2>/dev/null.
[ -f "$DO_CA_BUNDLE" ] || { echo "ERROR: DO_CA_BUNDLE ($DO_CA_BUNDLE) not found — download the CA cert from the DO DB control panel" >&2; exit 1; }

SLOW_LOG_RESULT=$(mysql_probe "$PMM_MONITOR_USER" "$DB_PASS" "127.0.0.1" "$LOCAL_PROXY_PORT" "$DO_CA_BUNDLE" "SHOW VARIABLES LIKE 'slow_query_log_file';") || exit 1
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
# Leftover from PMM's own slow-log rotation (disabled below): it renames
# slow_query_log_file to <path>.old — i.e. renames our symlink away. Remove it
# only if it's ours.
if [ -L "${SLOW_LOG_PATH}.old" ] && [ "$(readlink -f "${SLOW_LOG_PATH}.old")" = "$PROCESSED_DIR/native_slow_query.log" ]; then
  rm -f "${SLOW_LOG_PATH}.old"
  echo "  Removed stale ${SLOW_LOG_PATH}.old (left by a PMM-side rotation)"
fi

echo "==> Registering MySQL service '${PMM_SERVICE_NAME}' in PMM"
# PMM_SERVICE_NAME changed since the last run? Then this sink's service is
# still registered under the old name on the same local proxy port — remove it
# rather than leave a dead duplicate of this endpoint in PMM.
while read -r OLD_SVC; do
  [ -n "$OLD_SVC" ] || continue
  echo "  Removing this sink's previous service '${OLD_SVC}' (same 127.0.0.1:${LOCAL_PROXY_PORT}; PMM_SERVICE_NAME is now '${PMM_SERVICE_NAME}')."
  pmm-admin remove mysql "$OLD_SVC"
done < <(pmm_stale_services "$PMM_SERVICE_NAME" "$LOCAL_PROXY_PORT")
if pmm_service_exists "$PMM_SERVICE_NAME"; then
  # Re-register rather than skip, so a re-run applies the current .env —
  # a new DB_PASS after a DB replacement, a changed LOCAL_PROXY_PORT or labels.
  # (pmm-admin can't change most of these on an existing service, and the old
  # password can't be read back to compare.) QAN history is kept: it's
  # filtered by service name, which doesn't change.
  echo "  Service '${PMM_SERVICE_NAME}' already registered on this node — re-registering it with the current .env."
  pmm-admin remove mysql "$PMM_SERVICE_NAME"
fi
# Optional grouping labels, passed only when set (for comparing endpoints, e.g.
# primary vs replica, or old vs new clusters, in one PMM).
LABEL_ARGS=()
[ -n "$PMM_ENVIRONMENT" ]     && LABEL_ARGS+=(--environment="$PMM_ENVIRONMENT")
[ -n "$PMM_CLUSTER" ]         && LABEL_ARGS+=(--cluster="$PMM_CLUSTER")
[ -n "$PMM_REPLICATION_SET" ] && LABEL_ARGS+=(--replication-set="$PMM_REPLICATION_SET")
[ -n "$PMM_CUSTOM_LABELS" ]   && LABEL_ARGS+=(--custom-labels="$PMM_CUSTOM_LABELS")
# Residual limitations (pmm-admin tooling, not config choices):
#  - --password is the only way to supply credentials; briefly visible in argv.
#  - --tls-skip-verify stays: the agent connects to 127.0.0.1 (socat) while the
#    DB cert is issued for the DO hostname, so strict verification can't match.
#    The DB hop is still TLS-encrypted end-to-end through the socat passthrough.
# PMM's own slow-log rotation is disabled in the next step rather than with
# --size-slow-logs here: pmm-admin 3.10 rejects the documented "-1" ("unknown
# unit") and only takes "-1B", and the next step has to exist anyway to fix
# services registered by older versions of this script.
pmm-admin add mysql \
  --username="$PMM_MONITOR_USER" \
  --password="$DB_PASS" \
  --host=127.0.0.1 \
  --port="$LOCAL_PROXY_PORT" \
  --query-source=slowlog \
  --tls \
  --tls-skip-verify \
  --skip-connection-check \
  "${LABEL_ARGS[@]}" \
  "$PMM_SERVICE_NAME"

echo "==> Verifying service registration"
if ! pmm_service_exists "$PMM_SERVICE_NAME"; then
  echo "ERROR: '${PMM_SERVICE_NAME}' does not appear in 'pmm-admin list' after registration." >&2
  echo "Check: pmm-admin status ; journalctl -u pmm-agent -n 50" >&2
  exit 1
fi

echo "==> Disabling PMM's built-in slow-log rotation (logrotate owns rotation here)"
# PMM's slowlog agent rotates by renaming slow_query_log_file to <path>.old and
# running FLUSH SLOW LOGS on the DB, expecting mysqld to recreate the file. Here
# that path is our symlink and mysqld is remote, so the symlink is renamed away,
# nothing recreates it, and QAN goes silent (pmm-agent logs "Failed to stat" in
# a loop while `pmm-admin list` still says Running). It triggers once the
# processed log passes the limit (PMM default 1 GiB) and the monitor user has
# RELOAD, which DO's default users do.
# Applies to a service registered just now and, in place, to one registered by
# an older version of this script (which got PMM's 1 GiB default). Idempotent:
# PMM stores 0 as "no limit" and the agent skips rotation for sizes <= 0.
SLOWLOG_AGENT_ID="$(pmm_slowlog_agent_id "$PMM_SERVICE_NAME")"
if [ -z "$SLOWLOG_AGENT_ID" ]; then
  echo "ERROR: no QAN slowlog agent found for service '${PMM_SERVICE_NAME}' in 'pmm-admin --json list'." >&2
  echo "Check: pmm-admin list ; journalctl -u pmm-agent -n 50" >&2
  exit 1
fi
pmm-admin inventory change agent qan-mysql-slowlog-agent "$SLOWLOG_AGENT_ID" --max-slowlog-file-size=0 >/dev/null
echo "  slowlog agent $SLOWLOG_AGENT_ID: max slowlog file size = 0 (no PMM-side rotation)"

echo ""
echo "==> Done. Run 'pmm-admin list' to verify agents are Running."
echo "    Watch incoming: watch -n2 'ls -lh $INCOMING_DIR'"
echo "    Watch processed: tail -f $PROCESSED_DIR/native_slow_query.log"
echo ""
echo "    This script cannot confirm data is actually flowing end-to-end: DO's log"
echo "    forwarder takes ~1-2 minutes to redeploy after Step 4's config is saved,"
echo "    and generating a real slow-query workload against your DB isn't this"
echo "    script's job. Once you've waited a bit and/or run a test workload"
echo "    (test_prepared_statements.py), run 'bash diagnose.sh' — it checks every"
echo "    stage of the pipeline end to end and points at exactly where it's stuck"
echo "    if something isn't working."
