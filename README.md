# DO Managed MySQL Slow Log → PMM QAN Sink

Deploys an automated pipeline that turns DigitalOcean Managed MySQL's slow
query log into a working [PMM](https://www.percona.com/software/database-tools/percona-monitoring-and-management)
Query Analytics (QAN) data source — including prepared statements, which
PMM's default `performance_schema` QAN source cannot see. A small "sink"
Droplet receives the log over syslog, reconstructs it into a real MySQL
slow-query-log file, and wires the result into PMM automatically.

## Why this exists

- DO Managed MySQL doesn't expose its filesystem, so PMM can't tail the slow
  query log directly — only forward it via syslog.
- PMM's `performance_schema` QAN source can't see prepared statements
  (`COM_STMT_PREPARE`/`COM_STMT_EXECUTE`) at all — only the slow query log can.
- This repo automates the workaround (forward → reconstruct → symlink → PMM)
  in one script, so you don't have to build it by hand.

Full design rationale and pipeline diagram: [docs/architecture.md](docs/architecture.md).

## Prerequisites

- Two Ubuntu Droplets: one running PMM Server, one to act as the sink
  (**Ubuntu 24.04 LTS recommended**; 22.04 and 26.04 LTS also supported — see
  [Supported OS versions](RUNBOOK.md#supported-os-versions)).
- A public DNS A record pointing at the sink Droplet (or an
  [sslip.io](https://sslip.io) address for testing — see
  [docs/sslip.md](docs/sslip.md)).
- DO Managed MySQL with slow query log enabled, and a `pmm_monitor` DB user
  created.
- SSH access to the sink Droplet itself — no other machine is needed (the
  repo is public, so `git clone` over HTTPS needs no key). This is a single,
  non-HA sink Droplet by design (see [docs/architecture.md](docs/architecture.md));
  everything below runs in one SSH session on it.

## Install (Ubuntu 24.04 LTS)

1. **Provision the PMM Server Droplet** and install PMM:
   ```bash
   curl -fsSL https://www.percona.com/get/pmm | bash
   ```
2. **Provision the sink Droplet, SSH in, and clone this repo there**:
   ```bash
   ssh root@<SINK_IP>
   git clone https://github.com/DO-Solutions/slow-logs-custom-sync-pmm.git
   cd slow-logs-custom-sync-pmm
   ```
3. **Create and fill in `.env`** — see [Configuration](#configuration-env) below.
4. **Generate mTLS certificates**, directly on the sink Droplet:
   ```bash
   ./gen-certs.sh
   ```
5. **Configure DO Managed MySQL**: enable slow query log, set
   `log_output=LOGS` (formerly called `INSIGHTS`) and `long_query_time=0.1`,
   and set up mutual-TLS log forwarding to the sink (pasting the cert/key
   `gen-certs.sh` just produced into DO's panel).
   Full steps: [RUNBOOK.md, Step 4](RUNBOOK.md#step-4--configure-do-managed-db).

   `0.1` is the lowest `long_query_time` DO accepts, so **QAN only shows
   statements that take ≥ 100 ms** — prepared or not. Faster queries never
   reach the slow log. See the RUNBOOK's Step 4 note on what that means for
   reading QAN.
6. **Run setup**, still in the same SSH session:
   ```bash
   bash setup.sh
   ```

Full step-by-step — including PMM API tokens, DNS-01 certs for private/VPC
sinks, and re-deploy scenarios: [RUNBOOK.md](RUNBOOK.md).

## Configuration (`.env`)

Copy `env.example` to `.env` and fill in:

| Variable | Purpose |
|---|---|
| `DB_HOST`, `DB_PORT`, `DB_PASS`, `PMM_MONITOR_USER` | DO Managed MySQL connection details |
| `SINK_IP`, `SINK_HOSTNAME`, `LETSENCRYPT_EMAIL` | Sink Droplet's public identity — `SINK_HOSTNAME` must resolve to `SINK_IP` |
| `PMM_SERVER`, `PMM_TOKEN` | PMM Server address + API token (leave `PMM_TOKEN` blank to auto-mint on a fresh PMM install) |
| `DO_CA_BUNDLE` | Where `setup.sh` **installs** the DO Managed DB CA cert on this Droplet (default is fine — leave unset). This is **not** where you put the downloaded cert; paste that into `certs/do-ca.crt` instead (see below) |
| `PMM_SERVICE_NAME`, `PMM_NODE_NAME` | Optional with one sink (defaults: `do-managed-mysql`, the Droplet's hostname). **Must be unique per sink** when several sinks report to one PMM Server |
| `PMM_ENVIRONMENT`, `PMM_CLUSTER`, `PMM_REPLICATION_SET`, `PMM_CUSTOM_LABELS` | Optional PMM labels for grouping/comparing endpoints (e.g. primary vs replica) |
| `LOCAL_PROXY_PORT`, `PMM_FORCE_REREGISTER` | Rarely needed: local socat port (default `DB_PORT`); `1` to replace a stale PMM node with this sink's name |

**Monitoring several endpoints** (e.g. a cluster and its read-only replica) in
one PMM Server: deploy one sink per endpoint, each with its own `.env`, token,
`PMM_SERVICE_NAME` and node name — no source edits. See
[RUNBOOK.md, "Monitoring multiple Managed MySQL endpoints with one PMM Server"](RUNBOOK.md#monitoring-multiple-managed-mysql-endpoints-with-one-pmm-server).

Separately, paste the DO Managed DB's CA certificate (Connection Details →
Download CA certificate in the DO control panel) into `certs/do-ca.crt` in
this repo directory — this file is gitignored and isn't a `.env` variable.
`setup.sh` reads it from there and installs a copy to `DO_CA_BUNDLE` above.

`.env` is gitignored — never commit it. Full field-by-field details:
[RUNBOOK.md, Step 3](RUNBOOK.md#step-3--fill-in-env).

## Usage: `setup.sh`

Run on the sink Droplet:

```bash
bash setup.sh
```

It verifies DB connectivity first — failing fast with a real error if
something's wrong, before touching anything — then: creates the sink service
user and directories, sets up the mTLS syslog listener, obtains a Let's
Encrypt cert, installs `pmm-client`, registers the node and MySQL service in
PMM with `--query-source=slowlog`, and creates the symlink PMM needs. It's
idempotent — safe to re-run after fixing a config issue.

Verify it worked:
```bash
pmm-admin list                 # node + agents should show Running
bash diagnose.sh                # full pipeline health check — start here if anything looks off
bash verify-slow-log.sh        # focused symlink + target-file check (diagnose.sh calls this too)
```

`setup.sh` can't confirm data is actually flowing end-to-end on its own — DO's
log forwarder takes ~1-2 minutes to redeploy after its config is saved, and
generating a real slow-query workload isn't this script's job. `diagnose.sh`
is the follow-up: it checks every stage of the pipeline (DB config, rsyslog,
TLS certs, firewall, the incoming/processed log files, and PMM agent status)
and reports exactly where it's stuck if something isn't working.

## Validate prepared statements are captured

```bash
apt-get install -y python3-venv
python3 -m venv .venv && .venv/bin/pip install mysql-connector-python
set -a; source .env; set +a
.venv/bin/python test_prepared_statements.py "$DB_PASS"
```

(Use the venv rather than Ubuntu's `python3-mysql.connector` package — on
24.04 that's connector 8.0.15, which fails on Python 3.12 with
`module 'ssl' has no attribute 'wrap_socket'`. Details:
[RUNBOOK.md, Step 6](RUNBOOK.md#step-6--verify).)

Runs several `SLEEP()`-padded prepared statements against the DB and prints
where to check for them (`native_slow_query.log`, then PMM's QAN UI — give
QAN a minute or two to catch up). This is the actual point of the whole
pipeline: confirming PMM sees queries that `performance_schema` QAN would
miss.

## Cleanup: `destruct.sh`

Reverses everything `setup.sh` created — useful before re-running setup from
a clean slate:

```bash
bash destruct.sh --dry-run   # preview, changes nothing
bash destruct.sh             # tears down (with confirmation prompt)
```

Scoped to exactly what `setup.sh` creates (this node's PMM registration, the
sink's systemd units, rsyslog config, logs). Leaves shared packages and your
Let's Encrypt cert alone by default. Details:
[RUNBOOK.md](RUNBOOK.md#tearing-down--starting-over-destructsh).

## Further documentation

- **[RUNBOOK.md](RUNBOOK.md)** — full step-by-step deployment and operational procedures.
- **[docs/architecture.md](docs/architecture.md)** — why this exists, and how the pipeline works end to end.
- **[docs/tls-and-certificates.md](docs/tls-and-certificates.md)** — mTLS design, DO's certificate quirks, and the DNS-01 alternative for private/VPC sinks.
- **[docs/sslip.md](docs/sslip.md)** — using sslip.io to test without owning a domain.
