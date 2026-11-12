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

load_config "$SCRIPT_DIR_LOCAL"   # .env + defaults (common.sh), incl. LOCAL_PROXY_PORT, PMM_SERVICE_NAME

DO_CA_BUNDLE="${DO_CA_BUNDLE:-/etc/mysql_sink/do-ca.crt}"
DO_CA_SRC="${DO_CA_SRC:-$SCRIPT_DIR_LOCAL/certs/do-ca.crt}"
TLS_DIR="/etc/rsyslog.d/tls"
INCOMING_FILE="/var/log/mysql_sink/incoming/combined_mysql.log"
PROCESSED_FILE="/var/log/mysql_sink/processed/native_slow_query.log"
# Every TCP port DO Log Forwarding connects to on this sink (one listener today).
SYSLOG_PORTS=(6514)

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
  DB_QUERY_HOST="$DB_HOST"; DB_QUERY_PORT="$DB_PORT"; DB_QUERY_CA="$DO_CA_SRC"
else
  DB_QUERY_HOST="127.0.0.1"; DB_QUERY_PORT="$LOCAL_PROXY_PORT"; DB_QUERY_CA="$DO_CA_BUNDLE"
fi
if [ -n "$DB_HOST" ] && [ -n "$DB_PASS" ] && [ -f "$DB_QUERY_CA" ]; then
  DB_VARS="$(mysql_probe "$PMM_MONITOR_USER" "$DB_PASS" "$DB_QUERY_HOST" "$DB_QUERY_PORT" "$DB_QUERY_CA" \
    "SELECT @@slow_query_log, @@log_output, @@long_query_time;" 2>/dev/null || true)"
  if [ -n "$DB_VARS" ]; then
    read -r SLOW_ON LOG_OUT LONG_TIME <<<"$DB_VARS"
    if [ "$SLOW_ON" = "1" ]; then pass "slow_query_log is ON"; else fail "slow_query_log is OFF (@@slow_query_log=$SLOW_ON) — enable it in DO Advanced Configuration"; fi
    if [ "$LOG_OUT" = "FILE" ]; then pass "log_output is FILE (DO's LOGS mode, formerly called INSIGHTS — correctly forwarding via syslog)"; else fail "log_output is '$LOG_OUT', expected FILE — set log_output=LOGS (older UI/docs: INSIGHTS) in DO Advanced Configuration (RUNBOOK Step 4 has a note about a toggle bug: on a cluster where it's never been changed, DO can report LOGS while MySQL is actually still on TABLE — set it to TABLE, save, then back to LOGS, save again)"; fi
    # long_query_time is a decimal (MySQL reports e.g. "0.100000"), so compare
    # numerically, not as strings. DO's API currently rejects anything below
    # 0.1, so 0.1 is the recommended (and lowest settable) value — see RUNBOOK
    # Step 4 for what that threshold means for QAN coverage.
    if awk -v v="$LONG_TIME" 'BEGIN { exit !(v <= 0.1) }' 2>/dev/null; then
      pass "long_query_time is $LONG_TIME (captures every statement taking >= this many seconds; faster ones never reach the slow log or QAN)"
    else
      warn "long_query_time is $LONG_TIME — statements faster than that never reach the slow log or QAN. Set it to 0.1 (the lowest value DO accepts) unless you deliberately want a higher threshold"
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
section "3/9 Listeners (TLS syslog ${SYSLOG_PORTS[*]}, socat proxy 127.0.0.1:${LOCAL_PROXY_PORT})"
# Exact port match on ss's local-address column (":6514" must not match ":65140").
listening() { ss -tlnH 2>/dev/null | awk -v p="$1" '{ n = split($4, a, ":"); if (a[n] == p) found = 1 } END { exit !found }'; }
if command -v ss >/dev/null 2>&1; then
  for p in "${SYSLOG_PORTS[@]}"; do
    if listening "$p"; then
      pass "something is listening on ${p}/tcp"
    else
      fail "nothing is listening on ${p}/tcp — rsyslog's imtcp module may have failed to load; check journalctl -u rsyslog -n 50 for module load errors"
    fi
  done
  if listening "$LOCAL_PROXY_PORT"; then
    pass "socat proxy is listening on ${LOCAL_PROXY_PORT}/tcp (LOCAL_PROXY_PORT)"
  else
    fail "nothing is listening on ${LOCAL_PROXY_PORT}/tcp (LOCAL_PROXY_PORT) — systemctl status socat-mysql-proxy ; journalctl -u socat-mysql-proxy -n 50"
  fi
else
  warn "ss not available — skipping"
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
  for p in "${SYSLOG_PORTS[@]}"; do
    if ufw status | grep -qE "^${p}(/tcp)?[[:space:]]"; then
      pass "ufw allows ${p}/tcp"
    else
      fail "ufw is active but shows no rule for ${p}/tcp — ufw allow ${p}/tcp"
    fi
  done
else
  echo "  ufw not active on this Droplet — nothing to check here."
  echo "  Remember: a separate DO Cloud Firewall (if one is attached to this Droplet in the"
  echo "  DO control panel) is NOT visible to this script and could independently block ${SYSLOG_PORTS[*]}."
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
  # Is the daemon writing to the file pmm-agent actually reads? Older versions
  # of transform_logs.py never reopened their output, so after the first
  # logrotate they kept appending to native_slow_query.log.1 while the real
  # path stayed empty.
  DAEMON_PID="$(systemctl show -p MainPID --value slow-query-sink 2>/dev/null)"
  if [ -n "$DAEMON_PID" ] && [ "$DAEMON_PID" != "0" ] && [ -e "$PROCESSED_FILE" ]; then
    WRITING_TO="$(for fd in /proc/"$DAEMON_PID"/fd/*; do readlink "$fd"; done 2>/dev/null | grep '/processed/' | head -1)"
    if [ -z "$WRITING_TO" ]; then
      echo "  (daemon has no processed-log file open yet — expected until the first data arrives)"
    elif [ "$WRITING_TO" = "$PROCESSED_FILE" ]; then
      pass "daemon is writing to $PROCESSED_FILE"
    else
      fail "daemon is writing to '$WRITING_TO', not $PROCESSED_FILE — it missed a log rotation (pre-fix transform_logs.py), so QAN sees no new data. Fix: git pull && bash setup.sh (or at least: systemctl restart slow-query-sink)"
    fi
  fi
else
  fail "slow-query-sink.service is NOT active — systemctl status slow-query-sink ; journalctl -u slow-query-sink -n 50"
fi

# --- 9: symlink, target file, and PMM agent status ---------------------------
section "9/9 Symlink, target file, and PMM agent status"
VERIFY_LOG="$(mktemp)"
VERIFY_ARGS=()
[ "$MODE" = "direct" ] && VERIFY_ARGS+=(--direct)
if bash "$SCRIPT_DIR_LOCAL/verify-slow-log.sh" "${VERIFY_ARGS[@]}" >"$VERIFY_LOG" 2>&1; then
  pass "verify-slow-log.sh reports the symlink and target file are both correct"
else
  fail "verify-slow-log.sh reports a problem:"
  sed 's/^/    /' "$VERIFY_LOG" >&2
fi
rm -f "$VERIFY_LOG"

if command -v pmm-admin >/dev/null 2>&1; then
  # Look up THIS sink's service by exact name, not "any mysql_slowlog_agent".
  SLOWLOG_ID="$(pmm_slowlog_agent_id "$PMM_SERVICE_NAME" | head -1)"
  if [ -n "$SLOWLOG_ID" ]; then
    SLOWLOG_STATUS="$(pmm_slowlog_agent_status "$PMM_SERVICE_NAME" | head -1)"
    echo "  service '${PMM_SERVICE_NAME}': slowlog agent ${SLOWLOG_ID} ${SLOWLOG_STATUS}"
    # "Running" is necessary but not sufficient: if the path it tails vanishes
    # (e.g. PMM's own rotation renamed our symlink), the agent stays "Running"
    # while logging "Failed to stat" every second and sending nothing.
    STAT_ERRORS="$(journalctl -u pmm-agent --since '5 min ago' --no-pager 2>/dev/null | grep 'Failed to stat' | grep -c "agentID=${SLOWLOG_ID}" || true)"
    if [ "${STAT_ERRORS:-0}" -gt 0 ]; then
      fail "the slowlog agent reports ${SLOWLOG_STATUS}, but pmm-agent logged $STAT_ERRORS 'Failed to stat' error(s) for it in the last 5 min — the slow-log path it tails is missing (see verify-slow-log.sh output above). Fix: git pull && bash setup.sh"
    elif [ "$SLOWLOG_STATUS" = "RUNNING" ] || [ "$SLOWLOG_STATUS" = "AGENT_STATUS_RUNNING" ]; then
      pass "slowlog agent for '${PMM_SERVICE_NAME}' is Running"
    else
      warn "slowlog agent for '${PMM_SERVICE_NAME}' is ${SLOWLOG_STATUS:-not Running} — it commonly shows 'Waiting' until $PROCESSED_FILE exists and has content, which will resolve once stages 7-8 above are fixed"
    fi
  else
    fail "no PMM service named exactly '${PMM_SERVICE_NAME}' with a slowlog agent on this node — was it registered by setup.sh? (pmm-admin list)"
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
