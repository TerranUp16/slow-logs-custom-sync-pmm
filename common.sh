#!/usr/bin/env bash
# common.sh — shared helpers for setup.sh, verify-slow-log.sh, diagnose.sh, and destruct.sh.
# Not meant to be run directly; source it after `set -euo pipefail`.

# Memoized per-process so a script that calls mysql_probe multiple times
# (setup.sh does: once direct, once through the socat proxy) only checks/
# installs once instead of re-running apt-get update every time.
_MYSQL_CLIENT_ENSURED=""

# ensure_mysql_client
#
# Makes sure a `mysql` client binary is on PATH, installing `default-mysql-client`
# via apt if it isn't. A fresh Ubuntu Droplet does not ship one, and setup.sh's
# DB preflight (the very first real check it runs, by design, so bad
# DB_HOST/DB_PASS/Trusted-Sources fails fast) runs before setup.sh's own later
# `apt-get install` block — so without this, that preflight fails with
# "mysql: command not found" on a completely fresh box, which looks like (but
# isn't) a DB connectivity problem. Living here means every script that sources
# common.sh and calls mysql_probe (setup.sh, verify-slow-log.sh, destruct.sh)
# gets this fixed in one place, regardless of what's been installed so far.
ensure_mysql_client() {
  [ -n "$_MYSQL_CLIENT_ENSURED" ] && return 0

  if command -v mysql >/dev/null 2>&1; then
    _MYSQL_CLIENT_ENSURED=1
    return 0
  fi

  echo "==> 'mysql' client not found — installing default-mysql-client" >&2

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "ERROR: 'mysql' client is missing and apt-get is not available to install it." >&2
    echo "Install a MySQL client manually (the 'mysql' binary must be on PATH) and re-run." >&2
    return 1
  fi
  if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: 'mysql' client is missing and installing it requires root (apt-get)." >&2
    echo "Re-run as root, or install it yourself first: sudo apt-get install -y default-mysql-client" >&2
    return 1
  fi

  if ! DEBIAN_FRONTEND=noninteractive apt-get update -q \
      || ! DEBIAN_FRONTEND=noninteractive apt-get install -y -q default-mysql-client; then
    echo "ERROR: Failed to auto-install 'default-mysql-client' via apt-get." >&2
    echo "Install it manually (apt-get install -y default-mysql-client) and re-run." >&2
    return 1
  fi

  if ! command -v mysql >/dev/null 2>&1; then
    echo "ERROR: apt-get install default-mysql-client succeeded, but 'mysql' is still not on PATH." >&2
    return 1
  fi

  echo "  mysql client installed." >&2
  _MYSQL_CLIENT_ENSURED=1
  return 0
}

# --- configuration --------------------------------------------------------------

# load_config SCRIPT_DIR
#
# Sources SCRIPT_DIR/.env (if present) and fills in every optional setting with
# its default, so all scripts agree on defaults. Required settings are checked
# by each script itself (setup.sh needs more than diagnose.sh does).
#
# Every new key defaults to what a pre-multi-instance sink already used, so an
# old-style .env keeps producing exactly the same service name, node name,
# ports, paths and units.
# shellcheck disable=SC2034  # everything set here is read by the sourcing script
load_config() {
  local dir="$1"
  if [ -f "$dir/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$dir/.env"
    set +a
  fi
  DB_HOST="${DB_HOST:-}"
  DB_PORT="${DB_PORT:-25060}"
  DB_PASS="${DB_PASS:-}"
  PMM_MONITOR_USER="${PMM_MONITOR_USER:-pmm_monitor}"
  # Local side of the socat proxy (what pmm-agent and every probe connect to on
  # 127.0.0.1). Defaults to DB_PORT, which is what it always was.
  LOCAL_PROXY_PORT="${LOCAL_PROXY_PORT:-$DB_PORT}"
  # PMM identity. PMM_SERVICE_NAME_DEFAULTED lets callers print a one-line notice.
  PMM_SERVICE_NAME_DEFAULTED=0
  if [ -z "${PMM_SERVICE_NAME:-}" ]; then
    PMM_SERVICE_NAME="do-managed-mysql"
    PMM_SERVICE_NAME_DEFAULTED=1
  fi
  # PMM_NODE_NAME_SET distinguishes "explicitly configured" from the default:
  # only an explicit name is passed to `pmm-admin config`, so an old-style .env
  # produces byte-for-byte the same registration call as before. The default is
  # `hostname` (the full one) because that is exactly what pmm-admin itself
  # uses when given no node name — not `hostname -s`, which differs on hosts
  # with an FQDN hostname and would rename existing nodes.
  PMM_NODE_NAME_SET=0
  if [ -n "${PMM_NODE_NAME:-}" ]; then
    PMM_NODE_NAME_SET=1
  else
    PMM_NODE_NAME="$(hostname)"
  fi
  PMM_FORCE_REREGISTER="${PMM_FORCE_REREGISTER:-0}"
  PMM_ENVIRONMENT="${PMM_ENVIRONMENT:-}"
  PMM_CLUSTER="${PMM_CLUSTER:-}"
  PMM_REPLICATION_SET="${PMM_REPLICATION_SET:-}"
  PMM_CUSTOM_LABELS="${PMM_CUSTOM_LABELS:-}"
}

# validate_config — fail with a clear message on values that would be unsafe
# to put into a pmm-admin command line or a systemd unit. Returns 1 (after
# printing every problem, not just the first) if anything is invalid.
validate_config() {
  local bad=0 v
  _name_ok() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
  for v in PMM_SERVICE_NAME PMM_NODE_NAME; do
    if ! _name_ok "${!v}"; then
      echo "ERROR: $v='${!v}' — only letters, digits, '.', '_' and '-' are allowed." >&2; bad=1
    fi
  done
  for v in PMM_ENVIRONMENT PMM_CLUSTER PMM_REPLICATION_SET; do
    if [ -n "${!v}" ] && ! _name_ok "${!v}"; then
      echo "ERROR: $v='${!v}' — only letters, digits, '.', '_' and '-' are allowed." >&2; bad=1
    fi
  done
  # k=v,k=v with Prometheus-style keys (PMM labels end up as metric labels).
  if [ -n "$PMM_CUSTOM_LABELS" ] && ! [[ "$PMM_CUSTOM_LABELS" =~ ^[A-Za-z_][A-Za-z0-9_]*=[A-Za-z0-9._-]+(,[A-Za-z_][A-Za-z0-9_]*=[A-Za-z0-9._-]+)*$ ]]; then
    echo "ERROR: PMM_CUSTOM_LABELS='$PMM_CUSTOM_LABELS' — expected key=value[,key=value...], keys like" >&2
    echo "       [A-Za-z_][A-Za-z0-9_]*, values of letters, digits, '.', '_' and '-'." >&2; bad=1
  fi
  for v in DB_PORT LOCAL_PROXY_PORT; do
    if ! [[ "${!v}" =~ ^[0-9]+$ ]] || [ "${!v}" -lt 1 ] || [ "${!v}" -gt 65535 ]; then
      echo "ERROR: $v='${!v}' is not a TCP port (1-65535)." >&2; bad=1
    fi
  done
  case "$PMM_FORCE_REREGISTER" in 0|1) ;; *)
    echo "ERROR: PMM_FORCE_REREGISTER='$PMM_FORCE_REREGISTER' — must be 0 or 1." >&2; bad=1 ;;
  esac
  return "$bad"
}

# --- PMM ------------------------------------------------------------------------

_PMM_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pmm_helper.py"

# pmm_service_exists NAME — true iff a PMM service named EXACTLY NAME is
# registered on this node (never a substring match: `prod-primary` must not
# match `prod-primary-ro`).
pmm_service_exists() {
  pmm-admin --json list 2>/dev/null | python3 "$_PMM_HELPER" service-id "$1" >/dev/null
}

# pmm_slowlog_agent_id NAME — agent ID of NAME's QAN slowlog agent, or nothing.
pmm_slowlog_agent_id() {
  pmm-admin --json list 2>/dev/null | python3 "$_PMM_HELPER" slowlog-agent-id "$1" || true
}

# pmm_stale_services NAME PORT — MySQL services on this node at
# 127.0.0.1:PORT under a name other than NAME (this sink's own service under a
# previous PMM_SERVICE_NAME), one per line.
pmm_stale_services() {
  pmm-admin --json list 2>/dev/null | python3 "$_PMM_HELPER" stale-services "$1" "127.0.0.1:$2" || true
}

# pmm_slowlog_agent_status NAME — e.g. AGENT_STATUS_RUNNING, or nothing.
pmm_slowlog_agent_status() {
  pmm-admin --json list 2>/dev/null | python3 "$_PMM_HELPER" slowlog-agent-status "$1" || true
}

# pmm_local_status — prints "AGENT_ID NODE_ID NODE_NAME SERVER_HOST CONNECTED"
# for the local pmm-agent ("-" for unknown fields; CONNECTED is true/false).
# Works (all "-"/false) when pmm-client isn't installed or the agent is down.
pmm_local_status() {
  { pmm-admin --json status 2>/dev/null || true; } | python3 "$_PMM_HELPER" local-status
}

# pmm_service_owner NAME LOCAL_NODE_ID — exit 0 no such service on the PMM
# Server, 1 registered on LOCAL_NODE_ID, 2 on another node (JSON details on
# stdout), 3 API error. Needs PMM_SERVER/PMM_TOKEN.
pmm_service_owner() {
  PMM_SERVER="$PMM_SERVER" PMM_TOKEN="$PMM_TOKEN" python3 "$_PMM_HELPER" service-owner "$1" "$2"
}

# pmm_node_owner NAME LOCAL_AGENT_ID — exit 0 no such node, 1 ours, 2 another
# machine's (JSON details on stdout), 3 API error. Needs PMM_SERVER/PMM_TOKEN
# exported (the token is read from the environment, never argv).
pmm_node_owner() {
  PMM_SERVER="$PMM_SERVER" PMM_TOKEN="$PMM_TOKEN" python3 "$_PMM_HELPER" node-owner "$1" "$2"
}

# pmm_mint_token SA_NAME — prints a new token for Admin service account SA_NAME
# (created if missing), using PMM's default admin:admin. Exit 1 on failure.
pmm_mint_token() {
  PMM_SERVER="$PMM_SERVER" python3 "$_PMM_HELPER" mint-token "$1"
}

# mysql_probe USER PASS HOST PORT CA_BUNDLE QUERY
#
# Runs a single query against the DB using a 0600 temp options file (so the
# password never appears in argv/ps, same approach as the original inline
# probe). On success, prints the query's `-Nse` output to stdout.
#
# On failure, prints the REAL mysql client error plus a troubleshooting
# checklist to stderr and returns 1 — it never swallows the error with a
# blanket `2>/dev/null`, which is what made earlier failures look like
# silent no-ops (e.g. `ls` of the caller's cwd when a command substitution
# of this query came back empty).
#
# Callers under `set -e` should invoke it as either:
#   if ! mysql_probe ... >/dev/null; then exit 1; fi
#   RESULT=$(mysql_probe ...) || exit 1
# both are safe — the failure is caught before errexit would fire.
mysql_probe() {
  local user="$1" pass="$2" host="$3" port="$4" ca="$5" query="$6"
  local defaults_file err_file out rc

  ensure_mysql_client || return 1

  defaults_file="$(mktemp)"
  chmod 600 "$defaults_file"
  err_file="$(mktemp)"

  cat > "$defaults_file" <<EOF
[client]
user=${user}
password=${pass}
host=${host}
port=${port}
ssl-mode=VERIFY_CA
ssl-ca=${ca}
EOF

  if out="$(mysql --defaults-extra-file="$defaults_file" -Nse "$query" 2>"$err_file")"; then
    rc=0
  else
    rc=$?
  fi
  shred -u "$defaults_file" 2>/dev/null || rm -f "$defaults_file"

  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    {
      echo "ERROR: MySQL probe failed (host=${host} port=${port} user=${user})"
      echo "----- mysql client error -----"
      cat "$err_file"
      echo "-------------------------------"
      cat <<HINT
Likely causes, roughly in order:
  1. DB not reachable from this host — check Trusted Sources on the DO
     Managed MySQL cluster (Databases -> your cluster -> Settings -> Trusted
     Sources). This Droplet's IP (or its VPC/tag) must be listed, or DO
     drops the connection with no error visible on this end.
  2. If host=127.0.0.1: the socat proxy may be down —
       systemctl status socat-mysql-proxy
       ss -tlnp | grep ${port}
       journalctl -u socat-mysql-proxy -n 50
  3. Wrong credentials — confirm PMM_MONITOR_USER / DB_PASS in .env match
     the pmm_monitor DB user in the DO control panel.
  4. TLS/CA mismatch — confirm ${ca} was downloaded from THIS DB cluster's
     control panel (Connection Details -> Download CA certificate).
HINT
    } >&2
    rm -f "$err_file"
    return 1
  fi

  rm -f "$err_file"
  printf '%s\n' "$out"
  return 0
}
