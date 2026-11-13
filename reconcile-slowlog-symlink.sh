#!/usr/bin/env bash
# reconcile-slowlog-symlink.sh — keep the slow_query_log_file symlink pointing at
# the reconstructed log after the DB's reported path changes.
#
# Why: on DO Managed MySQL the reported path embeds the serving node's hostname
# (/var/lib/mysql/8/data/<cluster>-<n>-slow.log), and a primary failover (or a
# resize, which replaces nodes) changes it. mysql_slowlog_agent re-reads
# @@slow_query_log_file and opens the NEW path on this sink; without a symlink
# there, QAN stops until someone re-runs setup.sh. setup.sh installs this script
# plus mysql-sink-reconcile.timer (every minute) to close that gap.
#
# Read-only towards the DB (one SELECT). Idempotent: does nothing unless the
# current path lacks our symlink. Never replaces anything at that path that
# isn't already a symlink to our processed log, and never deletes the old
# symlink (the old node may become primary again; a dangling-free symlink to
# our own log is harmless). Every path it creates is recorded so destruct.sh
# can remove exactly those.
#
# Installed by setup.sh to /var/log/mysql_sink/bin/; reads
# /etc/mysql_sink/reconcile.cnf (0600 root: mysql client options for the
# monitor user via the local socat proxy). Not meant to be run from the repo.
set -uo pipefail

CNF="${RECONCILE_CNF:-/etc/mysql_sink/reconcile.cnf}"
TARGET="${RECONCILE_TARGET:-/var/log/mysql_sink/processed/native_slow_query.log}"
STATE="${RECONCILE_STATE:-/var/lib/mysql_sink/symlinks.list}"

log() { echo "reconcile: $*"; }

if ! P="$(mysql --defaults-extra-file="$CNF" -Nse 'SELECT @@slow_query_log_file' 2>&1)"; then
  # Transient by nature (failover in progress, proxy restarting): report and
  # try again next tick rather than failing the unit into a restart loop.
  log "could not query slow_query_log_file (will retry next run): ${P}"
  exit 0
fi
if [ -z "$P" ] || [ "${P:0:1}" != "/" ]; then
  log "unexpected slow_query_log_file value '${P}' — not touching anything"
  exit 0
fi

if [ -L "$P" ] && [ "$(readlink -f "$P")" = "$TARGET" ]; then
  exit 0   # already correct — the common case, silent
fi
if [ -e "$P" ] || [ -L "$P" ]; then
  log "ERROR: ${P} exists and is not our symlink to ${TARGET} — leaving it alone (fix by hand, then re-run setup.sh)"
  exit 1
fi

mkdir -p "$(dirname "$P")" && chmod 755 "$(dirname "$P")"
ln -s "$TARGET" "$P"
mkdir -p "$(dirname "$STATE")"
grep -qxF "$P" "$STATE" 2>/dev/null || echo "$P" >> "$STATE"
log "slow_query_log_file is now ${P} (DB failover/replacement?) — created symlink -> ${TARGET}"
