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
symlink needs to move with it.

## Why a daemon instead of a per-minute batch job

`transform_logs.py` runs as a persistent systemd service
(`slow-query-sink.service`), continuously tailing the incoming syslog file.
It reconstructs multi-line slow-query blocks keyed by `(source_host,
block_id)` — necessary because the 2-node DB cluster's syslog lines
interleave, and a naive line-by-line parser would corrupt entries by mixing
lines from different queries or different cluster nodes. Complete entries
are written to the processed log as soon as they're assembled, so there's no
batching delay on the sink's side of the pipeline — any remaining lag you see
in QAN is PMM's own ingestion interval, not this daemon.

## Component map

| Component | Runs where | Role |
|---|---|---|
| DO log forwarder | DO-managed | Streams syslog over mutual TLS to the sink |
| `rsyslog` (mTLS listener, port 6514) | Sink Droplet | Receives + authenticates the forwarded stream |
| `slow-query-sink.service` (`transform_logs.py`) | Sink Droplet | Reconstructs syslog lines into a real slow-log file |
| `socat-mysql-proxy.service` | Sink Droplet | TCP proxy `127.0.0.1:<port>` → the real DB host, so PMM/`mysql_slowlog_agent` connects "locally" |
| `pmm-agent` + `mysql_slowlog_agent` | Sink Droplet | Registers with PMM Server, tails the symlinked log |
| PMM Server | Separate Droplet | Ingests, aggregates, and displays QAN data |

See [../RUNBOOK.md](../RUNBOOK.md) for deployment steps, and
[tls-and-certificates.md](tls-and-certificates.md) for the mutual-TLS design
between DO and the sink.
