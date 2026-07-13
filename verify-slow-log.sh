#!/usr/bin/env bash
# verify-slow-log.sh — RUNBOOK Step 5 verification, automated.
#
# Replaces the manual printf/mysql/ls one-liner: builds the DB options file
# from .env automatically (no more copy-pasting <DB_PASS> by hand), runs the
# slow_query_log_file lookup with real error output (see common.sh), and
# checks that the resulting path is a symlink pointing at our processed log.
#
# Run on the sink Droplet, from this repo's directory (needs .env present).
#
# Usage:
#   bash verify-slow-log.sh            # query through the socat proxy (127.0.0.1)
#                                       # — this is exactly what pmm-agent uses
#   bash verify-slow-log.sh --direct   # query the DB directly, bypassing socat
#                                       # — use this to isolate "is it the proxy
#                                       # or the DB/firewall?" when the proxy
#                                       # query fails
set -euo pipefail

SCRIPT_DIR_LOCAL="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR_LOCAL/common.sh"

if [ -f "$SCRIPT_DIR_LOCAL/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR_LOCAL/.env"
  set +a
fi

DB_PORT="${DB_PORT:-25060}"
PMM_MONITOR_USER="${PMM_MONITOR_USER:-pmm_monitor}"
DB_PASS="${DB_PASS:?Set DB_PASS in .env}"
DO_CA_BUNDLE="${DO_CA_BUNDLE:-/etc/mysql_sink/do-ca.crt}"
PROCESSED_DIR="/var/log/mysql_sink/processed"
INCOMING_FILE="/var/log/mysql_sink/incoming/combined_mysql.log"
PROCESSED_FILE="$PROCESSED_DIR/native_slow_query.log"

MODE="proxy"
if [ "${1:-}" = "--direct" ]; then
  MODE="direct"
fi

if [ "$MODE" = "direct" ]; then
  : "${DB_HOST:?Set DB_HOST in .env}"
  DO_CA_SRC="${DO_CA_SRC:-$SCRIPT_DIR_LOCAL/certs/do-ca.crt}"
  [ -f "$DO_CA_SRC" ] || { echo "ERROR: $DO_CA_SRC not found — download the CA cert from the DO control panel." >&2; exit 1; }
  echo "==> Querying DB directly at ${DB_HOST}:${DB_PORT} (bypassing socat proxy)"
  RESULT=$(mysql_probe "$PMM_MONITOR_USER" "$DB_PASS" "$DB_HOST" "$DB_PORT" "$DO_CA_SRC" "SHOW VARIABLES LIKE 'slow_query_log_file';")
else
  [ -f "$DO_CA_BUNDLE" ] || { echo "ERROR: $DO_CA_BUNDLE not found on this droplet — run setup.sh first, or pass --direct to test the DB directly instead of through the proxy." >&2; exit 1; }
  echo "==> Querying DB through the socat proxy at 127.0.0.1:${DB_PORT}"
  RESULT=$(mysql_probe "$PMM_MONITOR_USER" "$DB_PASS" "127.0.0.1" "$DB_PORT" "$DO_CA_BUNDLE" "SHOW VARIABLES LIKE 'slow_query_log_file';")
fi

SLOW_LOG_PATH="$(printf '%s' "$RESULT" | awk '{print $2}')"
if [ -z "$SLOW_LOG_PATH" ]; then
  echo "ERROR: query succeeded but returned no path — unexpected DB response." >&2
  exit 1
fi
echo "  slow_query_log_file = $SLOW_LOG_PATH"

echo ""
echo "==> Checking the symlink"
if ! ls -la "$SLOW_LOG_PATH" 2>/dev/null; then
  echo "ERROR: $SLOW_LOG_PATH does not exist on this filesystem." >&2
  exit 1
fi

TARGET="$(readlink -f "$SLOW_LOG_PATH" 2>/dev/null || true)"
if [ "$TARGET" != "$PROCESSED_FILE" ]; then
  echo "  WARNING: symlink resolves to '$TARGET', expected '$PROCESSED_FILE'." >&2
  exit 1
fi
echo "  Symlink path is correct: $SLOW_LOG_PATH -> $PROCESSED_FILE"

# The check above only confirms the symlink POINTS at the right path — both
# `ls -la` on a symlink and `readlink -f` succeed even when the target file
# doesn't exist (a dangling symlink), so a correct-looking symlink here does
# NOT by itself mean the pipeline has ever produced data. Check the target
# file actually exists before calling this a real end-to-end OK.
echo ""
echo "==> Checking the target file actually exists (not just the symlink path)"
if [ ! -e "$PROCESSED_FILE" ]; then
  echo "  WARNING: $PROCESSED_FILE does not exist yet." >&2
  echo "  The symlink is configured correctly, but nothing has flowed through the" >&2
  echo "  pipeline — transform_logs.py doesn't create this file until AFTER it" >&2
  echo "  successfully opens $INCOMING_FILE for the first time, which rsyslog" >&2
  echo "  in turn only writes once it receives at least one forwarded syslog line" >&2
  echo "  from DO. (slow-query-sink.service will still show 'active (running)' the" >&2
  echo "  whole time it's parked waiting — that's normal, not a crash.)" >&2
  echo "" >&2
  if [ -e "$INCOMING_FILE" ]; then
    echo "  $INCOMING_FILE exists — check whether it's actually growing (data IS" >&2
    echo "  arriving but the daemon or PMM side may be the problem)." >&2
  else
    echo "  $INCOMING_FILE also does not exist — no data has ever arrived from DO." >&2
    echo "  Check, in order: systemctl status rsyslog ; ss -tlnp | grep 6514 ;" >&2
    echo "  journalctl -u rsyslog -n 100 (TLS handshake errors, or no connection" >&2
    echo "  attempts at all); DO's Log Forwarding destination — confirm 'Show" >&2
    echo "  advanced configuration options' was expanded and Client key/Client" >&2
    echo "  certificate are actually filled in, not left blank; and log_output=" >&2
    echo "  INSIGHTS on the DB (SELECT @@log_output; should show FILE, not TABLE)." >&2
  fi
  exit 1
fi
echo "  OK: $PROCESSED_FILE exists — $(wc -l < "$PROCESSED_FILE") line(s), last modified $(date -r "$PROCESSED_FILE")"
