#!/usr/bin/env bash
# diagnose.sh — end-to-end pipeline health check.
#
# Why this exists: individual pieces of this pipeline can each look "fine" in
# isolation while the whole thing is broken — e.g. verify-slow-log.sh reporting
# the symlink is correctly configured tells you nothing about whether DO has
# ever actually delivered a single log line. This script walks every stage of
# the pipeline in order (DB config -> rsyslog -> TLS certs -> firewall ->
# incoming file -> daemon -> symlink/target -> PMM agent) and reports a clear
# PASS/WARN/FAIL for each, so a break in the middle doesn't just show up as a
# confusing absence of files three stages downstream.
#
# Run on the sink Droplet, from this repo's directory (needs .env present).
# Read-only — makes no changes. Safe to re-run anytime.
#
# Usage:
#   bash diagnose.sh            # full check via the socat proxy for the DB stage
#   bash diagnose.sh --direct   # DB stage queries the DB directly, bypassing socat
set -uo pipefail   # no -e: every stage should run and report, not abort on the first miss

SCRIPT_DIR_LOCAL="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR_LOCAL/common.sh"

if [ -f "$SCRIPT_DIR_LOCAL/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR_LOCAL/.env"
  set +a
fi

DB_HOST="${DB_HOST:-}"
DB_PORT="${DB_PORT:-25060}"
PMM_MONITOR_USER="${PMM_MONITOR_USER:-pmm_monitor}"
DB_PASS="${DB_PASS:-}"
DO_CA_BUNDLE="${DO_CA_BUNDLE:-/etc/mysql_sink/do-ca.crt}"
DO_CA_SRC="${DO_CA_SRC:-$SCRIPT_DIR_LOCAL/certs/do-ca.crt}"
TLS_DIR="/etc/rsyslog.d/tls"
INCOMING_FILE="/var/log/mysql_sink/incoming/combined_mysql.log"
PROCESSED_FILE="/var/log/mysql_sink/processed/native_slow_query.log"

MODE="proxy"
if [ "${1:-}" = "--direct" ]; then
  MODE="direct"
fi

# Color PASS/WARN/FAIL when writing to an actual terminal (checked per stream,
# since PASS goes to stdout but WARN/FAIL go to stderr) and NO_COLOR isn't set
# (https://no-color.org). Falls back to plain text when piped/redirected/logged
# so output stays clean in files or CI.
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then GREEN=$'\033[32m'; RESET_OUT=$'\033[0m'; else GREEN=""; RESET_OUT=""; fi
if [ -z "${NO_COLOR:-}" ] && [ -t 2 ]; then YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET_ERR=$'\033[0m'; else YELLOW=""; RED=""; RESET_ERR=""; fi

PASS=0; WARN=0; FAIL=0
pass() { echo "  ${GREEN}PASS${RESET_OUT}: $1"; PASS=$((PASS + 1)); }
warn() { echo "  ${YELLOW}WARN${RESET_ERR}: $1" >&2; WARN=$((WARN + 1)); }
fail() { echo "  ${RED}FAIL${RESET_ERR}: $1" >&2; FAIL=$((FAIL + 1)); }
section() { echo ""; echo "==> $1"; }

echo "Pipeline health check — every stage runs and reports; a FAIL early on"
echo "is usually the real cause of FAILs/WARNs further down, not a separate problem."

# --- 1: DB slow-query configuration -----------------------------------------
section "1/9 DB slow-query configuration"
if [ "$MODE" = "direct" ]; then
  DB_QUERY_HOST="$DB_HOST"; DB_QUERY_CA="$DO_CA_SRC"
else
  DB_QUERY_HOST="127.0.0.1"; DB_QUERY_CA="$DO_CA_BUNDLE"
fi
if [ -n "$DB_HOST" ] && [ -n "$DB_PASS" ] && [ -f "$DB_QUERY_CA" ]; then
  DB_VARS="$(mysql_probe "$PMM_MONITOR_USER" "$DB_PASS" "$DB_QUERY_HOST" "$DB_PORT" "$DB_QUERY_CA" \
    "SELECT @@slow_query_log, @@log_output, @@long_query_time;" 2>/dev/null || true)"
  if [ -n "$DB_VARS" ]; then
    read -r SLOW_ON LOG_OUT LONG_TIME <<<"$DB_VARS"
    if [ "$SLOW_ON" = "1" ]; then pass "slow_query_log is ON"; else fail "slow_query_log is OFF (@@slow_query_log=$SLOW_ON) — enable it in DO Advanced Configuration"; fi
    if [ "$LOG_OUT" = "FILE" ]; then pass "log_output is FILE (DO's INSIGHTS mode — correctly forwarding via syslog)"; else fail "log_output is '$LOG_OUT', expected FILE — set log_output=INSIGHTS in DO Advanced Configuration (RUNBOOK Step 4 has a note about a toggle bug: if it's never been changed before, it may show INSIGHTS in the UI while actually still TABLE — set it to something else, save, then back to INSIGHTS, save again)"; fi
    # long_query_time is a decimal (MySQL reports it as e.g. "0.000000"), so a
    # plain string comparison against "0" fails even when it's really zero —
    # compare numerically instead.
    if awk -v v="$LONG_TIME" 'BEGIN { exit !(v == 0) }' 2>/dev/null; then
      pass "long_query_time is 0 (captures all queries)"
    else
      warn "long_query_time is $LONG_TIME, not 0 — queries faster than this won't be logged as slow"
    fi
  else
    fail "could not query DB config — see the mysql_probe error above, if any (credentials/network/TLS)"
  fi
else
  warn "skipped — DB_HOST/DB_PASS/.env or the CA cert ($DB_QUERY_CA) aren't all available"
fi

# --- 2: rsyslog service ------------------------------------------------------
section "2/9 rsyslog service"
if systemctl is-active --quiet rsyslog 2>/dev/null; then
  pass "rsyslog is active"
else
  fail "rsyslog is NOT active — systemctl status rsyslog ; journalctl -u rsyslog -n 50"
fi

# --- 3: TLS syslog listener ---------------------------------------------------
section "3/9 TLS syslog listener (port 6514)"
if command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -q ':6514'; then
  pass "something is listening on 6514/tcp"
else
  fail "nothing is listening on 6514/tcp — rsyslog's imtcp module may have failed to load; check journalctl -u rsyslog -n 50 for module load errors"
fi

# --- 4: TLS certificate files -------------------------------------------------
section "4/9 TLS certificate files"
for f in ca.pem sink-server-cert.pem sink-server-key.pem; do
  if [ -f "$TLS_DIR/$f" ]; then
    pass "$TLS_DIR/$f exists"
  else
    fail "$TLS_DIR/$f is MISSING — re-run setup.sh"
  fi
done
if [ -f "$TLS_DIR/sink-server-cert.pem" ]; then
  if command -v openssl >/dev/null 2>&1 && openssl x509 -in "$TLS_DIR/sink-server-cert.pem" -noout -checkend 0 >/dev/null 2>&1; then
    pass "sink-server-cert.pem is not expired"
  else
    fail "sink-server-cert.pem is EXPIRED or invalid — check: certbot certificates ; journalctl -u certbot"
  fi
fi

# --- 5: recent rsyslog TLS/imtcp errors --------------------------------------
section "5/9 Recent rsyslog TLS/imtcp messages"
if command -v journalctl >/dev/null 2>&1; then
  RECENT="$(journalctl -u rsyslog --since '30 min ago' --no-pager 2>/dev/null | grep -iE 'error|tls|decrypt|imtcp|certificate' || true)"
  if [ -n "$RECENT" ]; then
    warn "found recent rsyslog messages mentioning TLS/errors/imtcp — review them (last 20 shown):"
    echo "$RECENT" | tail -20 | sed 's/^/    /' >&2
  else
    echo "  No matching messages in the last 30 min. This does NOT confirm data is arriving —"
    echo "  only that rsyslog hasn't logged a TLS/imtcp error. If stage 7 below shows no data"
    echo "  has ever arrived, silence here often means DO never even attempted a connection —"
    echo "  re-check DO's Log Forwarding config (destination/port match, and that 'Show advanced"
    echo "  configuration options' was expanded with Client key/Client certificate actually"
    echo "  filled in — DO gives no error of its own for a misconfigured or stale destination)."
  fi
else
  warn "journalctl not available — skipping"
fi

# --- 6: firewall --------------------------------------------------------------
section "6/9 Firewall (ufw)"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
  if ufw status | grep -q '6514'; then
    pass "ufw allows 6514/tcp"
  else
    fail "ufw is active but shows no rule for 6514/tcp — ufw allow 6514/tcp"
  fi
else
  echo "  ufw not active on this Droplet — nothing to check here."
  echo "  Remember: a separate DO Cloud Firewall (if one is attached to this Droplet in the"
  echo "  DO control panel) is NOT visible to this script and could independently block 6514."
fi

# --- 7: incoming syslog file --------------------------------------------------
section "7/9 Incoming syslog file ($INCOMING_FILE)"
if [ ! -e "$INCOMING_FILE" ]; then
  fail "$INCOMING_FILE does not exist — no data has EVER arrived from DO. Most likely causes,"
  echo "    roughly in order: (a) DO's Log Forwarding destination isn't fully configured for" >&2
  echo "    THIS cluster/Droplet — especially the collapsed 'Show advanced configuration" >&2
  echo "    options' section (Client key/Client certificate); (b) a mismatched/stale client" >&2
  echo "    cert if gen-certs.sh was re-run since DO's config was last saved (a fresh CA/cert" >&2
  echo "    pair needs re-pasting into DO's panel — see RUNBOOK 'Re-deploying to a new sink" >&2
  echo "    Droplet'); (c) the mTLS handshake is failing (see stage 5); (d) network/firewall" >&2
  echo "    blocks port 6514 inbound (see stage 6, and DO Cloud Firewalls)." >&2
else
  SIZE1=$(stat -c%s "$INCOMING_FILE" 2>/dev/null || echo 0)
  sleep 3
  SIZE2=$(stat -c%s "$INCOMING_FILE" 2>/dev/null || echo 0)
  if [ "$SIZE2" -gt "$SIZE1" ]; then
    pass "$INCOMING_FILE is growing ($SIZE1 -> $SIZE2 bytes over 3s) — data is actively arriving"
  else
    warn "$INCOMING_FILE exists ($SIZE2 bytes) but didn't grow during a 3s sample — could just be between forwarded lines; re-run this script, or generate a workload with test_prepared_statements.py first"
  fi
fi

# --- 8: slow-query-sink.service ----------------------------------------------
section "8/9 slow-query-sink.service (transform_logs.py)"
if systemctl is-active --quiet slow-query-sink 2>/dev/null; then
  pass "slow-query-sink.service is active"
  echo "  Note: 'active (running)' only means the process is alive — if stage 7 shows no"
  echo "  incoming file, this daemon is parked waiting for it to appear, which is expected"
  echo "  behavior, not a crash. Last 5 log lines:"
  journalctl -u slow-query-sink -n 5 --no-pager 2>/dev/null | sed 's/^/    /'
else
  fail "slow-query-sink.service is NOT active — systemctl status slow-query-sink ; journalctl -u slow-query-sink -n 50"
fi

# --- 9: symlink, target file, and PMM agent status ---------------------------
section "9/9 Symlink, target file, and PMM agent status"
VERIFY_LOG="$(mktemp)"
if bash "$SCRIPT_DIR_LOCAL/verify-slow-log.sh" $([ "$MODE" = "direct" ] && echo --direct) >"$VERIFY_LOG" 2>&1; then
  pass "verify-slow-log.sh reports the symlink and target file are both correct"
else
  fail "verify-slow-log.sh reports a problem:"
  sed 's/^/    /' "$VERIFY_LOG" >&2
fi
rm -f "$VERIFY_LOG"

if command -v pmm-admin >/dev/null 2>&1; then
  AGENT_LINE="$(pmm-admin list 2>/dev/null | grep mysql_slowlog_agent || true)"
  if [ -n "$AGENT_LINE" ]; then
    echo "  $AGENT_LINE"
    if echo "$AGENT_LINE" | grep -q 'Running'; then
      pass "mysql_slowlog_agent is Running"
    else
      warn "mysql_slowlog_agent is not Running yet — it commonly shows 'Waiting' until $PROCESSED_FILE exists and has content, which will resolve once stages 7-8 above are fixed"
    fi
  else
    fail "mysql_slowlog_agent not found in pmm-admin list — was the MySQL service registered by setup.sh?"
  fi
else
  warn "pmm-admin not installed — skipping"
fi

# --- summary ------------------------------------------------------------------
echo ""
echo "==> Summary: $PASS passed, $WARN warning(s), $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "    Start with the FIRST FAIL above — later stages are frequently just downstream"
  echo "    symptoms of it, not separate problems."
  exit 1
elif [ "$WARN" -gt 0 ]; then
  echo "    No hard failures, but review the warning(s) above."
  exit 0
else
  echo "    Pipeline looks healthy end-to-end."
  exit 0
fi
