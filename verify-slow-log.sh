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
if [ "$TARGET" = "$PROCESSED_DIR/native_slow_query.log" ]; then
  echo "  OK: symlink correctly points at $PROCESSED_DIR/native_slow_query.log"
else
  echo "  WARNING: symlink resolves to '$TARGET', expected '$PROCESSED_DIR/native_slow_query.log'." >&2
  exit 1
fi
