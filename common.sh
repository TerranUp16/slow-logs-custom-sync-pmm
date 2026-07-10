#!/usr/bin/env bash
# common.sh — shared helpers for setup.sh, verify-slow-log.sh, and destruct.sh.
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
