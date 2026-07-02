# DO Managed MySQL Slow Log → PMM 3 QAN — Runbook

## Overview

DigitalOcean Managed MySQL does not expose the filesystem, so PMM cannot tail the slow query log directly. This pipeline routes slow query logs from DO's syslog forwarding feature through a sink Droplet where they are parsed and reconstituted as a native MySQL slow log that PMM can consume.

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

The daemon (`transform_logs.py`) runs as a persistent systemd service. It tails the incoming file continuously, reconstructs multi-line slow query blocks keyed by `(source_host, block_id)` to avoid collisions between cluster nodes, and writes complete entries to the processed log immediately — no per-minute batch delay.

---

## Prerequisites

| What | Notes |
|------|-------|
| **PMM Server Droplet** | Ubuntu 22.04+, minimum 4 GB RAM (8 GB recommended). Must be provisioned and reachable before running `setup.sh`. |
| **Sink Droplet** | Ubuntu 22.04+, any size. This is where `setup.sh` runs. |
| **DNS hostname for the sink** | A public DNS **A record** pointing at the sink Droplet's IP (e.g. `logs.example.com → <SINK_IP>`). Required — the sink presents a Let's Encrypt cert for this name, and certbot's HTTP-01 challenge needs it to resolve here. No domain handy? `<IP-dashed>.sslip.io` works for testing. |
| **DO Managed MySQL** | Slow query log must be enabled in the DO control panel (Database → Settings → Slow query log). |
| **`pmm_monitor` DB user** | Create via DO control panel (Database → Users). DO grants admin-level access by default — no additional `GRANT` statements needed. |
| **`.env` file** | Fill in all fields (see below) before running `setup.sh`. |

---

## Step 1 — Provision and configure the PMM Server Droplet

SSH into the new PMM server droplet and run the Percona easy-install script:

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
     token (starts with `glsa_`; you will not be able to view it again). Put
     it into `.env` as `PMM_TOKEN`.

  (PMM 3 runs on Grafana 9+, which replaced the old "API Keys" page with
  Service Accounts + tokens — if you see stale docs/screenshots referencing
  "Settings → API Keys", use the Service Accounts path above instead.)

  Once you've changed the admin password via the UI, the automatic path no
  longer works (the default credentials are gone) — you must generate the
  token manually from then on.

---

## Step 2 — Fill in `.env`

Edit `.env` in this repo with all values:

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
> with no domain, use `<IP-dashed>.sslip.io` (e.g. `142-93-154-42.sslip.io`).

> Download the DO Managed DB **CA certificate** from the database control panel
> (Connection Details → Download CA certificate) and save it locally as
> `certs/do-ca.crt`. It rides along with the `gen-certs.sh` output when the repo is
> copied to the droplet, and `setup.sh` installs it to the `DO_CA_BUNDLE` path. The
> DB-credential probe verifies the DB cert chain against it (`ssl-mode=VERIFY_CA`).

> `.env` is gitignored. Never commit it.

---

## Step 3 — Configure DO Managed DB

### Advanced Configuration

In the DO control panel, go to **Databases → your cluster → Settings → Advanced Configuration** and set:

| Setting | Value | Notes |
|---------|-------|-------|
| `slow_query_log` | `on` | Enables slow query logging |
| `log_output` | `INSIGHTS` | **Required** — DO's abstraction for `FILE`; if set to `TABLE`, slow queries are not forwarded via syslog |
| `long_query_time` | `0` | Captures all queries during testing; raise to `1`–`2` for production |

Save and wait ~30 seconds for the settings to apply.

### Generate mTLS certificates (before configuring forwarding)

Run locally, from this repo directory:

```bash
./gen-certs.sh    # writes certs/ca.pem + certs/do-client-{cert,key}.pem
```

This creates a private CA and the DO client cert. `setup.sh` deploys `ca.pem` to
the droplet (used to verify DO's client cert) and obtains a Let's Encrypt server
cert via certbot (see Step 4). The CA private key (`certs/ca-key.pem`) stays on
your machine — never commit or deploy it. `certs/` is gitignored.

### How the two TLS directions work (important)

DO's log forwarder and the rsyslog sink authenticate **each other** (mutual TLS),
and the two directions use **different** trust anchors:

| Direction | Who verifies | Against what | DO panel field / rsyslog setting |
|-----------|--------------|--------------|----------------------------------|
| DO verifies the **sink's server cert** | DO forwarder | DO's **system CA bundle** (publicly trusts Let's Encrypt) | DO **CA Certificate** = **blank** |
| rsyslog verifies **DO's client cert** | rsyslog sink | our **private CA** | rsyslog `CAFile` = `/etc/rsyslog.d/tls/ca.pem` |

The sink presents a **publicly-trusted Let's Encrypt** cert issued for
`SINK_HOSTNAME`. Because it is publicly trusted, DO's **CA Certificate** field is
left **blank** and DO verifies it against its built-in system trust store (this is
what the DO docs mean by "ca — typically not needed"). **This is the only supported
design** — see the note below on why self-signed is not an option.

> **Hard-won facts (don't re-derive):**
> - **Always use a hostname + a publicly-trusted (Let's Encrypt) server cert.** This
>   is the only configuration DO accepts. A **private-CA / self-signed server cert is
>   always rejected with `certificate_unknown`** — proven exhaustively (both DNS and
>   IP SANs, `keyCertSign` set, chain vs. leaf, fresh clusters, `ossl` and `gtls`).
>   DO requires the sink cert to chain to a public root; a private CA can't satisfy
>   that. Do not attempt the self-signed path.
> - Leave DO's **CA Certificate** field **blank**. DO verifies the LE cert via its
>   system bundle. (After saving, DO takes ~1–2 min to redeploy the forwarder before
>   it reconnects; brief silence is normal.)
> - **DO does NOT clear the CA Certificate field once set** — blanking it in the UI
>   doesn't take; the old value persists. To truly get a blank CA, **create a fresh
>   forwarding destination** (delete + recreate, or a new cluster). A stale value
>   makes DO reject the LE cert with `certificate_unknown` — if a blank CA "isn't
>   working," suspect a cached value first.
> - The client cert (DO → rsyslog) uses our **private CA** — unrelated to the server
>   side above, and correct to keep.
> - No public domain? `<IP-dashed>.sslip.io` is a valid `SINK_HOSTNAME` for testing
>   (wildcard DNS: `142-93-154-42.sslip.io` → `142.93.154.42`), so certbot can issue
>   for an IP-only sink via HTTP-01.

### Log Forwarding (Syslog over mutual TLS)

`setup.sh` obtains a Let's Encrypt cert for `SINK_HOSTNAME` and configures rsyslog to
present it. Use that **same hostname** as the destination.

In the DO control panel, go to **Databases → your cluster → Settings → Log Forwarding**:

- **Destination:** `SINK_HOSTNAME` (the DNS name — e.g. `logs.example.com`; **not** a raw IP)
- **Port:** `6514`
- **Protocol:** `TCP`
- **Format:** `RFC3164`
- **TLS:** **enabled**, with:
  - **CA Certificate** = **leave blank** (DO trusts the Let's Encrypt server cert via its system bundle)
  - **Client Certificate** = `certs/do-client-cert.pem`
  - **Client Key** = `certs/do-client-key.pem`

Save. Log forwarding starts within ~1–2 minutes (DO redeploys the forwarder after
a config change). After a cert/destination change, a full disable → save →
re-enable cycle forces a faster reload.

### Alternative certificate issuance: DNS-01 (private / VPC sinks, no inbound port 80)

`setup.sh` uses certbot's **HTTP-01** challenge (`--standalone`), which requires the
sink to be **publicly reachable on port 80** and `SINK_HOSTNAME` to resolve to its
public IP. That's the right default for an internet-facing sink.

Use **DNS-01 instead** when any of these apply:

- The sink lives on a **VPC / private network** and has no public IP or inbound port 80.
- Port 80 can't be opened (firewall/policy).
- You want a **wildcard** cert, or to issue the cert **before** the droplet exists.

DNS-01 proves domain control via a `_acme-challenge` **TXT record** — it needs **no
inbound connectivity to the sink at all**. The sink still presents the resulting
publicly-trusted cert; DO still validates it against its system bundle (CA field
blank). The only requirement is that `SINK_HOSTNAME` resolves to an address DO's
forwarder can reach (a private VPC IP is fine — DO forwards over the VPC).

**Issuing with DNS-01.** Two options:

1. **DNS provider plugin (automated, renews unattended).** If your DNS is with a
   supported provider (Cloudflare, Route 53, DigitalOcean DNS, etc.), install the
   matching plugin and supply API credentials:
   ```bash
   apt-get install -y certbot python3-certbot-dns-digitalocean
   printf 'dns_digitalocean_token = %s\n' "$DO_DNS_TOKEN" > /root/.secrets/do.ini
   chmod 600 /root/.secrets/do.ini
   certbot certonly \
     --dns-digitalocean --dns-digitalocean-credentials /root/.secrets/do.ini \
     --non-interactive --agree-tos -m "$LETSENCRYPT_EMAIL" -d "$SINK_HOSTNAME"
   ```
   (Swap `digitalocean` for `cloudflare`/`route53`/etc. and the corresponding
   credentials file. Renewal is automatic via the certbot timer — no port 80.)

2. **Manual DNS-01 (one-off, e.g. no plugin for your provider).** certbot prints a
   TXT record to create; add it, then continue:
   ```bash
   certbot certonly --manual --preferred-challenges dns \
     --non-interactive --agree-tos -m "$LETSENCRYPT_EMAIL" -d "$SINK_HOSTNAME"
   ```
   > Manual issuance does **not** auto-renew — you'll repeat the TXT step every ~60
   > days. Prefer a provider plugin for anything long-lived.

**Wiring it into the deployment.** Obtain the cert with one of the above *before* (or
instead of) the certbot step in `setup.sh`, so the cert already exists at
`/etc/letsencrypt/live/$SINK_HOSTNAME/`. `setup.sh` detects an existing cert
(`if [ -f "${LE_LIVE}/fullchain.pem" ]`) and skips fresh issuance, then copies it
into `/etc/rsyslog.d/tls/` and installs the same renewal deploy hook. So the rest of
the pipeline (rsyslog config, DO panel, blank CA field) is **identical** — only the
challenge type differs. Everything else in this runbook applies unchanged.

---

## Step 4 — Deploy the sink Droplet

From this repo directory on your local machine:

```bash
# Copy repo to droplet (clears stale directory first so re-runs don't nest)
ssh root@<SINK_IP> "rm -rf /tmp/sink-setup"
scp -r . root@<SINK_IP>:/tmp/sink-setup

# SSH in and run setup
ssh root@<SINK_IP> "cd /tmp/sink-setup && bash setup.sh"
```

`setup.sh` does the following automatically:
1. Creates a dedicated `mysqlsink` service user and `/var/log/mysql_sink/{bin,incoming,processed}` with least-privilege ownership (`750`).
2. Deploys `transform_logs.py` to the bin directory.
3. Installs `rsyslog-gnutls`, deploys the CA + sink server cert, and configures rsyslog to receive **mutual-TLS** syslog on port 6514 (rejecting any sender without a CA-signed client cert).
4. Installs `socat` and creates a systemd service proxying `127.0.0.1:25060` → the DO managed DB host (PMM needs a local-looking host to enable slowlog parsing).
5. Installs and starts `slow-query-sink.service` (replaces the old per-minute cron job).
6. Configures logrotate (daily, 14-day retention for processed log; daily, 3-day retention for incoming log with rsyslog HUP postrotate).
7. Installs `pmm-client` via the Percona apt repository (skipped if already installed).
8. Registers the node with the PMM server.
9. Queries the DB to find the `slow_query_log_file` path and creates a symlink pointing it at the processed log.
10. Registers the MySQL service in PMM with `--query-source=slowlog`.

---

## Step 5 — Verify

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

# Confirm the symlink is correct — pulls creds from .env automatically (no more
# hand-editing <DB_PASS> into a printf), and prints the REAL mysql error on
# failure instead of silently returning nothing.
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
- Navigate to **QAN** — queries should appear within seconds of slow queries being generated (no longer a 1-minute batch delay).

**Generate test slow queries** (optional, uses `test_prepared_statements.py`):
```bash
pip install mysql-connector-python
python3 test_prepared_statements.py
```

---

## Re-deploying after a DB replacement

When the managed DB cluster is replaced (new hostname or password):

1. In the DO control panel: update the syslog destination to point to the same sink droplet IP (it may have been reset).
2. Create the `pmm_monitor` user on the new DB.
3. Update `.env` with the new `DB_HOST` and `DB_PASS`.
4. Re-run from your local machine:
   ```bash
   scp -r . root@<SINK_IP>:/tmp/sink-setup/
   ssh root@<SINK_IP> "cd /tmp/sink-setup && bash setup.sh"
   ```
   The script is idempotent — it updates the socat service target, recreates the symlink, and re-registers PMM (using `--force` if the node name already exists).

---

## Re-deploying to a new sink Droplet (existing PMM server)

1. Provision a new Ubuntu droplet.
2. Update `SINK_IP` in `.env`, and repoint `SINK_HOSTNAME`'s DNS A record at the new droplet IP (keep the same hostname if you can — then DO's forwarding config needs no change).
3. Copy repo and run `setup.sh` exactly as in Step 4. It obtains a Let's Encrypt cert for `SINK_HOSTNAME` automatically (HTTP-01 needs port 80 reachable and the A record pointing here).
4. If you kept the same `SINK_HOSTNAME`, DO's destination and cert fields need no change. If the hostname changed, update the DO syslog destination to the new name. The CA cert and client cert/key in DO's panel stay the same — no need to re-run `gen-certs.sh` unless you want to rotate the client cert.
5. Open ports 6514/tcp (syslog) and 80/tcp (ACME) inbound in the new droplet's firewall if one is configured.

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
| `combined_mysql.log` not growing | rsyslog TLS listener — `ss -tlnp \| grep 6514`; firewall — `ufw status` (allow 6514/tcp); TLS handshake/cert errors — `journalctl -u rsyslog -n 50` (cert mismatch, expired, or wrong CA in DO panel); confirm DO log forwarding has TLS enabled with the certs from `gen-certs.sh` |
| `combined_mysql.log` has data but no `[SlowQuery]` lines | `log_output` is not set to `INSIGHTS` — change in DO advanced config (DO's abstraction for `FILE`; `TABLE` does not forward via syslog) |
| `native_slow_query.log` empty after daemon runs | Check `combined_mysql.log` for `[SlowQuery]` lines — slow query log may not be enabled in DO settings |
| Daemon not running | `systemctl status slow-query-sink` and `journalctl -u slow-query-sink -n 50` |
| "Discarding stale incomplete block" in daemon logs | A multi-line slow query block arrived with missing lines — likely a transient rsyslog drop; normal at low frequency |
| PMM agents not Running | `journalctl -u pmm-agent -n 50`; verify `PMM_TOKEN` is valid; check PMM server is reachable on port 443 |
| QAN shows no data | Confirm symlink resolves: `readlink -f <slow_query_log_file path>`; confirm `mysql_slowlog_agent` is Running in `pmm-admin list` |
| `socat-mysql-proxy` fails to start | Check `DB_HOST` and `DB_PORT` in `/etc/systemd/system/socat-mysql-proxy.service`; test connectivity: `nc -zv <DB_HOST> 25060` |
| `setup.sh`'s DB preflight/probe fails, or `verify-slow-log.sh` errors | Read the printed checklist (from `mysql_probe` in `common.sh`) — most common cause is the sink Droplet not being in the DB cluster's **Trusted Sources** (Databases → cluster → Settings → Trusted Sources); DO drops the connection with no error visible on this end. Also check the socat proxy (`systemctl status socat-mysql-proxy`), credentials in `.env`, and that the CA cert matches this exact cluster. `setup.sh`'s DB preflight happens before socat exists; `bash verify-slow-log.sh --direct` lets you test the same thing later, bypassing the proxy |
| `pmm-admin config` returns "node already exists" | `setup.sh` uses `--force` by default, so re-running the script handles this automatically |
| Node + agents exist in PMM but no service | `setup.sh` registers the service last; if it exited earlier (e.g. the DB preflight/probe failed), the node/agents from `pmm-admin config` are left orphaned. Fix the earlier failure and re-run `setup.sh` — it's idempotent and will pick up from where it left off. To fully reset first, use `destruct.sh` (below) |
| rsyslog silent failure (action suspended/resumed loop) | `/var/log/mysql_sink` ownership must be `syslog:adm` mode `775` — root ownership breaks rsyslog writes |

---

## Key files in this repo

| Path | Purpose |
|------|---------|
| `common.sh` | Shared helper library — `mysql_probe()`, used by `setup.sh`, `verify-slow-log.sh`, and `destruct.sh` so DB-connection failures always surface the real error + a troubleshooting checklist instead of being swallowed |
| `verify-slow-log.sh` | Step 5 verification, automated — resolves `slow_query_log_file` and checks the symlink. Supports `--direct` to bypass the socat proxy |
| `destruct.sh` | Tears down everything `setup.sh` created (PMM node/service/agents, systemd units, rsyslog config, log dirs, symlink) so a re-run of `setup.sh` starts clean. See "Tearing down / starting over" above |

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
