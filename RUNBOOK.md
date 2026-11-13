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
| **PMM Server Droplet** | **Ubuntu 22.04, 24.04 or 26.04 LTS** — see "Supported OS versions" below. Minimum 4 GB RAM (8 GB recommended). Must be provisioned and reachable before running `setup.sh`. Note DigitalOcean offers [a prebuilt Marketplace Droplet to make this deployment easier](https://marketplace.digitalocean.com/apps/percona-monitoring-and-management) |
| **Sink Droplet** | **Ubuntu 22.04, 24.04 or 26.04 LTS** — see "Supported OS versions" below. Any size (required size based on database query load; can upscale the Droplet later if initial size guess is too small or weak). This is where `setup.sh` runs. |
| **DNS hostname for the sink** | A public DNS **A record** pointing at the sink Droplet's IP (e.g. `logs.example.com → <SINK_IP>`). Required — the sink presents a Let's Encrypt cert for this name, and certbot's HTTP-01 challenge needs it to resolve here. No domain handy? `<IP-dashed>.sslip.io` works for testing. |
| **DO Managed MySQL** | Slow query log must be enabled in the DO control panel (Database → Settings → Slow query log). |
| **`pmm_monitor` DB user** | Create via DO control panel (Database → Users). DO grants appropriate access by default — no additional `GRANT` statements needed. |
| **`.env` file** | Fill in all fields (see below) before running `setup.sh`. |

### Supported OS versions

**Ubuntu 22.04 LTS, 24.04 LTS and 26.04 LTS.** These are the Ubuntu releases
Percona's `pmm3-client` apt repository publishes `pmm-client` for (`jammy`,
`noble`, `resolute`) — `setup.sh` installs it from there via `percona-release`
with no manual repo edits. The full pipeline has been validated end to end on
24.04 and 26.04 (pmm-client 3.10.0, November 2026). Percona's own docs only
say "Ubuntu Server LTS" without listing versions, so if a future Ubuntu
release appears, check for its codename under
`https://repo.percona.com/pmm3-client/apt/dists/` before using it.

`setup.sh` prints a warning (not a hard stop) on any other version, so
existing test boxes aren't locked out — but don't deploy a real integration
on one: getting `pmm-client` onto it means pointing `apt` at another release's
repo, which is unverified and can break silently on any Percona-side update.

---

## Step 1 — Provision and configure the PMM Server Droplet

SSH into the new PMM server droplet and run the Percona easy-install script (NOTE- this can be skipped if you used the [DO Marketplace PMM deployment](https://marketplace.digitalocean.com/apps/percona-monitoring-and-management)):

```bash
curl -fsSL https://www.percona.com/get/pmm | bash
```

This installs Docker and starts the PMM server container automatically. Wait ~60 seconds for it to finish initializing.

**Getting an API token — two options.** Either way, use **one service account
and token per sink Droplet**, so each sink can be revoked on its own without
touching the others (see "Monitoring multiple Managed MySQL endpoints" below).

- **Automatic (recommended for a fresh install):** leave `PMM_TOKEN` blank in
  `.env`. `setup.sh` checks whether `PMM_SERVER` is reachable; if it is and
  nobody has logged into the PMM UI yet (still on the default `admin`/`admin`
  password), it creates an Admin-role service account named
  `sink-<PMM_NODE_NAME>` (reusing it if it already exists), mints a token for
  it via the PMM API, and writes it into this sink's `.env`. If `PMM_SERVER`
  isn't reachable yet, `setup.sh` prints this install command and exits so you
  can run it, then re-run `setup.sh`.
- **Manual:**
  1. Open `https://<PMM_SERVER_IP>` in a browser (accept the self-signed cert warning).
  2. Log in with `admin` / `admin`.
  3. You will be prompted to change the password — do so.
  4. Go to **Administration → Users and access → Service Accounts → Add
     service account**. Name: `sink-<node name>` (e.g. `sink-prod-primary`) —
     one per sink. Role: **Admin**.
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
git clone https://github.com/DO-Solutions/slow-logs-custom-sync-pmm.git
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

# Where setup.sh INSTALLS the DO Managed DB CA cert on this Droplet (default is
# fine — leave this line out unless you need a non-default path). Do NOT put the
# downloaded cert here yourself: paste it into certs/do-ca.crt instead (below) —
# setup.sh copies it from there to this path automatically.
# DO_CA_BUNDLE=/etc/mysql_sink/do-ca.crt

# Optional — PMM identity and labels. With a single sink you can leave these
# out (defaults: service "do-managed-mysql", node = this Droplet's hostname).
# With more than one sink on the same PMM Server, PMM_SERVICE_NAME and the node
# name MUST be unique per sink — see "Monitoring multiple Managed MySQL
# endpoints with one PMM Server" below.
# PMM_SERVICE_NAME=prod-primary
# PMM_NODE_NAME=sink-prod-primary
# PMM_ENVIRONMENT=production
# PMM_CLUSTER=prod
# PMM_REPLICATION_SET=prod
# PMM_CUSTOM_LABELS=role=primary
```

`env.example` lists every key with comments (including `LOCAL_PROXY_PORT` and
`PMM_FORCE_REREGISTER`); `setup.sh` validates them before changing anything
and stops with a clear message on an invalid value.

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
> Like `certs/ca.pem`, this file is gitignored and never travels via git. It's
> referred to as `DO_CA_SRC` internally (default `certs/do-ca.crt`, no need to
> set it explicitly in `.env`) to distinguish it from `DO_CA_BUNDLE` above —
> `setup.sh` reads the cert from here (`DO_CA_SRC`) and installs a copy to
> `DO_CA_BUNDLE`, and the DB-credential probe verifies the DB cert chain
> against it (`ssl-mode=VERIFY_CA`).

---

## Step 4 — Configure DO Managed DB

### Advanced Configuration

In the DO control panel, go to [**Databases → your cluster → Settings → Advanced Configuration**](https://docs.digitalocean.com/products/databases/mysql/how-to/reconfigure/#update-a-databases-configuration-using-the-control-panel) and set:

| Setting | Value | Notes |
|---------|-------|-------|
| `slow_query_log` | `on` | Enables slow query logging |
| `log_output` | `LOGS` | **Required** — DO's abstraction for MySQL's `FILE`; with `TABLE`, slow queries are not forwarded via syslog. DO renamed this value: it used to be `INSIGHTS`, and the API now rejects `INSIGHTS` — if your control panel still shows `INSIGHTS`, it's the same setting. **Toggle bug:** on a cluster where this has never been changed, DO can report `LOGS` while MySQL is actually still on `TABLE` (reproduced November 2026 on a brand-new cluster). Set it to `TABLE`, save, then back to `LOGS`, save again. Verify with `SELECT @@log_output;` — you want `FILE`, not `TABLE` |
| `long_query_time` | `0.1` | The lowest value DO accepts — see below. (Earlier versions of this runbook said `0`; DO's API now rejects anything below `0.1` with an HTTP 500, even though its published API spec allows `0`.) |

Save and wait ~30 seconds for the settings to apply. `bash diagnose.sh`
(Step 6) checks all three on the live DB.

> **What `long_query_time = 0.1` means for what you'll see in QAN.** MySQL
> writes a statement to the slow log only if it takes at least
> `long_query_time` seconds to execute, and the slow log is this pipeline's
> only data source for QAN. So, for the PMM service this pipeline registers:
>
> - **Only statements taking ≥ 100 ms appear in QAN.** That applies to
>   prepared statements too: a prepared statement that runs in 5 ms is just
>   as invisible as a 5 ms plain query. This pipeline answers "which
>   prepared (and other) statements are slow?", not "what is my whole
>   workload doing?".
> - **QAN's counts, load and "% of total time" describe the slow subset only.**
>   A query that runs thousands of times a second at 2 ms each — often the
>   largest share of real load — won't show up at all, so rankings are biased
>   toward slow outliers. Don't read QAN here as a complete workload profile.
> - **Server-level metrics are unaffected.** The MySQL dashboards fed by
>   `mysqld_exporter` (QPS, connections, InnoDB, etc.) still cover all traffic;
>   only per-query QAN detail is thresholded.
> - **Lower is not available, higher is a valid choice.** Every logged
>   statement flows through DO's log forwarder, the sink and PMM, so a higher
>   threshold (e.g. `0.5` or `1`) cuts that volume on a very busy database,
>   at the cost of even less coverage. `diagnose.sh` warns about anything
>   above `0.1` so a higher value is a deliberate choice, not an accident.

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
6. Registers the node with PMM Server — after a read-only preflight (before
   anything is changed) that a PMM node with this name isn't another
   machine's and the service name isn't already used by another node. If this
   Droplet is already registered and connected under that name, the node
   registration is left as is.
7. Queries the DB for its `slow_query_log_file` path and symlinks it to the processed log, and installs `mysql-sink-reconcile.timer`, which re-checks that path every minute and adds the symlink when it changes — DO's path embeds the serving node's hostname, so it changes on every primary failover (see Troubleshooting).
8. Registers the MySQL service (`PMM_SERVICE_NAME`) in PMM with `--query-source=slowlog` and any labels set in `.env`, and verifies it actually appears in `pmm-admin list`.

It's idempotent — safe to re-run after fixing a config issue, and after a
`git pull` to pick up fixes: a re-run restarts `slow-query-sink` and the
`socat` proxy so they run the new code/config, keeps the existing PMM node
(same node ID), and re-registers the MySQL service under the same name so it
picks up the current `.env` (e.g. a new `DB_PASS` after a DB replacement, or
changed labels). QAN history stays available under the service name; the
service's PMM ID changes. To force a full node re-registration (e.g. after
rotating `PMM_TOKEN` while the old token still works), run
`PMM_FORCE_REREGISTER=1 bash setup.sh`.

It also disables PMM's own built-in slow-log rotation for the service and
leaves rotation to the sink's logrotate config. PMM's rotation renames
`slow_query_log_file` and expects `mysqld` to recreate it, which can't happen
here — it would rename our symlink away and silently stop QAN (see
Troubleshooting).

---

## Step 6 — Verify

**Start here — run the full pipeline health check:**

```bash
bash diagnose.sh              # via the socat proxy — what pmm-agent actually uses
bash diagnose.sh --direct     # DB stage bypasses the proxy — isolates proxy vs. DB/firewall
```

`diagnose.sh` walks every stage of the pipeline in order — DB slow-query config,
rsyslog service/listener/certs, recent rsyslog TLS errors, firewall, whether the
incoming syslog file exists and is actually growing, the sink daemon, the
symlink + target file, and the PMM agent status — and prints a clear PASS/WARN/FAIL
for each with specific remediation. **Read failures top to bottom**: a FAIL early
on (e.g. rsyslog not listening) is very often the real cause of everything that
looks broken further down (e.g. no incoming file, daemon parked waiting, PMM
agent stuck on `Waiting`), not a separate problem to chase individually. This is
also the tool to reach for if individual checks look OK but something still
doesn't add up — e.g. the symlink resolving correctly is not proof that any data
has ever arrived; `diagnose.sh` checks both, and `verify-slow-log.sh` (which it
calls internally) checks the target file's actual existence, not just the
symlink path.

Manual/targeted checks, if you want to dig into one specific stage yourself:

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

# Confirm the symlink AND its target file are correct — pulls creds from .env
# automatically, and prints the REAL mysql error on failure instead of
# silently returning nothing.
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
- Navigate to **QAN** and select this sink's service — `PMM_SERVICE_NAME` from `.env`, `do-managed-mysql` if you didn't set one. See the note below on ingestion lag before assuming something's broken.

**Generate test prepared statements** (optional, uses `test_prepared_statements.py` — this
is what actually exercises the reason this whole pipeline exists: prepared
statements, which `performance_schema` QAN cannot see, but slow-log QAN can):
```bash
apt-get install -y python3-venv
python3 -m venv .venv                          # in the repo dir; .venv/ is gitignored
.venv/bin/pip install mysql-connector-python   # current connector from PyPI
set -a; source .env; set +a                    # exposes DB_PASS from .env into this shell
.venv/bin/python test_prepared_statements.py "${DB_PASS}"
```
(The script also accepts `DB_PASS=... .venv/bin/python test_prepared_statements.py`
with no positional arg. Either way, a password is required — running it with
neither just prints its `Usage:` message and exits.)

> **Use the venv, not Ubuntu's `python3-mysql.connector` package.** On Ubuntu
> 24.04 the apt package is connector 8.0.15, which calls `ssl.wrap_socket()` —
> removed in the Python 3.12 that 24.04 ships — so it fails on connect with
> `AttributeError: module 'ssl' has no attribute 'wrap_socket'` (the script
> detects this and prints these instructions). On 26.04 the apt package is
> 9.5.0 and works, but the venv route above works on every supported release
> and doesn't touch system packages, so it's the one to use. (Older versions of
> this runbook used `pip3 install --break-system-packages`; that also works,
> but mixes a PyPI package into the system Python.)

> **QAN can lag behind the slow log by a minute or so.** The sink daemon
> (`transform_logs.py`) writes to `native_slow_query.log` as soon as each entry
> is complete (for the very last query before the DB goes quiet, that's up to
> ~30 s, since nothing else signals that its entry is finished), but PMM's
> own QAN ingestion/aggregation pipeline has its own polling interval on top of
> that. If `grep` finds your test query in `native_slow_query.log` but QAN hasn't
> shown it yet, wait a bit before assuming something's broken.

---

## Monitoring multiple Managed MySQL endpoints with one PMM Server

Example: a Standard cluster `prod-primary` and its read-only replica
`prod-replica`, both reporting to one PMM Server so they can be compared side
by side. This is configuration only — no source edits on any sink.

**One sink Droplet per endpoint, always.** An endpoint is a DO database
resource with its own hostname and its own Log Forwarding destination: a
cluster (its primary and any standby nodes forward together, to one sink), or
a read-only replica. Each endpoint gets its own sink Droplet, running this
repo with its own `.env`. All sinks point at the same `PMM_SERVER`. Standby
nodes need nothing extra.

Don't point two endpoints' Log Forwarding at the same sink. A sink has one
ingest stream and one reconstructed log, so the second endpoint's slow queries
would show up in QAN under the first endpoint's service.

### What must be unique per sink

PMM requires unique service names, and `pmm-admin config --force` replaces any
node with the same name, so each sink needs:

- **its own `PMM_SERVICE_NAME`** — what you'll pick in QAN (e.g. `prod-primary`,
  `prod-replica`). Leaving two sinks on the default `do-managed-mysql` doesn't work:
  the second `setup.sh` stops with "PMM service name … is already used by another node".
- **its own node name** — distinct Droplet hostnames are enough, or set
  `PMM_NODE_NAME` explicitly (e.g. `sink-prod-primary`). If two sinks end up with
  the same node name, the second `setup.sh` stops instead of silently removing
  the first one's registration ("… already exists and is NOT this machine's").
- **its own PMM token** — one service account per sink (`sink-<node name>`;
  auto-mint does this for you on a fresh PMM), so each sink can be revoked
  without touching the others.
- **its own mTLS CA and client cert** (`gen-certs.sh` on each sink), its own
  `SINK_HOSTNAME`, and its own Let's Encrypt cert — exactly as for a single sink.

### Worksheet

| Value | `prod-primary` sink | `prod-replica` sink | Same or different? |
|---|---|---|---|
| `DB_HOST` | the cluster's host | the replica's host (Connection Details of the replica) | **different** |
| `DB_PORT` | `25060` | `25060` | same |
| `PMM_MONITOR_USER` / `DB_PASS` | `pmm_monitor` / its password | same user and password (users replicate — see below) | same |
| `certs/do-ca.crt` | the cluster's CA | the replica's CA — identical to the cluster's in testing (one CA per DO project) | same |
| `SINK_IP`, `SINK_HOSTNAME` | sink A's | sink B's | **different** |
| `certs/` from `gen-certs.sh` | generated on sink A | generated on sink B | **different** |
| `PMM_SERVER` | PMM Server | PMM Server | same |
| `PMM_TOKEN` | token of `sink-prod-primary` | token of `sink-prod-replica` | **different** |
| `PMM_SERVICE_NAME` | `prod-primary` | `prod-replica` | **different** |
| `PMM_NODE_NAME` (or hostname) | `sink-prod-primary` | `sink-prod-replica` | **different** |
| `PMM_ENVIRONMENT`, `PMM_CLUSTER`, `PMM_REPLICATION_SET` | e.g. `production`, `prod`, `prod` | same values | same (that's what groups them) |
| `PMM_CUSTOM_LABELS` | `role=primary` | `role=replica` | **different** |
| DO Log Forwarding destination | configured **on the cluster** → sink A's hostname | configured **on the replica** → sink B's hostname | **different** |
| DO Trusted Sources | the cluster's list must include sink A | the replica's list must include sink B | **different** (per endpoint) |

### Steps for each additional sink

1. Provision the Droplet and do Steps 2–3 on it, with that endpoint's
   `DB_HOST`, unique `PMM_SERVICE_NAME`/node name, and labels.
2. Step 4 **on that endpoint**: check its Advanced Configuration, and add a Log
   Forwarding destination on that endpoint pointing at **this** sink's
   `SINK_HOSTNAME`, with **this** sink's `gen-certs.sh` client cert/key. Add this
   sink to that endpoint's Trusted Sources.
3. Step 5 (`bash setup.sh`) and Step 6 (`bash diagnose.sh`) on this sink.

### Labels: grouping and comparing endpoints

`PMM_ENVIRONMENT`, `PMM_CLUSTER`, `PMM_REPLICATION_SET` and `PMM_CUSTOM_LABELS`
(`key=value,key=value`) are passed to `pmm-admin add mysql` only when set, and
show up as filters in QAN and on the dashboards. Give endpoints that belong
together the same cluster/replication set, and tell them apart with a custom
label such as `role=primary` / `role=replica`. The same works for an
old-versus-new comparison — e.g. label Standard-edition endpoints
`edition=standard` and whatever else reports to the same PMM Server
`edition=advanced`. (Advanced Edition clusters report to PMM directly via DO's
managed PMM client and don't need a sink.) Changing a label in `.env` takes
effect on the next `bash setup.sh`, which re-registers the service.

### Read-only replica notes

Verified on a DO Managed MySQL 8.4 Standard cluster with a read-only replica
(November 2026):

- **`pmm_monitor` is created on the primary and replicates.** The same user and
  password work on the replica — don't create it there (the replica is
  read-only: writes fail with `ERROR 1290 … --read-only`).
- **A replica is its own endpoint in DO.** It has its own Trusted Sources,
  Advanced Configuration and Log Forwarding. When the replica was created, its
  Trusted Sources and Advanced Configuration (`slow_query_log`,
  `long_query_time`, `log_output`) were **copied** from the primary, but **Log
  Forwarding was not** — the replica starts with no destination, and gets its
  own. They're copies, not links: a Trusted Source added to the primary later
  did **not** appear on the replica (tested), so add each sink to the Trusted
  Sources of the endpoint it monitors. Likewise check the replica's own
  Advanced Configuration, and confirm on the replica DB itself that
  `SELECT @@slow_query_log, @@log_output, @@long_query_time;` gives `1`,
  `FILE`, `0.100000` (`diagnose.sh` on the replica's sink checks this).
- **Same CA.** The replica's CA certificate was identical to the primary's
  (DO issues one CA per project), so the same `certs/do-ca.crt` works.
- **Each endpoint reports its own slow-log path** (it embeds the node's
  hostname, e.g. `…/<cluster>-1-slow.log` vs `…/<replica>-1-slow.log`), so
  sinks never collide on it.
- **`test_prepared_statements.py` only runs `SELECT`s**, so it's safe to run
  on the replica's sink.

---

## Re-deploying after a DB replacement

When the managed DB cluster is replaced (new hostname or password):

1. In the DO control panel: update the syslog destination to point to the same sink droplet IP (it may have been reset).
2. Create the `pmm_monitor` user on the new DB.
3. On the sink Droplet, update `.env` with the new `DB_HOST` and `DB_PASS`.
4. On the sink Droplet: `bash setup.sh`.

The script is idempotent — it re-points and restarts the socat proxy at the new `DB_HOST`, recreates the symlink (the new cluster reports a different `slow_query_log_file` path), and re-registers the MySQL service in PMM with the new credentials (the node registration is kept).

---

## Re-deploying to a new sink Droplet (existing PMM server)

This is a single, non-HA Droplet by design (see
[docs/architecture.md](docs/architecture.md)) — there's no standby to fail
over to, so replacing it means standing up a fresh one from scratch and
re-pointing DO at it. Because `gen-certs.sh` runs per-Droplet, the new
Droplet mints its **own new CA and client cert** — DO's Log Forwarding panel
needs updating, it isn't a no-op this time:

1. Provision a new Ubuntu droplet (22.04, 24.04 or 26.04 LTS).
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
   A record pointing here). If the new Droplet ends up with the **same node
   name** as the old one (same hostname, or the same `PMM_NODE_NAME`) and the
   old node is still registered in PMM, `setup.sh` stops rather than replace a
   node it can't prove is its own. Either remove the old one first
   (`bash destruct.sh` on the old Droplet, or delete the node in PMM's
   Inventory), or — once you're sure the old Droplet is gone — re-run with
   `PMM_FORCE_REREGISTER=1 bash setup.sh`.
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

It removes, in order: this sink's PMM service (`PMM_SERVICE_NAME`, default `do-managed-mysql`), this node's PMM
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

**Run `bash diagnose.sh` first.** It checks the whole pipeline end to end in one
pass and will usually point straight at which of the rows below actually
applies, rather than you needing to guess from the symptom alone.

| Symptom | Check |
|---------|-------|
| `combined_mysql.log` doesn't exist at all, or exists but isn't growing | No data has ever arrived from DO (or hasn't recently). Check, in order: rsyslog is actually running — `systemctl status rsyslog`; it's listening — `ss -tlnp \| grep 6514`; firewall — `ufw status` (allow 6514/tcp); TLS handshake/cert errors, or a total absence of connection attempts — `journalctl -u rsyslog -n 100` (cert mismatch, expired, or wrong CA in DO panel; no attempts at all usually means DO's Log Forwarding config wasn't actually saved correctly); confirm DO's Log Forwarding destination has TLS enabled AND that **Show advanced configuration options** was expanded with Client key/Client certificate actually pasted in — it's collapsed by default and easy to miss (see Step 4) |
| `combined_mysql.log` has data but no `[SlowQuery]` lines | `log_output` is not set to `LOGS` (formerly `INSIGHTS`) — change in DO advanced config (DO's abstraction for `FILE`; `TABLE` does not forward via syslog). Check `SELECT @@log_output;` returns `FILE`, and see the toggle-bug note in Step 4 |
| Setting `long_query_time` to `0` (or anything below `0.1`) fails — HTTP 500 / "Server Error" from the DO API or control panel | Expected: DO currently rejects values below `0.1`. Use `0.1` — see Step 4 for what that threshold means for QAN |
| A query you ran doesn't show up in `native_slow_query.log` or QAN at all (not just late) | Did it take at least `long_query_time` (normally 0.1 s) to execute? Faster statements are never written to the slow log — see Step 4. `test_prepared_statements.py` uses `SLEEP()` to stay well above the threshold |
| `native_slow_query.log` doesn't exist, even though `slow-query-sink.service` shows `active (running)` | **Expected, not a bug**, if `combined_mysql.log` doesn't exist yet: `transform_logs.py` blocks waiting to open `combined_mysql.log` before it ever creates/opens `native_slow_query.log`, and that blocking wait is not a crash — systemd will show the service as `active (running)` the whole time. Don't chase the daemon here; fix why `combined_mysql.log` is missing (row above), and this resolves itself. `bash verify-slow-log.sh` checks for exactly this and will say so explicitly rather than giving a false "OK" |
| `native_slow_query.log` empty after daemon runs (but `combined_mysql.log` is growing) | Check `combined_mysql.log` for `[SlowQuery]` lines — slow query log may not be enabled in DO settings |
| Daemon not running | `systemctl status slow-query-sink` and `journalctl -u slow-query-sink -n 50` |
| "Discarding stale incomplete block" in daemon logs | A multi-line slow query block arrived with missing lines — likely a transient rsyslog drop; normal at low frequency. (Older versions of `transform_logs.py` also logged this for the last, *complete* query before every quiet period — and dropped it — and logged every host as `host=unknown`. If you see `host=unknown`, you're on old code: `git pull && bash setup.sh`.) |
| "Dropping input: finalized block has gaps" in daemon logs | A slow query's lines didn't all reach the sink, so it was left out rather than written half-built. `occurrences=` is the running count since the daemon started; each reason is logged at most once a minute. Older versions of `transform_logs.py` caused this themselves: they could read a line rsyslog was still writing and lose it (on the test sinks, one slow query every 5–10 hours; how often depends on traffic). They also logged only the 1st and every 1000th drop, so most went unseen. Fix: `git pull && bash setup.sh`. On current code, an occasional occurrence means lines really were missing from the forwarded stream |
| `diagnose.sh` warns about rsyslog TLS errors such as `http request`, `Handshake failed`, or a remote like `*.shodan.io` | Port 6514 is open to the internet, so scanners connect to it; mutual TLS rejects them and rsyslog logs the failed handshake. That's harmless noise when stage 7 shows data arriving. A handshake failure from DO itself shows up as no data arriving at all (see the `combined_mysql.log` row above) |
| QAN worked for about a day, then stopped; `native_slow_query.log` is empty or tiny while `native_slow_query.log.1` keeps growing | Old `transform_logs.py`: it never reopened its output after logrotate's daily rotation, so it kept writing to the rotated file while PMM read the new, empty one. `diagnose.sh` stage 8 reports "daemon is writing to '…log.1'". Fix: `git pull && bash setup.sh` (it restarts the daemon on the new code) |
| QAN stopped; the `slow_query_log_file` symlink is gone but `<that path>.old` exists; `journalctl -u pmm-agent` repeats `Failed to stat … no such file or directory` while `pmm-admin list` still shows `mysql_slowlog_agent Running` | PMM's own slow-log rotation fired (default limit 1 GiB): it renames the slow-log path to `.old` and expects `mysqld` to recreate it, which can't happen here. Fix: `git pull && bash setup.sh` — it recreates the symlink, removes the stale `.old`, and sets the service's PMM-side rotation limit to 0 (disabled). `diagnose.sh` and `verify-slow-log.sh` both detect this state |
| QAN stopped right after a DB failover, maintenance or resize; `pmm-admin list` shows the slowlog agent `Waiting`; `verify-slow-log.sh` says the `slow_query_log_file` path doesn't exist | Expected for up to ~1 minute. DO's `slow_query_log_file` embeds the serving node's hostname (`…/<cluster>-<n>-slow.log`), and a failover — or a resize, which replaces nodes — moves the primary to a node with a different `<n>` (observed: `-1` → `-4`). `mysql-sink-reconcile.timer` notices within a minute and adds the symlink at the new path; the slowlog agent resumes by itself. If it doesn't: `systemctl status mysql-sink-reconcile.timer` and `journalctl -u mysql-sink-reconcile -n 20`; on sinks set up before the timer existed, `git pull && bash setup.sh` installs it (and fixes the path right away) |
| `./gen-certs.sh: Permission denied` | Your clone predates the scripts being marked executable in git. Run `bash gen-certs.sh` (or `git pull`) |
| `test_prepared_statements.py` fails with `AttributeError: module 'ssl' has no attribute 'wrap_socket'` | You're using Ubuntu 24.04's apt `python3-mysql.connector` (8.0.15), which doesn't work on Python 3.12. Use the venv from Step 6 instead |
| `mysql_probe`/`setup.sh` preflight fails with `ERROR 1045 Access denied` | Networking is fine (you got a real MySQL auth response, not a timeout) — this is a credentials issue. Check `DB_PASS` in `.env` matches the current `pmm_monitor` password exactly; if `.env` was ever edited on Windows, check for a stray trailing `\r` (`cat -A .env \| grep DB_PASS` — a `^M` before the line end means CRLF snuck in and is silently corrupting the password when bash sources it: fix with `sed -i 's/\r$//' .env`). Also confirm `pmm_monitor` actually exists on *this* DB cluster, not a previous one. |
| PMM agents not Running | `journalctl -u pmm-agent -n 50`; verify `PMM_TOKEN` is valid; check PMM server is reachable on port 443 |
| QAN shows no data | First check whether it's just lagging: `grep` the query text in `/var/log/mysql_sink/processed/native_slow_query.log` — if it's there, QAN's own ingestion has a polling delay on top of the sink's real-time write, give it a minute or two. If it's genuinely absent: run `bash verify-slow-log.sh` — it checks both the symlink path AND that the target file actually exists (`readlink -f` alone will resolve a path even if nothing exists there, which reads as "correct" when it isn't); confirm `mysql_slowlog_agent` is Running in `pmm-admin list` |
| `socat-mysql-proxy` fails to start | Check `DB_HOST` and `DB_PORT` in `/etc/systemd/system/socat-mysql-proxy.service`; test connectivity: `nc -zv <DB_HOST> 25060` |
| `setup.sh`'s DB preflight/probe fails outright (no connection), or `verify-slow-log.sh` errors | Read the printed checklist (from `mysql_probe` in `common.sh`) — most common cause is the sink Droplet not being in the DB cluster's **Trusted Sources** (Databases → cluster → Settings → Trusted Sources); DO drops the connection with no error visible on this end. Also check the socat proxy (`systemctl status socat-mysql-proxy`), credentials in `.env`, and that the CA cert matches this exact cluster. `bash verify-slow-log.sh --direct` bypasses the proxy to isolate proxy vs. DB/firewall |
| `mysql: command not found` (from `common.sh`'s `mysql_probe`, right at the start of `setup.sh`) | Expected to self-heal: `mysql_probe` auto-installs `default-mysql-client` via `apt-get` the first time it's needed, since a fresh Droplet doesn't ship a MySQL client and the preflight check runs before `setup.sh`'s own package-install step. If you still see this, either you're on an old copy of `common.sh` (`git pull` and re-run), you're not running as root (apt-get install needs root), or the Droplet has no working internet/apt access — install it yourself with `apt-get install -y default-mysql-client` and re-run |
| `setup.sh` stops with "a PMM node named '…' already exists and is NOT this machine's" | Another machine (usually another sink with the same hostname) is registered under this node name. Registering would run `pmm-admin config --force`, which removes that node with all its services and agents — so `setup.sh` refuses. Set a unique `PMM_NODE_NAME` in `.env`; or, if that node is stale (its Droplet was deleted), re-run with `PMM_FORCE_REREGISTER=1` |
| `setup.sh` stops with "PMM service name '…' is already used by another node" | PMM service names are unique per PMM Server and another sink already uses this one (often both are on the default `do-managed-mysql`). Set a unique `PMM_SERVICE_NAME` in `.env` — see "Monitoring multiple Managed MySQL endpoints with one PMM Server" |
| Node + agents exist in PMM but no service | `setup.sh` registers the service last; if it exited earlier (e.g. the DB preflight/probe failed), the node/agents from `pmm-admin config` are left orphaned. Fix the earlier failure and re-run `setup.sh` — it's idempotent and will pick up from where it left off. To fully reset first, use `destruct.sh` above |
| rsyslog silent failure (action suspended/resumed loop) | `/var/log/mysql_sink` and `/var/log/mysql_sink/incoming` must be owned `syslog:adm` (mode `750`, as `setup.sh` sets them) — root ownership breaks rsyslog writes. Re-run `setup.sh` to restore ownership |

---

## Key files in this repo

| Path | Purpose |
|------|---------|
| `common.sh` | Shared helper library — `mysql_probe()` (auto-installs a MySQL client on first use if one isn't present), used by `setup.sh`, `verify-slow-log.sh`, `diagnose.sh`, and `destruct.sh` so DB-connection failures always surface the real error + a troubleshooting checklist instead of being swallowed |
| `gen-certs.sh` | Generates the private CA and DO client cert/key for mutual-TLS log forwarding. Run once on the sink Droplet, before `setup.sh`; prints the exact values to paste into DO's Log Forwarding panel |
| `setup.sh` | Main install script — see Step 5 above |
| `diagnose.sh` | End-to-end pipeline health check — DB config, rsyslog service/listener/certs/errors, firewall, incoming file growth, daemon status, symlink+target, PMM agent status. Read-only; start here when something's wrong. Supports `--direct` |
| `verify-slow-log.sh` | Focused symlink verification (also called by `diagnose.sh`) — resolves `slow_query_log_file`, checks the symlink path, AND confirms the target file actually exists (a dangling symlink still "resolves" correctly, so both are checked). Supports `--direct` to bypass the socat proxy |
| `destruct.sh` | Tears down everything `setup.sh` created (PMM node/service/agents, systemd units, rsyslog config, log dirs, symlink) so a re-run of `setup.sh` starts clean. See "Tearing down / starting over" above |
| `test_prepared_statements.py` | Generates prepared-statement slow queries to validate the pipeline captures what `performance_schema` QAN cannot |
| `reconcile-slowlog-symlink.sh` | Run every minute by `mysql-sink-reconcile.timer` (installed by `setup.sh`): one read-only `SELECT @@slow_query_log_file` through the socat proxy, and a new symlink if the path changed after a DB failover. Never touches anything at that path that isn't its own symlink |
| `pmm_helper.py` | Stdlib-only helper behind `common.sh`'s PMM functions: exact service-name matching on `pmm-admin --json list`, and the PMM inventory lookups behind `setup.sh`'s node/service-ownership preflight |
| `tests/` | Unit tests (`python3 -m unittest discover -s tests`) for `transform_logs.py` and `pmm_helper.py` — no network, no real paths |

## Key files on the sink Droplet

| Path | Purpose |
|------|---------|
| `/var/log/mysql_sink/bin/transform_logs.py` | Daemon — continuously tails incoming log, reassembles syslog blocks into native slow log format |
| `/var/log/mysql_sink/incoming/combined_mysql.log` | rsyslog writes raw syslog messages here |
| `/var/log/mysql_sink/processed/native_slow_query.log` | Native slow query log consumed by PMM |
| `/etc/rsyslog.d/99-mysql-sink.conf` | mTLS imtcp listener (port 6514) → routes input to the incoming log file |
| `/etc/rsyslog.d/tls/` | CA + sink server cert/key used for the TLS syslog listener |
| `/etc/mysql_sink/do-ca.crt` | DO Managed DB CA cert, used for `VERIFY_CA` on the credential probe |
| `/etc/mysql_sink/reconcile.cnf` | Root-only (0600) MySQL client options (monitor user, via the socat proxy) for the reconcile timer |
| `/etc/systemd/system/mysql-sink-reconcile.{service,timer}` | Re-points the slow-log symlink after DB failovers (every minute) |
| `/var/lib/mysql_sink/symlinks.list` | Every slow-log symlink path this sink has created, so `destruct.sh` removes exactly those |
| `/etc/systemd/system/slow-query-sink.service` | Systemd unit for the parser daemon |
| `/etc/systemd/system/socat-mysql-proxy.service` | TCP proxy: `127.0.0.1:25060` → DO managed DB |
| `/etc/logrotate.d/mysql-sink` | Rotation for both incoming (3-day) and processed (14-day) logs. The only thing that rotates these — PMM's own slow-log rotation is disabled by `setup.sh`, and `transform_logs.py` reopens its output after each rotation |
