#!/usr/bin/env bash
# destruct.sh — reverses everything setup.sh did, so a fresh `bash setup.sh`
# run starts from a clean slate. Run as root on the sink Droplet, from the
# same directory as setup.sh (needs .env present, though it degrades
# gracefully if some values are missing).
#
# Scope: only touches what setup.sh itself creates —
#   - PMM: this sink's service (PMM_SERVICE_NAME, default "do-managed-mysql")
#     and THIS node's registration/agents
#     (pmm-admin commands are scoped to the local agent's own node, so this
#     never touches other nodes/services in your PMM inventory)
#   - systemd: slow-query-sink.service, socat-mysql-proxy.service,
#     mysql-sink-reconcile.{service,timer}
#   - rsyslog: the mTLS listener config + its cert/key/CA copies
#   - the slow_query_log_file symlink on the DB side (best-effort, needs the
#     DB to still be reachable to resolve the path)
#   - /etc/mysql_sink, /var/log/mysql_sink, logrotate config, the mysqlsink
#     system user, the ufw rules setup.sh added
#
# It deliberately does NOT uninstall shared system packages (pmm-client,
# rsyslog-openssl, socat, certbot) — those aren't exclusively ours, and
# setup.sh already skips reinstalling them if present. It also leaves your
# Let's Encrypt certificate alone by default, since reissuing burns ACME
# rate-limit budget — pass --purge-letsencrypt if you really want it gone.
#
# Usage:
#   bash destruct.sh [--dry-run] [--yes] [--keep-logs] [--purge-letsencrypt]
set -uo pipefail   # no -e: a teardown script must keep going past individual
                    # failures ("already removed", etc.) and report everything
                    # it could/couldn't do at the end, not die on the first one.

SCRIPT_DIR_LOCAL="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR_LOCAL/common.sh"

load_config "$SCRIPT_DIR_LOCAL"   # .env + defaults (common.sh), incl. PMM_SERVICE_NAME, LOCAL_PROXY_PORT

SINK_HOSTNAME="${SINK_HOSTNAME:-}"
DO_CA_BUNDLE="${DO_CA_BUNDLE:-/etc/mysql_sink/do-ca.crt}"
PROCESSED_DIR="/var/log/mysql_sink/processed"

DRY_RUN=0
ASSUME_YES=0
KEEP_LOGS=0
PURGE_LETSENCRYPT=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --keep-logs) KEEP_LOGS=1 ;;
    --purge-letsencrypt) PURGE_LETSENCRYPT=1 ;;
    -h|--help)
      sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown flag: $arg (see --help)" >&2; exit 1 ;;
  esac
done

FAILURES=0
run() {
  # run "description" -- actual command...
  local desc="$1"; shift
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [dry-run] would: $desc"
    return 0
  fi
  echo "  -> $desc"
  local log; log="$(mktemp)"
  if ! "$@" >"$log" 2>&1; then
    echo "     WARNING: step failed (continuing): $desc"
    sed 's/^/       /' "$log"
    FAILURES=$((FAILURES + 1))
  fi
  rm -f "$log"
}

echo "This will remove everything setup.sh created for the '${PMM_SERVICE_NAME}'"
echo "integration on THIS droplet and its PMM node/service registration:"
echo "  - PMM: the '${PMM_SERVICE_NAME}' service + this node's registration/agents"
echo "  - systemd: slow-query-sink.service, socat-mysql-proxy.service, mysql-sink-reconcile.timer"
echo "  - rsyslog: the mTLS listener config + its cert/key/CA copies"
echo "  - the slow_query_log_file symlink on the DB side (if resolvable)"
echo "  - /etc/mysql_sink, logrotate config, the mysqlsink system user"
if [ "$KEEP_LOGS" -eq 0 ]; then
  echo "  - /var/log/mysql_sink (incoming + processed logs)"
else
  echo "  - (--keep-logs set: /var/log/mysql_sink will be left in place)"
fi
if [ "$PURGE_LETSENCRYPT" -eq 1 ]; then
  echo "  - the Let's Encrypt certificate for ${SINK_HOSTNAME:-<unset>} (uses ACME rate-limit budget to reissue)"
else
  echo "  - Let's Encrypt cert under /etc/letsencrypt is LEFT ALONE (pass --purge-letsencrypt to remove it too)"
fi
echo "  - NOT touched: pmm-client, rsyslog-openssl, socat, certbot packages themselves"
echo ""

if [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  read -r -p "Proceed? [y/N] " REPLY
  case "$REPLY" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi
echo ""

echo "==> 1/9 Removing PMM service registration"
if command -v pmm-admin >/dev/null 2>&1; then
  if pmm_service_exists "$PMM_SERVICE_NAME"; then
    run "remove ${PMM_SERVICE_NAME} service from PMM" pmm-admin remove mysql "$PMM_SERVICE_NAME"
  else
    echo "  no service named exactly '${PMM_SERVICE_NAME}' on this node — skipping."
  fi
else
  echo "  pmm-admin not installed — skipping PMM steps entirely."
fi

echo "==> 2/9 Unregistering this node from PMM"
if command -v pmm-admin >/dev/null 2>&1; then
  run "unregister node from PMM server" pmm-admin unregister --force
else
  echo "  pmm-admin not installed — skipping."
fi

echo "==> 3/9 Removing symlink at slow_query_log_file (best-effort DB lookup)"
# Stop the reconcile timer first, or it could re-create a symlink we just removed.
run "stop+disable mysql-sink-reconcile.timer" systemctl disable --now mysql-sink-reconcile.timer
SLOW_LOG_PATH=""
if [ -n "$DB_HOST" ] && [ -n "$DB_PASS" ] && [ -f "$DO_CA_BUNDLE" ]; then
  SLOW_LOG_RESULT="$(mysql_probe "$PMM_MONITOR_USER" "$DB_PASS" "127.0.0.1" "$LOCAL_PROXY_PORT" "$DO_CA_BUNDLE" "SHOW VARIABLES LIKE 'slow_query_log_file';" 2>/dev/null || true)"
  SLOW_LOG_PATH="$(printf '%s' "$SLOW_LOG_RESULT" | awk '{print $2}')"
fi
# Every path setup.sh / the reconcile timer ever symlinked (it changes across
# DB failovers), plus the current one and PMM's rotation leftover (<path>.old).
LINKS=()
if [ -f /var/lib/mysql_sink/symlinks.list ]; then
  while read -r l; do [ -n "$l" ] && LINKS+=("$l" "${l}.old"); done < /var/lib/mysql_sink/symlinks.list
fi
[ -n "$SLOW_LOG_PATH" ] && LINKS+=("$SLOW_LOG_PATH" "${SLOW_LOG_PATH}.old")
# Plus any other symlink to OUR processed log in those same directories — e.g.
# one for a pre-failover node created before the record above existed. Only
# links that resolve to our own file are ever removed (checked below).
if [ "${#LINKS[@]}" -gt 0 ]; then
  while read -r d; do
    [ -d "$d" ] || continue
    while read -r l; do LINKS+=("$l"); done < <(find "$d" -maxdepth 1 -type l 2>/dev/null)
  done < <(for l in "${LINKS[@]}"; do dirname "$l"; done | sort -u)
fi
if [ "${#LINKS[@]}" -gt 0 ]; then
  while read -r link; do
    [ -L "$link" ] || continue
    LINK_TARGET="$(readlink -f "$link" 2>/dev/null || true)"
    if [ "$LINK_TARGET" = "$PROCESSED_DIR/native_slow_query.log" ]; then
      run "remove symlink $link" rm -f "$link"
    else
      echo "  WARNING: $link doesn't point at our processed log ($LINK_TARGET) — leaving it alone."
    fi
  done < <(printf '%s\n' "${LINKS[@]}" | sort -u)
else
  echo "  Could not resolve slow_query_log_file via DB (proxy/DB may already be down) — skipping."
  echo "  If you know the path, remove it manually: rm -f <slow_query_log_file>"
fi

echo "==> 4/9 Stopping and removing systemd services"
run "remove mysql-sink-reconcile unit files" rm -f /etc/systemd/system/mysql-sink-reconcile.timer /etc/systemd/system/mysql-sink-reconcile.service
run "stop+disable slow-query-sink.service" systemctl disable --now slow-query-sink.service
run "remove slow-query-sink.service unit file" rm -f /etc/systemd/system/slow-query-sink.service
run "stop+disable socat-mysql-proxy.service" systemctl disable --now socat-mysql-proxy.service
run "remove socat-mysql-proxy.service unit file" rm -f /etc/systemd/system/socat-mysql-proxy.service
run "reload systemd" systemctl daemon-reload

echo "==> 5/9 Removing rsyslog mTLS config"
run "remove rsyslog mysql-sink config" rm -f /etc/rsyslog.d/99-mysql-sink.conf
run "remove rsyslog TLS cert/key/CA copies" rm -rf /etc/rsyslog.d/tls
run "restart rsyslog" systemctl restart rsyslog

echo "==> 6/9 Removing certbot renewal hook"
run "remove renewal deploy hook" rm -f /etc/letsencrypt/renewal-hooks/deploy/rsyslog-sink.sh
if [ "$PURGE_LETSENCRYPT" -eq 1 ]; then
  if [ -n "$SINK_HOSTNAME" ]; then
    run "delete Let's Encrypt cert for $SINK_HOSTNAME" certbot delete --cert-name "$SINK_HOSTNAME" --non-interactive
  else
    echo "  --purge-letsencrypt set but SINK_HOSTNAME is unset — skipping (delete manually with 'certbot delete')."
  fi
fi

echo "==> 7/9 Removing DO CA bundle and mysql_sink directories"
run "remove DO CA bundle" rm -f "$DO_CA_BUNDLE"
run "remove reconcile DB options file" rm -f /etc/mysql_sink/reconcile.cnf
run "remove /var/lib/mysql_sink (symlink record)" rm -rf /var/lib/mysql_sink
run "remove /etc/mysql_sink (if now empty)" rmdir --ignore-fail-on-non-empty "$(dirname "$DO_CA_BUNDLE")"
if [ "$KEEP_LOGS" -eq 1 ]; then
  echo "  --keep-logs set — leaving /var/log/mysql_sink in place."
else
  run "remove /var/log/mysql_sink" rm -rf /var/log/mysql_sink
fi
run "remove logrotate config" rm -f /etc/logrotate.d/mysql-sink

echo "==> 8/9 Removing service user"
run "delete mysqlsink user" userdel mysqlsink

echo "==> 9/9 Removing firewall rules (if ufw active)"
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  run "remove ufw rule for 6514/tcp" ufw delete allow 6514/tcp
  run "remove ufw rule for 80/tcp (certbot)" ufw delete allow 80/tcp
else
  echo "  ufw not active — skipping."
fi

echo ""
if [ "$DRY_RUN" -eq 1 ]; then
  echo "==> Dry run complete — nothing was actually changed."
elif [ "$FAILURES" -eq 0 ]; then
  echo "==> Done. A fresh 'bash setup.sh' run should now start clean."
else
  echo "==> Done, but $FAILURES step(s) reported warnings above — review before re-running setup.sh."
fi
echo "    NOT removed (shared system packages): pmm-client, rsyslog-openssl, socat, certbot"
if [ "$PURGE_LETSENCRYPT" -eq 0 ]; then
  echo "    NOT removed: Let's Encrypt certificate under /etc/letsencrypt (pass --purge-letsencrypt to remove)"
fi
