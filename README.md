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
  (**Ubuntu 24.04 LTS recommended**; 22.04 LTS also supported — see
  [Supported OS versions](RUNBOOK.md#supported-os-versions)).
- A public DNS A record pointing at the sink Droplet (or an
  [sslip.io](https://sslip.io) address for testing).
- DO Managed MySQL with slow query log enabled, and a `pmm_monitor` DB user
  created.
- `git` and an SSH key for cloning this repo onto the sink Droplet.

## Install (Ubuntu 24.04 LTS)

1. **Provision the PMM Server Droplet** and install PMM:
   ```bash
   curl -fsSL https://www.percona.com/get/pmm | bash
   ```
2. **Clone this repo** — locally, to fill in config, and onto the sink Droplet:
   ```bash
   git clone git@github.com:<your-org-or-user>/slow-logs-custom-sync-pmm.git
   cd slow-logs-custom-sync-pmm
   ```
3. **Generate mTLS certificates** (run locally, before configuring DO log forwarding):
   ```bash
   ./gen-certs.sh
   ```
4. **Configure `.env`** — see [Configuration](#configuration-env) below.
5. **Configure DO Managed MySQL**: enable slow query log, set
   `log_output=INSIGHTS`, and set up mutual-TLS log forwarding to the sink.
   Full steps: [RUNBOOK.md, Step 3](RUNBOOK.md#step-3--configure-do-managed-db).
6. **Deploy to the sink Droplet and run setup**:
   ```bash
   git clone git@github.com:<your-org-or-user>/slow-logs-custom-sync-pmm.git
   scp .env root@<SINK_IP>:~/slow-logs-custom-sync-pmm/.env
   scp certs/* root@<SINK_IP>:~/slow-logs-custom-sync-pmm/certs/
   ssh root@<SINK_IP> "cd slow-logs-custom-sync-pmm && bash setup.sh"
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
| `DO_CA_BUNDLE` | Where the DO Managed DB CA cert lands on the sink Droplet (default is fine) |

`.env` is gitignored — never commit it. Full field-by-field details:
[RUNBOOK.md, Step 2](RUNBOOK.md#step-2--fill-in-env).

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
bash verify-slow-log.sh        # confirms the symlink and DB connectivity
```

## Validate prepared statements are captured

```bash
pip install mysql-connector-python
set -a; source .env; set +a
python3 test_prepared_statements.py "$DB_PASS"
```

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
