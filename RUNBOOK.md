# DO Managed MySQL Slow Log → PMM 3 QAN — Runbook

## Overview

DigitalOcean Managed MySQL doesn't expose its filesystem, so PMM can't tail the
slow query log directly. This pipeline forwards the log via syslog, reconstructs
it into a real slow-log file on a sink Droplet, and wires that into PMM
automatically. Full design rationale and component map: [docs/architecture.md](docs/architecture.md).

```
DO Managed MySQL (2-node cluster)
  --[mutual-TLS syslog port 6514, sink presents a Let's Encrypt cert]--> Sink Droplet (rsyslog, ossl)
    --> /var/log/mysql_sink/incoming/combined_mysql.log
    --> slow-query-sink.service (systemd daemon, continuous tail)
    --> /var/log/mysql_sink/processed/native_slow_query.log
    --> symlink at slow_query_log_file path
    --> pmm-agent (mysql_slowlog_agent) tails symlink
    --> PMM Server QAN
```

`slow-query-sink.service` (`transform_logs.py`) reconstructs multi-line slow-query
blocks continuously, with no batch delay on this side of the pipeline. (PMM's own
QAN ingestion has a separate polling interval — see Step 6 and Troubleshooting.)

---

## Prerequisites

| What | Notes |
|------|-------|
| **PMM Server Droplet** | **Ubuntu 22.04 LTS or 24.04 LTS** — see "Supported OS versions" below. Minimum 4 GB RAM (8 GB recommended). Must be provisioned and reachable before running `setup.sh`. Note DigitalOcean offers [a prebuilt Marketplace Droplet to make this deployment easier](https://marketplace.digitalocean.com/apps/percona-monitoring-and-management) |
| **Sink Droplet** | **Ubuntu 22.04 LTS or 24.04 LTS** — see "Supported OS versions" below. Any size (required size based on database query load; can upscale the Droplet later if initial size guess is too small or weak). This is where `setup.sh` runs. |
| **DNS hostname for the sink** | A public DNS **A record** pointing at the sink Droplet's IP (e.g. `logs.example.com → <SINK_IP>`). Required — the sink presents a Let's Encrypt cert for this name, and certbot's HTTP-01 challenge needs it to resolve here. No domain handy? `<IP-dashed>.sslip.io` works for testing. |
| **DO Managed MySQL** | Slow query log must be enabled in the DO control panel (Database → Settings → Slow query log). |
| **`pmm_monitor` DB user** | Create via DO control panel (Database → Users). DO grants appropriate access by default — no additional `GRANT` statements needed. |
| **`.env` file** | Fill in all fields (see below) before running `setup.sh`. |

### Supported OS versions

**Ubuntu 22.04 LTS and 24.04 LTS only.** Ubuntu 26.04 LTS is **not supported** —
as of this writing, Percona has not released (or tested) `percona-release`/
`pmm-client` packages for it. Getting `pmm-client` installed on 26.04 requires
manually rewriting `apt` package-source distro codenames to point at an
older release's repo. That happens to work, but it's unverified by Percona
and can silently break on any Percona-side update — don't do this for a real
deployment. `setup.sh` prints a warning (not a hard stop) if it detects an
unsupported OS version, so existing test boxes aren't locked out, but treat
anything other than 22.04/24.04 as unsupported.

---

## Step 1 — Provision and configure the PMM Server Droplet

SSH into the new PMM server droplet and run the Percona easy-install script (NOTE- this can be skipped if you used the [DO Marketplace PMM deployment](https://marketplace.digitalocean.com/apps/percona-monitoring-and-management)):

```bash
curl -fsSL https://www.percona.com/get/pmm | bash
```

This installs Docker and starts the PMM server container automatically. Wait ~60 seconds for it to finish initializing.

**Getting an API token — two options:**

- **Automatic (recommended for a fresh install):** leave `PMM_TOKEN` blank in
  `.env`. `setup.sh` checks whether `PMM_SERVER` is reachable; if it is and
  nobody has logged into the PMM UI yet (still on the default `admin`/`admin`
  password), it mints an Admin-role API token itself via the PMM API and
  writes it into `.env`. If `PMM_SERVER` isn't reachable yet, `setup.sh` prints
  this install command and exits so you can run it, then re-run `setup.sh`.
- **Manual:**
  1. Open `https://<PMM_SERVER_IP>` in a browser (accept the self-signed cert warning).
  2. Log in with `admin` / `admin`.
  3. You will be prompted to change the password — do so.
  4. Go to **Administration → Users and access → Service Accounts → Add
     service account**. Name: anything (e.g. `sink-droplet`), Role: **Admin**.
  5. Open the new service account → **Add service account token** → copy the
     token (starts with `glsa_`; you will not be able to view it again; strongly recommend storing in a secure password manager). Put
     it into `.env` as `PMM_TOKEN`.

  (PMM 3 runs on Grafana 9+, which replaced the old "API Keys" page with
  Service Accounts + tokens — if you see stale docs/screenshots referencing
  "Settings → API Keys", use the Service Accounts path above instead.)

  Once you've changed the admin password via the UI, the automatic path no
  longer works (the default credentials are gone) — you must generate the
  token manually from then on.

---

## Step 2 — Clone the repo onto the sink Droplet

SSH into the sink Droplet and clone the repo there — this is the directory
`setup.sh` (and later `destruct.sh`/`verify-slow-log.sh`) will run from:

```bash
ssh root@<SINK_IP>
git clone git@github.com:TerranUp16/slow-logs-custom-sync-pmm.git
cd slow-logs-custom-sync-pmm
```

`.env` and `certs/` are gitignored, so this clone won't bring them over —
you'll create both directly on this Droplet over the next two steps. Nothing
in this runbook requires a separate laptop/dev machine or file transfer
between machines; everything happens in this one SSH session (plus a
browser for the DO and PMM control panels).

---

## Step 3 — Create and fill in `.env`

Create a file called `.env` in the `slow-logs-custom-sync-pmm` on your sink Droplet. Populate all the below values:

```dotenv
DB_HOST=<managed-db-hostname>.db.ondigitalocean.com
DB_PORT=25060
DB_PASS=<pmm_monitor user password>
PMM_MONITOR_USER=pmm_monitor

SINK_IP=<sink droplet IP>
SINK_HOSTNAME=<public DNS name for the sink, e.g. logs.example.com>
LETSENCRYPT_EMAIL=<contact address for the Let's Encrypt account>
PMM_SERVER=<pmm server IP>
PMM_TOKEN=<glsa_... token from Step 1, or leave blank to auto-mint on fresh installs>

# Path on the sink Droplet to DO Managed DB CA cert (download from DB control panel)
DO_CA_BUNDLE=/etc/mysql_sink/do-ca.crt
```

> `SINK_HOSTNAME` is the linchpin of the TLS design: rsyslog presents a Let's Encrypt
> cert issued for this name, and it is the destination you configure in DO log
> forwarding. It **must** resolve publicly (A record) to `SINK_IP`. For a quick test
> with no domain, use `<IP-dashed>.sslip.io` (e.g. `142-93-154-42.sslip.io`) — see
> [docs/sslip.md](docs/sslip.md) for a full walkthrough.

> Open the [DO Managed DB **CA certificate** in the database control panel](https://docs.digitalocean.com/products/databases/mysql/how-to/connect/#download-the-ssl-encryption)
> (Connection Details → Download CA certificate). Rather than downloading it
> to a separate machine, paste its contents directly into a file on the sink
> Droplet, in the same SSH session — e.g.:
> ```bash
> mkdir -p certs
> cat > certs/do-ca.crt   # paste the certificate contents, then press Ctrl-D
> ```
> Like `certs/ca.pem`, this file is gitignored and never travels via git.
> `setup.sh` installs it to the `DO_CA_BUNDLE` path, and the DB-credential
> probe verifies the DB cert chain against it (`ssl-mode=VERIFY_CA`).

---

## Step 4 — Configure DO Managed DB

### Advanced Configuration

In the DO control panel, go to [**Databases → your cluster → Settings → Advanced Configuration**](https://docs.digitalocean.com/products/databases/mysql/how-to/reconfigure/#update-a-databases-configuration-using-the-control-panel) and set:

| Setting | Value | Notes |
|---------|-------|-------|
| `slow_query_log` | `on` | Enables slow query logging |
| `log_output` | `INSIGHTS` | **Required** — DO's abstraction for `FILE`; if set to `TABLE`, slow queries are not forwarded via syslog. NOTE- due to a bug, if this has never been changed on the cluster yet, this will show as `INSIGHTS`, but it is actually set to `TABLE`. Set this to any other value, save the change, and then change this to `INSIGHTS` and save the configuration change to properly apply `INSIGHTS` setting. Note you can verify if this is set correctly by checking `SELECT @@log_output;` on your MySQL command-line- you want to see `FILE` instead of `TABLE` from this command's output |
| `long_query_time` | `0` | Captures all queries |

Save and wait ~30 seconds for the settings to apply.

### Generate mTLS certificates (before configuring forwarding)

Still on the sink Droplet, from this repo directory:

```bash
./gen-certs.sh    # writes certs/ca.pem, certs/ca-key.pem, certs/do-client-{cert,key}.pem
```

This creates a private CA and the DO client cert **directly on this
Droplet** — no separate machine involved, and nothing to transfer
afterward. `setup.sh` will read `certs/ca.pem` straight out of this checkout
in Step 5.

This design deliberately uses a single, non-HA sink Droplet (see
[docs/architecture.md](docs/architecture.md)), so there's no need to keep
the CA authority anywhere else or make it portable between machines. If this
Droplet is ever rebuilt, just re-run `gen-certs.sh` there and re-paste the
new client cert into DO's control panel below — a few minutes of manual
work, not a design problem to solve around.

Of the four files this produces:

| File | Where it's used | Notes |
|------|------------------|-------|
| `ca.pem` | This Droplet — `setup.sh` installs it to `/etc/rsyslog.d/tls/ca.pem` to verify DO's client cert | Safe to leave here |
| `do-client-cert.pem` / `do-client-key.pem` | DO's control panel only | Paste into the Log Forwarding form below (`cat certs/do-client-cert.pem`, `cat certs/do-client-key.pem`) — `setup.sh` never reads these |
| `ca-key.pem` | Nowhere else. Stays on this Droplet, full stop. | Never commit it, never copy it to another machine |

(`certs/do-ca.crt` — the DO Managed DB's own CA cert from Step 3 — lives
alongside these but isn't produced by `gen-certs.sh`.)

### Log Forwarding (Syslog over mutual TLS)

`setup.sh` obtains a Let's Encrypt cert for `SINK_HOSTNAME` and configures rsyslog to
present it. Use that **same hostname** as the destination.

In the DO control panel, [go to **Databases → your cluster → Settings → Log
Forwarding**](https://docs.digitalocean.com/products/databases/mysql/how-to/forward-logs/)
and add (or edit) a Rsyslog Destination. The form has these fields, top to bottom —
field names below match the DO UI exactly:

- **Destination name** — any label; using `SINK_HOSTNAME` itself is fine and keeps
  things unambiguous.
- **Endpoint** (required) — `SINK_HOSTNAME` (the DNS name — e.g. `logs.example.com`
  or your `sslip.io` hostname, see [docs/sslip.md](docs/sslip.md); **not** a raw IP).
- **Port** (required) — `6514`.
- **Enable TLS support** — check this box. (There's no separate protocol field —
  TCP is implied once TLS is enabled.)
- **Message format** — change this to **`RFC3164`**. **DO's default is not
  this** (the dropdown defaults to a different format) — you must explicitly
  change it, or `transform_logs.py` won't recognize the incoming lines and
  nothing will show up in the processed slow-query log.
- Click **Show advanced configuration options** to reveal three more fields,
  collapsed by default:
  - **CA certificate** = **leave blank** (DO trusts the Let's Encrypt server cert
    via its own system bundle — don't paste anything here)
  - **Client key** = paste the full contents of `certs/do-client-key.pem`
    (`cat certs/do-client-key.pem` on the sink Droplet, copy the output —
    everything between and including the `BEGIN`/`END PRIVATE KEY` lines)
  - **Client certificate** = paste the full contents of `certs/do-client-cert.pem`
    (`cat certs/do-client-cert.pem` — everything between and including the
    `BEGIN`/`END CERTIFICATE` lines)

Click **Save Destination**. Log forwarding starts within ~1–2 minutes (DO redeploys
the forwarder after a config change). After a cert/destination change, a full
disable → save → re-enable cycle forces a faster reload.

> The advanced options are collapsed by default — if you only fill in Endpoint/Port/TLS
> and save, DO has no client cert to present and the mTLS handshake will fail. Always
> expand **Show advanced configuration options** and fill in all three fields (CA
> certificate blank, Client key, Client certificate filled) before saving.

> Deploying to a private/VPC sink with no public port 80, or want to know why
> these specific field values (blank CA, `ossl` driver) are what they are?
> See [docs/tls-and-certificates.md](docs/tls-and-certificates.md) — it also
> covers the DNS-01 alternative to the default HTTP-01 certificate challenge.
> No domain to test with? See [docs/sslip.md](docs/sslip.md).

---

## Step 5 — Deploy slow log integration on the sink Droplet

Everything `setup.sh` needs — the repo, `.env`, and `certs/ca.pem`/`certs/do-ca.crt`
— is already on the sink Droplet from Steps 2–4. Nothing to copy or transfer.
Just run it, still in the same SSH session:

```bash
bash setup.sh
```

`setup.sh` does the following automatically:
1. Checks this is a supported Ubuntu version (warns, doesn't block, if not), then verifies direct DB connectivity before making any changes.
2. Creates the dedicated `mysqlsink` service user and `/var/log/mysql_sink/{bin,incoming,processed}` with least-privilege ownership.
3. Deploys `transform_logs.py` and installs `socat`, a MySQL client, `rsyslog-openssl`, and `certbot`.
4. Deploys the private CA cert, obtains (or reuses) a Let's Encrypt cert for `SINK_HOSTNAME`, and configures rsyslog for mutual-TLS syslog on port 6514 using the `ossl` driver.
5. Installs `pmm-client`, creates the `socat` proxy service (so PMM connects to the DB via a local-looking address), and starts `slow-query-sink.service`.
6. Registers the node with PMM Server.
7. Queries the DB for its `slow_query_log_file` path and symlinks it to the processed log.
8. Registers the MySQL service in PMM with `--query-source=slowlog`, and verifies it actually appears in `pmm-admin list`.

It's idempotent — safe to re-run after fixing a config issue.

---

## Step 6 — Verify

**On the sink droplet:**

```bash
# Daemon should be active (running)
systemctl status slow-query-sink.service

# Live daemon logs
journalctl -u slow-query-sink -f

# All PMM agents should show Running
pmm-admin list

# Check rsyslog is receiving data (file grows continuously)
ls -lh /var/log/mysql_sink/incoming/combined_mysql.log

# Check the daemon is producing output
tail -f /var/log/mysql_sink/processed/native_slow_query.log

# Confirm the symlink is correct — pulls creds from .env automatically, and
# prints the REAL mysql error on failure instead of silently returning nothing.
bash verify-slow-log.sh              # via the socat proxy — what pmm-agent actually uses
bash verify-slow-log.sh --direct     # bypass the proxy — isolates "is it the proxy, or the DB/firewall?"
```

> If `verify-slow-log.sh` fails, read the printed checklist — it covers DO's
> **Trusted Sources** firewall, the socat proxy, credentials, and TLS/CA
> mismatches, in that order of likelihood. `setup.sh` runs the same check
> (via `common.sh`'s `mysql_probe`) as a preflight, before touching anything
> else on the droplet, so the same message shows up there too if connectivity
> is broken.

**In PMM UI:**
- Navigate to **QAN** and select the `do-managed-mysql` service. See the note below on ingestion lag before assuming something's broken.

**Generate test prepared statements** (optional, uses `test_prepared_statements.py` — this
is what actually exercises the reason this whole pipeline exists: prepared
statements, which `performance_schema` QAN cannot see, but slow-log QAN can):
```bash
pip3 install mysql-connector-python --break-system-packages
set -a; source .env; set +a          # exposes DB_PASS from .env into this shell
python3 test_prepared_statements.py "${DB_PASS}"
```
(The script also accepts `DB_PASS=... python3 test_prepared_statements.py` with no
positional arg. Either way, a password is required — running it with neither just
prints its `Usage:` message and exits.)

> **QAN can lag behind the slow log by a minute or so.** The sink daemon
> (`transform_logs.py`) writes to `native_slow_query.log` immediately, but PMM's
> own QAN ingestion/aggregation pipeline has its own polling interval on top of
> that. If `grep` finds your test query in `native_slow_query.log` but QAN hasn't
> shown it yet, wait a bit before assuming something's broken.

---

## Re-deploying after a DB replacement

When the managed DB cluster is replaced (new hostname or password):

1. In the DO control panel: update the syslog destination to point to the same sink droplet IP (it may have been reset).
2. Create the `pmm_monitor` user on the new DB.
3. On the sink Droplet, update `.env` with the new `DB_HOST` and `DB_PASS`.
4. On the sink Droplet: `bash setup.sh`.

The script is idempotent — it updates the socat service target, recreates the symlink, and re-registers PMM (using `--force` if the node name already exists).

---

## Re-deploying to a new sink Droplet (existing PMM server)

This is a single, non-HA Droplet by design (see
[docs/architecture.md](docs/architecture.md)) — there's no standby to fail
over to, so replacing it means standing up a fresh one from scratch and
re-pointing DO at it. Because `gen-certs.sh` runs per-Droplet, the new
Droplet mints its **own new CA and client cert** — DO's Log Forwarding panel
needs updating, it isn't a no-op this time:

1. Provision a new Ubuntu droplet (22.04 LTS or 24.04 LTS).
2. On the new Droplet: clone the repo (Step 2), create and fill in `.env`
   (Step 3) — using the same `DB_HOST`/`DB_PASS`, and the new Droplet's own
   `SINK_IP` — and repoint `SINK_HOSTNAME`'s DNS A record at the new droplet's
   IP (keep the same hostname if you can — DO's log-forwarding *destination*
   field then needs no change).
3. Run `./gen-certs.sh` on the new Droplet. This mints a brand-new private CA
   and client cert — it does **not** reuse anything from the old Droplet.
4. In DO's control panel (Step 4's Log Forwarding section), update the
   **Client Certificate** and **Client Key** fields to the new Droplet's
   `certs/do-client-cert.pem`/`do-client-key.pem` contents. If `SINK_HOSTNAME`
   changed, also update the destination. **CA Certificate** stays blank as
   before.
5. Run `bash setup.sh` on the new Droplet (Step 5). It obtains a fresh Let's
   Encrypt cert for `SINK_HOSTNAME` (HTTP-01 needs port 80 reachable and the
   A record pointing here).
6. Open ports 6514/tcp (syslog) and 80/tcp (ACME) inbound in the new
   droplet's firewall if one is configured.
7. Decommission the old Droplet once QAN is confirmed flowing from the new
   one. Its CA/client cert are no longer trusted by DO once step 4 is saved,
   so there's no cleanup needed on DO's side beyond that field update.

---

## Tearing down / starting over (`destruct.sh`)

If a `setup.sh` run went sideways (or you just want a clean slate before
re-running it), use `destruct.sh` instead of manually hunting down what
`setup.sh` touched:

```bash
bash destruct.sh --dry-run     # preview what would be removed, changes nothing
bash destruct.sh               # prompts for confirmation, then tears down
bash destruct.sh --yes         # skip the confirmation prompt (automation)
```

It removes, in order: the `do-managed-mysql` PMM service, this node's PMM
registration (and every agent under it), the `slow-query-sink` and
`socat-mysql-proxy` systemd units, the rsyslog mTLS listener config and its
certs, the `slow_query_log_file` symlink (best-effort — needs the DB
reachable to resolve the path), `/etc/mysql_sink`, `/var/log/mysql_sink`,
the logrotate config, the `mysqlsink` system user, and the `ufw` rules
`setup.sh` added.

It's scoped to exactly what `setup.sh` creates: PMM removal commands operate
on the local `pmm-agent`'s own node, so it never touches other
nodes/services in your PMM inventory. It does **not** uninstall shared
packages (`pmm-client`, `rsyslog-openssl`, `socat`, `certbot`) or your
Let's Encrypt certificate by default — reissuing a cert burns ACME
rate-limit budget, so pass `--purge-letsencrypt` only if you actually want
it gone. Pass `--keep-logs` to preserve captured slow-query history.

After `destruct.sh` finishes cleanly, `bash setup.sh` should run as if
against a fresh droplet.

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| `combined_mysql.log` doesn't exist at all, or exists but isn't growing | No data has ever arrived from DO (or hasn't recently). Check, in order: rsyslog is actually running — `systemctl status rsyslog`; it's listening — `ss -tlnp \| grep 6514`; firewall — `ufw status` (allow 6514/tcp); TLS handshake/cert errors, or a total absence of connection attempts — `journalctl -u rsyslog -n 100` (cert mismatch, expired, or wrong CA in DO panel; no attempts at all usually means DO's Log Forwarding config wasn't actually saved correctly); confirm DO's Log Forwarding destination has TLS enabled AND that **Show advanced configuration options** was expanded with Client key/Client certificate actually pasted in — it's collapsed by default and easy to miss (see Step 4) |
| `combined_mysql.log` has data but no `[SlowQuery]` lines | `log_output` is not set to `INSIGHTS` — change in DO advanced config (DO's abstraction for `FILE`; `TABLE` does not forward via syslog) |
| `native_slow_query.log` doesn't exist, even though `slow-query-sink.service` shows `active (running)` | **Expected, not a bug**, if `combined_mysql.log` doesn't exist yet: `transform_logs.py` blocks waiting to open `combined_mysql.log` before it ever creates/opens `native_slow_query.log`, and that blocking wait is not a crash — systemd will show the service as `active (running)` the whole time. Don't chase the daemon here; fix why `combined_mysql.log` is missing (row above), and this resolves itself. `bash verify-slow-log.sh` checks for exactly this and will say so explicitly rather than giving a false "OK" |
| `native_slow_query.log` empty after daemon runs (but `combined_mysql.log` is growing) | Check `combined_mysql.log` for `[SlowQuery]` lines — slow query log may not be enabled in DO settings |
| Daemon not running | `systemctl status slow-query-sink` and `journalctl -u slow-query-sink -n 50` |
| "Discarding stale incomplete block" in daemon logs | A multi-line slow query block arrived with missing lines — likely a transient rsyslog drop; normal at low frequency |
| `mysql_probe`/`setup.sh` preflight fails with `ERROR 1045 Access denied` | Networking is fine (you got a real MySQL auth response, not a timeout) — this is a credentials issue. Check `DB_PASS` in `.env` matches the current `pmm_monitor` password exactly; if `.env` was ever edited on Windows, check for a stray trailing `\r` (`cat -A .env \| grep DB_PASS` — a `^M` before the line end means CRLF snuck in and is silently corrupting the password when bash sources it: fix with `sed -i 's/\r$//' .env`). Also confirm `pmm_monitor` actually exists on *this* DB cluster, not a previous one. |
| PMM agents not Running | `journalctl -u pmm-agent -n 50`; verify `PMM_TOKEN` is valid; check PMM server is reachable on port 443 |
| QAN shows no data | First check whether it's just lagging: `grep` the query text in `/var/log/mysql_sink/processed/native_slow_query.log` — if it's there, QAN's own ingestion has a polling delay on top of the sink's real-time write, give it a minute or two. If it's genuinely absent: run `bash verify-slow-log.sh` — it checks both the symlink path AND that the target file actually exists (`readlink -f` alone will resolve a path even if nothing exists there, which reads as "correct" when it isn't); confirm `mysql_slowlog_agent` is Running in `pmm-admin list` |
| `socat-mysql-proxy` fails to start | Check `DB_HOST` and `DB_PORT` in `/etc/systemd/system/socat-mysql-proxy.service`; test connectivity: `nc -zv <DB_HOST> 25060` |
| `setup.sh`'s DB preflight/probe fails outright (no connection), or `verify-slow-log.sh` errors | Read the printed checklist (from `mysql_probe` in `common.sh`) — most common cause is the sink Droplet not being in the DB cluster's **Trusted Sources** (Databases → cluster → Settings → Trusted Sources); DO drops the connection with no error visible on this end. Also check the socat proxy (`systemctl status socat-mysql-proxy`), credentials in `.env`, and that the CA cert matches this exact cluster. `bash verify-slow-log.sh --direct` bypasses the proxy to isolate proxy vs. DB/firewall |
| `mysql: command not found` (from `common.sh`'s `mysql_probe`, right at the start of `setup.sh`) | Expected to self-heal: `mysql_probe` auto-installs `default-mysql-client` via `apt-get` the first time it's needed, since a fresh Droplet doesn't ship a MySQL client and the preflight check runs before `setup.sh`'s own package-install step. If you still see this, either you're on an old copy of `common.sh` (`git pull` and re-run), you're not running as root (apt-get install needs root), or the Droplet has no working internet/apt access — install it yourself with `apt-get install -y default-mysql-client` and re-run |
| `pmm-admin config` returns "node already exists" | `setup.sh` uses `--force` by default, so re-running the script handles this automatically |
| Node + agents exist in PMM but no service | `setup.sh` registers the service last; if it exited earlier (e.g. the DB preflight/probe failed), the node/agents from `pmm-admin config` are left orphaned. Fix the earlier failure and re-run `setup.sh` — it's idempotent and will pick up from where it left off. To fully reset first, use `destruct.sh` above |
| rsyslog silent failure (action suspended/resumed loop) | `/var/log/mysql_sink` ownership must be `syslog:adm` mode `775` — root ownership breaks rsyslog writes |

---

## Key files in this repo

| Path | Purpose |
|------|---------|
| `common.sh` | Shared helper library — `mysql_probe()`, used by `setup.sh`, `verify-slow-log.sh`, and `destruct.sh` so DB-connection failures always surface the real error + a troubleshooting checklist instead of being swallowed |
| `verify-slow-log.sh` | Step 6 verification, automated — resolves `slow_query_log_file`, checks the symlink path, AND confirms the target file actually exists (a dangling symlink still "resolves" correctly, so both are checked). Supports `--direct` to bypass the socat proxy |
| `destruct.sh` | Tears down everything `setup.sh` created (PMM node/service/agents, systemd units, rsyslog config, log dirs, symlink) so a re-run of `setup.sh` starts clean. See "Tearing down / starting over" above |
| `test_prepared_statements.py` | Generates prepared-statement slow queries to validate the pipeline captures what `performance_schema` QAN cannot |

## Key files on the sink Droplet

| Path | Purpose |
|------|---------|
| `/var/log/mysql_sink/bin/transform_logs.py` | Daemon — continuously tails incoming log, reassembles syslog blocks into native slow log format |
| `/var/log/mysql_sink/incoming/combined_mysql.log` | rsyslog writes raw syslog messages here |
| `/var/log/mysql_sink/processed/native_slow_query.log` | Native slow query log consumed by PMM |
| `/etc/rsyslog.d/99-mysql-sink.conf` | mTLS imtcp listener (port 6514) → routes input to the incoming log file |
| `/etc/rsyslog.d/tls/` | CA + sink server cert/key used for the TLS syslog listener |
| `/etc/mysql_sink/do-ca.crt` | DO Managed DB CA cert, used for `VERIFY_CA` on the credential probe |
| `/etc/systemd/system/slow-query-sink.service` | Systemd unit for the parser daemon |
| `/etc/systemd/system/socat-mysql-proxy.service` | TCP proxy: `127.0.0.1:25060` → DO managed DB |
| `/etc/logrotate.d/mysql-sink` | Rotation for both incoming (3-day) and processed (14-day) logs |
