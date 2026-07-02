#!/usr/bin/env bash
# common.sh — shared helpers for setup.sh, verify-slow-log.sh, and destruct.sh.
# Not meant to be run directly; source it after `set -euo pipefail`.

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
