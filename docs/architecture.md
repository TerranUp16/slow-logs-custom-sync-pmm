# Architecture

## The problem

PMM's Query Analytics (QAN) module needs a slow query log to see prepared
statements (`COM_STMT_PREPARE` / `COM_STMT_EXECUTE`) — the alternative source,
`performance_schema`, does not capture them at all. But DigitalOcean Managed
MySQL doesn't expose its underlying filesystem, so there's no file for a
locally-installed `pmm-agent` to tail directly. DO's only way to get log data
out is **syslog forwarding**, which streams raw, timestamped syslog lines —
not a file PMM can point `mysql_slowlog_agent` at.

This repo bridges that gap.

## The pipeline

```
DO Managed MySQL (2-node cluster)
  --[mutual-TLS syslog, port 6514]--> Sink Droplet (rsyslog, ossl driver)
    --> /var/log/mysql_sink/incoming/combined_mysql.log      (raw syslog)
    --> slow-query-sink.service (transform_logs.py, continuous tail)
    --> /var/log/mysql_sink/processed/native_slow_query.log  (real slow-log format)
    --> symlink at the DB's own slow_query_log_file path
    --> pmm-agent (mysql_slowlog_agent) tails the symlink
    --> PMM Server QAN
```

## Why the symlink, specifically

When you register a MySQL service in PMM with `--query-source=slowlog`, the
`mysql_slowlog_agent` asks the database itself for its slow-log path
(`SHOW VARIABLES LIKE 'slow_query_log_file'`) and then tries to open that path
**on the machine `pmm-agent` is running on** — which, in this setup, is the
sink Droplet, not DO's managed server. DO still reports a real-looking path
(e.g. `/var/lib/mysql/8/data/<cluster>-slow.log`) even though that file isn't
reachable on DO's side.

`setup.sh` exploits that: it queries the DB for its reported slow-log path,
then creates a symlink **at that exact path string, on the sink Droplet's
local filesystem**, pointing at the sink's own reconstructed log
(`native_slow_query.log`). When `mysql_slowlog_agent` asks the DB "where's
your slow log?" and then opens that path locally, it finds our symlink
instead — and starts tailing the reconstructed log without knowing the
difference.

This is also why `setup.sh` re-resolves and re-creates the symlink on every
run: if the DB reports a different path (new cluster, DB replacement), the
symlink needs to move with it. On DO the reported path embeds the serving
node's hostname (e.g. `/var/lib/mysql/8/data/<cluster>-1-slow.log`), so it is
node-specific — and it changes whenever the primary moves to another node: a
failover, maintenance, or a resize (which replaces nodes; observed live, `-1`
became `-4`). `mysql_slowlog_agent` re-reads the variable and opens the new
path, so `mysql-sink-reconcile.timer` re-resolves it every minute and adds the
symlink there (read-only towards the DB; it never replaces anything that isn't
its own symlink). The agent picks the file up again by itself — QAN gap after
a failover is about a minute, not "until someone re-runs setup.sh".

### Who rotates the log: logrotate, not PMM

The same "PMM thinks it's talking to a local mysqld" trick has one sharp edge.
PMM's slowlog agent has its own rotation: once the file passes a size limit
(1 GiB by default) it renames `slow_query_log_file` to `<path>.old` and runs
`FLUSH SLOW LOGS` on the DB, expecting mysqld to recreate the file. Here the
path is our symlink and mysqld is remote, so the rename moves the symlink
away, nothing recreates it, and QAN silently stops (the agent keeps reporting
`Running`). So `setup.sh` sets the service's PMM-side limit to 0 (disabled),
and rotation belongs to `/etc/logrotate.d/mysql-sink` alone. `transform_logs.py`
notices when logrotate has moved its output file and reopens the path, so it
always writes to the file PMM is reading.

## Why a daemon instead of a per-minute batch job

`transform_logs.py` runs as a persistent systemd service
(`slow-query-sink.service`), continuously tailing the incoming syslog file.
It reconstructs multi-line slow-query blocks keyed by `(source_host,
block_id)` — necessary because every node of the DB cluster forwards its logs
(a standby forwards too, though only the node serving queries writes slow-log
lines), their syslog lines can interleave, and a naive line-by-line parser
would corrupt entries by mixing lines from different queries or different
nodes. `source_host` is parsed from rsyslog's file output, whose format
`setup.sh` pins (`RSYSLOG_FileFormat`) so it doesn't depend on distro
defaults.

A block is written to the processed log once it's known to be finished: when
the same host starts its next block, or — for the last block before a quiet
period — once it's 30 seconds old. So there's no batching delay while queries
are flowing; on a quiet DB the final query of a burst can take up to ~30 s to
appear. Any further lag you see in QAN is PMM's own ingestion interval, not
this daemon.

## Deployment model: one sink Droplet per endpoint, no HA

"Single sink" means **one sink per DB endpoint**. Each endpoint DO lets you
point Log Forwarding at — a cluster (primary and standby nodes forward
together), or a read-only replica — gets its own sink Droplet, with its own
`.env`, mTLS CA, PMM token, PMM node and PMM service. Any number of sinks can
report to one PMM Server; they only need unique `PMM_SERVICE_NAME` and node
names (`setup.sh` refuses to register over another machine's node or
service). See RUNBOOK "Monitoring multiple Managed MySQL endpoints with one
PMM Server".

Serving several endpoints from one sink was designed and deliberately not
pursued. One sink per endpoint is the model; don't add multi-endpoint support
to a sink.

Each sink is intentionally a single, non-clustered resource — no
horizontal scaling, no standby, no automatic failover. If it goes down, log
forwarding to QAN stops until it's back, and that downtime is an accepted
trade-off, not an oversight: for the customer this repo was first built for,
the value is seeing prepared statements in QAN at all, and they've explicitly
chosen not to pay for an HA version of this pipeline.

This shapes a few concrete design choices elsewhere in this repo:

- **No separate dev/laptop machine anywhere in the flow.** The repo clone,
  `.env`, `certs/` (including the private CA from `gen-certs.sh`), and every
  config value pasted into DO's or PMM's control panels all happen in one SSH
  session on the sink Droplet itself. There's no multi-machine state to keep
  in sync, because there's only ever one machine.
- **The CA `gen-certs.sh` generates is per-Droplet, not portable.** Since
  there's only ever one sink Droplet in service at a time, there's no need
  for a shared/portable CA authority that multiple Droplets could present. If
  the Droplet is rebuilt or replaced, the new one mints its own CA and client
  cert from scratch, and DO's Log Forwarding panel gets a one-time manual
  update to match (see RUNBOOK's "Re-deploying to a new sink Droplet").
- **Recovery is "redeploy," not "failover."** There's no second sink Droplet
  standing by. Recovering from a lost or corrupted Droplet means provisioning
  a new one and re-running the same one-session setup flow, not promoting a
  replica.

If a customer's requirements change and this pipeline needs to become highly
available, that's a real redesign — a shared/portable CA, externalized `.env`
and cert storage, and an active/standby or load-balanced sink layer — not a
config toggle on top of what's here today.

## Component map

| Component | Runs where | Role |
|---|---|---|
| DO log forwarder | DO-managed | Streams syslog over mutual TLS to the sink |
| `rsyslog` (mTLS listener, port 6514) | Sink Droplet | Receives + authenticates the forwarded stream |
| `slow-query-sink.service` (`transform_logs.py`) | Sink Droplet | Reconstructs syslog lines into a real slow-log file |
| `socat-mysql-proxy.service` | Sink Droplet | TCP proxy `127.0.0.1:<LOCAL_PROXY_PORT>` → the real DB host, so PMM/`mysql_slowlog_agent` connects "locally" |
| `pmm-agent` + `mysql_slowlog_agent` | Sink Droplet | Registers with PMM Server, tails the symlinked log |
| PMM Server | Separate Droplet | Ingests, aggregates, and displays QAN data |

See [../RUNBOOK.md](../RUNBOOK.md) for deployment steps, and
[tls-and-certificates.md](tls-and-certificates.md) for the mutual-TLS design
between DO and the sink.
