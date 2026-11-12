# Design: many Managed MySQL endpoints on one sink ("Shape B")

**Status:** proposal, for review before any code. Phase 1 (one endpoint per
sink, many sinks per PMM Server — "Shape A") is implemented. This document
covers the work after it.

**Goal:** one sink Droplet serves N DO Managed MySQL endpoints (for example a
cluster's primary and its read-only replica). Each endpoint gets its own
ingest, reconstruction, proxy, symlink and PMM service. Removing one leaves
the others untouched. A legacy single-`.env` sink behaves exactly as today.

Facts below marked **(verified)** were checked against live DO Managed MySQL
8.4, PMM 3.10.0 and rsyslog 8.2312 / 8.2512 in November 2026, using the
throwaway test environment the Phase 1 work was validated on.

---

## 1. Configuration layout

**Decision:** sink-wide settings stay in `.env`, and there is one file per
endpoint, `instances/<name>.env`.

| Lives in `.env` (sink-wide) | Lives in `instances/<name>.env` (per endpoint) |
|---|---|
| `SINK_IP`, `SINK_HOSTNAME`, `LETSENCRYPT_EMAIL` | `DB_HOST`, `DB_PORT`, `DB_PASS`, `PMM_MONITOR_USER` |
| `PMM_SERVER`, `PMM_TOKEN`, `PMM_NODE_NAME`, `PMM_FORCE_REREGISTER` | `PMM_SERVICE_NAME`, `PMM_ENVIRONMENT`, `PMM_CLUSTER`, `PMM_REPLICATION_SET`, `PMM_CUSTOM_LABELS` |
| `PERCONA_RELEASE_URL`, `PERCONA_RELEASE_SHA256` | `LOCAL_PROXY_PORT`, `SYSLOG_PORT`, `DO_CA_SRC` (default `certs/do-ca.crt`) |

- **The legacy shape maps to an implicit instance named `default`.** If `.env`
  itself contains `DB_HOST`, it is treated as the endpoint `default` and keeps
  every legacy name: units `slow-query-sink.service` and
  `socat-mysql-proxy.service`, paths `/var/log/mysql_sink/{incoming,processed}`,
  syslog port 6514, and `PMM_SERVICE_NAME` defaulting to `do-managed-mysql`.
  Nothing moves on existing sinks. A sink may have `default` plus
  `instances/*.env`, so an existing sink can grow a second endpoint without
  migrating the first.
- **Instance names** match `^[a-z0-9][a-z0-9-]{0,31}$`. The name appears in
  systemd unit instance names, file paths and rsyslog ruleset names, so it is
  kept to the intersection of what all three accept. `default` is reserved.
- **Instance files may not set sink-wide keys,** and `.env` may not set
  per-instance keys other than legacy `default`'s. The loader rejects both
  with a message naming the file and key, so a sink-wide value can't be
  silently shadowed.
- **Why files rather than one big `.env` with prefixed keys:** one file per
  endpoint is what an operator adds or removes. Its `DB_PASS` stays with its
  endpoint, and `destruct.sh --instance X` has an obvious artifact to leave
  behind or point at. The existing `load_config` / `validate_config`
  (Phase 1, `common.sh`) are reused per file.
- **Rendered runtime config:** `setup.sh` writes
  `/etc/mysql_sink/instances/<name>.conf` (root, 0644) with only what the
  units need: `DB_HOST`, `DB_PORT`, `LOCAL_PROXY_PORT`, `INPUT`, `OUTPUT`. It
  contains no credentials, because socat and the daemon need none.

## 2. Ingest separation

**Decision:** one rsyslog `imtcp` listener per instance, on its own port, each
bound to its own ruleset that writes that instance's incoming file. `default`
keeps 6514. New instances set `SYSLOG_PORT` (validated unique on the sink, and
not 80).

```
global(defaultNetstreamDriver="ossl" ... sink-wide LE server cert + private client CA ...)
module(load="imtcp" StreamDriver.Name="ossl" StreamDriver.Mode="1" StreamDriver.AuthMode="x509/certvalid")
ruleset(name="inst_default")      { action(type="omfile" file="/var/log/mysql_sink/incoming/combined_mysql.log" template="RSYSLOG_FileFormat" ...) stop }
ruleset(name="inst_prod-replica") { action(type="omfile" file="/var/log/mysql_sink/prod-replica/incoming/combined_mysql.log" template="RSYSLOG_FileFormat" ...) stop }
input(type="imtcp" port="6514" ruleset="inst_default")
input(type="imtcp" port="6515" ruleset="inst_prod-replica")
```

- **TLS stays sink-wide.** Every listener presents the same Let's Encrypt
  cert for `SINK_HOSTNAME` and verifies clients against the same private CA,
  so one `gen-certs.sh` client cert/key is pasted into every endpoint's Log
  Forwarding destination. Only the port differs per endpoint.
- **(verified) The `ossl` driver accepts this.** The config above, with
  the global TLS settings exactly as `setup.sh` writes them today, passes
  `rsyslogd -N1` on both 8.2312 (Ubuntu 24.04) and 8.2512 (Ubuntu 26.04).
  Per-input `streamDriver.*` overrides also parse, but aren't needed. **Still
  to verify live:** a real DO mTLS handshake on a second port.
- **(verified) A wrong ruleset name doesn't fail at runtime.** rsyslog
  logs "ruleset '…' for port N not found — using default ruleset instead".
  That would silently deliver one endpoint's logs into whatever the default
  ruleset does. `setup.sh` must therefore write the new config to a temporary
  file, run `rsyslogd -N1 -f <tmp>`, treat any failure as fatal, and only then
  replace `99-mysql-sink.conf` and restart rsyslog. If the check fails, the
  running config is left alone.
- **The whole file is regenerated from all instances on every run,** rather
  than each instance appending or removing its own fragment. A single writer
  avoids ordering problems and leftovers. The file name stays
  `/etc/rsyslog.d/99-mysql-sink.conf`. For a `default`-only sink the
  generated content changes shape (an input-bound ruleset instead of today's
  `if $inputname == 'imtcp'` filter) but routes identically; the `-N1` gate
  covers it.
- **Routing by syslog HOSTNAME is rejected.** It would make correctness
  depend on DO's node naming, and that naming moves:
  - every node of a cluster forwards, including the standby **(verified)**:
    `pmmsink-test-prod-primary-2` appeared in the stream while `-1` was
    primary;
  - node hostnames change across failover and resize (see §8).
  Port-per-endpoint depends only on configuration we control.

## 3. Per-instance units

**Decision:** systemd template units `slow-query-sink@.service` and
`socat-mysql-proxy@.service`, both with
`EnvironmentFile=/etc/mysql_sink/instances/%i.conf`. `default` keeps the
existing non-template units, so they are not renamed on legacy sinks.

- `socat-mysql-proxy@.service`:
  `ExecStart=/usr/bin/socat TCP4-LISTEN:${LOCAL_PROXY_PORT},fork,reuseaddr,bind=127.0.0.1 TCP4:${DB_HOST}:${DB_PORT}`,
  with the same hardening as today. `LOCAL_PROXY_PORT` must be unique across
  the sink's instances; validation checks the set of instances, and preflight
  checks that nothing else is listening on the port.
- `slow-query-sink@.service`:
  `ExecStart=/usr/bin/python3 /var/log/mysql_sink/bin/transform_logs.py --input ${INPUT} --output ${OUTPUT}`,
  with `ReadWritePaths=/var/log/mysql_sink/%i/processed` and
  `ReadOnlyPaths=/var/log/mysql_sink/%i/incoming`. Each daemon can then only
  write its own output, which is tighter than today's
  `ReadWritePaths=/var/log/mysql_sink`. `MemoryMax` and the other hardening
  directives stay per process.
- `transform_logs.py` gains `--input` / `--output` arguments, defaulting to
  today's constants, so the legacy unit (no arguments) behaves exactly as now.
  The input-hardening bounds stay global constants, enforced per process,
  i.e. per instance.

## 4. Paths

- New instances use `/var/log/mysql_sink/<name>/{incoming,processed}`, with
  the same owners and modes as today: `incoming/` is `syslog:adm 750`, and
  `processed/` is `mysqlsink:adm 2750` (setgid, as introduced in the
  prerequisite fixes).
- `default` keeps `/var/log/mysql_sink/{incoming,processed}`.
- The symlink at each instance's DB-reported `slow_query_log_file` points at
  that instance's `processed/native_slow_query.log`.

## 5. Logrotate and firewall

- **Logrotate:** one file per instance, `/etc/logrotate.d/mysql-sink-<name>`,
  with `default` keeping `/etc/logrotate.d/mysql-sink`. This keeps
  `destruct.sh --instance` a single `rm`. The stanzas are today's, and still
  need no postrotate for the processed log (the daemon reopens it after
  rotation). The incoming stanza keeps `systemctl kill -s HUP rsyslog`.
- **ufw:** one rule per `SYSLOG_PORT`, with comment
  `mysql-sink <name> syslog mTLS`. `destruct.sh --instance` deletes only that
  rule; port 80 (ACME) stays sink-wide. `diagnose.sh` already iterates a
  `SYSLOG_PORTS` list (Phase 1), which becomes every instance's port.

## 6. Script interface

| Command | No flag | `--instance NAME` | `--all` |
|---|---|---|---|
| `setup.sh` | Legacy `.env` only: exactly as today. Instances present: same as `--all`. | Sink-wide steps, then only `NAME`'s per-instance steps. | Sink-wide steps, then every instance. |
| `destruct.sh` | Legacy `.env` only: exactly as today. Instances present: **error**, asking for an explicit flag. | Removes only `NAME`: its PMM service, units, `/var/log/mysql_sink/NAME`, symlink(s), logrotate file, ufw rule and listener (rsyslog config regenerated without it). Leaves `instances/NAME.env` with a note. | Today's full teardown, applied to every instance plus the sink-wide parts and the node. |
| `diagnose.sh` | Every instance (sink-wide stages once). | Sink-wide stages, plus `NAME`'s. | Same as no flag. |
| `verify-slow-log.sh` | The only instance (legacy or single); error if there are several. | `NAME`. | n/a |

- "Sink-wide steps" means packages, the Let's Encrypt cert, the rsyslog
  global/TLS section, and PMM node registration (`pmm-admin config`, with the
  Phase 1 ownership preflight). They run once per invocation.
- **Removing the last instance does not unregister the node.**
  `destruct.sh --instance` never touches sink-wide state. When it removes the
  last instance it says so and points at `destruct.sh --all`. Reason: a
  per-instance command shouldn't have a sink-wide side effect that depends on
  what else happens to be configured.
- **PMM identity on a multi-instance sink:** one node (`PMM_NODE_NAME`,
  sink-wide) and N services, each with its own `PMM_SERVICE_NAME` and
  `LOCAL_PROXY_PORT`. Phase 1's rename cleanup ("a service on this node at
  this instance's `127.0.0.1:<port>` under another name is this instance's
  old name") stays correct because ports are unique per sink.
- **Config-loading and validation logic** (instance discovery, key placement,
  uniqueness of names and ports) gets unit tests. The loader becomes a small
  stdlib Python module next to `pmm_helper.py`, returning a JSON/`declare`
  view that the bash scripts consume, so it can be tested without a sink.

## 7. `slow_query_log_file` collisions

- `mysql_slowlog_agent` opens the DB-reported path on the sink. Two instances
  that report the **same** path can't both be served: one symlink can only
  point at one processed log.
- **(verified) DO paths embed the serving node's hostname,** which embeds the
  cluster name: `/var/lib/mysql/8/data/<cluster>-<n>-slow.log`. A primary and
  its replica differ (`…prod-primary-1-…` vs `…prod-replica-1-…`). Collisions
  therefore need two endpoints with the same cluster name, which is only
  possible across DO accounts or projects.
- **Detection:** every resolved path is recorded in
  `/etc/mysql_sink/instances/<name>.path`. Before creating or re-pointing an
  instance's symlink, `setup.sh` and the reconcile job (§8) compare it with
  the other instances' recorded paths. If they're equal, `setup.sh` fails
  before touching the symlink, with: "instances A and B both report
  slow_query_log_file=…; mysql_slowlog_agent opens that path for both, so they
  can't share a sink — move one to its own sink (Shape A)". The reconcile job
  logs the same error and leaves the existing symlink alone.
- **(verified) PMM has no supported per-service path override.** The
  agent's `SlowLogFilePrefix` comes from `pmm-agent.yaml` `paths`, applies to
  every service on the node, and is labelled "for development and testing".
  It can't separate two services that report the same path, so the symlink
  design stays.

## 8. Drift reconciliation (failover)

**(verified) Drift is real.** A resize of the 2-node test primary (DO
replaces nodes, then switches over) moved the serving node from
`pmmsink-test-prod-primary-1` to `…-4`. The database was unreachable for
about 20 s, and `slow_query_log_file` changed to `…-4-slow.log`. Within a
minute, `mysql_slowlog_agent` re-read the variable and sat in `Waiting` on
the new, missing path. QAN for that service stopped. The incoming stream also
carried interleaved lines from `-1`, `-3` and `-4` around the switchover.

**Phase 1 already ships the fix for single-instance sinks:**
`mysql-sink-reconcile.timer`, which runs every minute, together with
`reconcile-slowlog-symlink.sh`.

- Each run does one read-only `SELECT @@slow_query_log_file` through the socat
  proxy, using a root-only options file.
- If that path lacks our symlink, it creates one and records the path in
  `/var/lib/mysql_sink/symlinks.list`.
- It never replaces anything at that path that isn't already its own
  symlink.
- It keeps the old symlink, since that node may become primary again.
- A failed query just means "retry next minute", so the timer doesn't flap.
- **(verified)** With the new path's symlink deleted, the timer restored it on
  its next tick (about 65 s), and the agent went from `Waiting` to `Running`
  about 5 s later with no restart.

**Per instance in Phase 2:**

- One template pair, `mysql-sink-reconcile@.service` / `@.timer`, reading
  `/etc/mysql_sink/instances/%i.cnf`, with `RECONCILE_TARGET` and
  `RECONCILE_STATE` per instance. The script already takes these as
  environment overrides.
- `default` keeps the non-template units.
- Before creating a symlink, the job runs the §7 collision check against the
  other instances' recorded paths.

## 8a. Why not route by syslog hostname: more evidence

The failover above produced three different source hostnames for one
endpoint within a minute, and none of them was the one configured when the
sink was set up. Any design that keys "which endpoint is this?" on the syslog
HOSTNAME would have needed reconfiguring on every failover. Port-per-endpoint
(§2) doesn't care.

## 9. Capacity

Measured on the test environment:

- **(verified) `transform_logs.py` parse throughput is about 576k lines/s
  per core** (Python 3.14, real line format, two interleaved hosts,
  in-memory). That is roughly 96k reconstructed slow queries/s per core.
  Each instance is its own process, so instances scale across cores. The
  daemon is not the bottleneck.
- **(verified) Live load:** about 1 slow query/s produced about 1.2 KB/s of
  incoming syslog and used 0.4% CPU and 15 MB RSS for the daemon on a
  2 vCPU sink.

The practical limits are elsewhere: DO's log forwarder, the sink's disk (each
logged query is stored twice, raw and reconstructed, for 3 and 14 days), and
PMM's slowlog agent plus the PMM Server's QAN ingestion. Rough guidance for a
2 vCPU / 8 GB sink, **to be validated with a load test before it goes into
the RUNBOOK:**

- **Disk:** per instance, about (slow queries/s) × 1.2 KB × 86,400 per day
  incoming, plus a similar amount processed. At 100 slow queries/s that is
  about 10 GB/day per copy before compression. Size the disk for 3 days
  incoming plus 14 days processed (compressed after the first rotation).
- **Use separate sinks (Shape A) instead when:**
  - the endpoints need independent failure domains (a sink outage stops QAN
    for every endpoint on it);
  - they sit in different VPCs or regions;
  - their combined slow-log rate needs more than one Droplet's disk or NIC;
  - or two endpoints report the same `slow_query_log_file` (§7).
- **Use Shape B for:** a handful of moderate endpoints in one VPC where saving
  Droplets matters more than isolation. A typical example is a cluster plus
  its replica at `long_query_time = 0.1`.

## 10. Backward compatibility and rollout

- **A legacy `.env` with no `instances/`** produces the same units, paths,
  ports, rsyslog routing, service name and node as Phase 1. The only change is
  the generated rsyslog file's shape, which routes identically and is gated by
  `-N1`.
- **Adding `instances/x.env` to a legacy sink** leaves `default` untouched and
  adds `x` alongside it.
- **No migration step.** Nobody has to move `default` into `instances/`.
  Doing so would be a deliberate later choice, and is out of scope here.

## 11. Test plan

- **Unit tests (no network):**
  - the config loader: discovery, key placement, uniqueness of names, ports
    and `SYSLOG_PORT`, and the reserved `default`;
  - the rsyslog config renderer (golden-file output for `default`-only and
    `default` + 2);
  - `transform_logs.py` with explicit `--input` / `--output`.
- **Live** (same throwaway environment pattern as Phase 1):
  - one sink serving the primary (`default`, 6514) and the replica (6515);
    both appear in QAN;
  - `destruct.sh --instance prod-replica` leaves `default` passing
    `diagnose.sh` with no FAILs;
  - a legacy sink's `git pull && bash setup.sh` gives a byte-identical
    registration (same node ID and service name);
  - a deliberately broken ruleset makes `setup.sh` fail before restarting
    rsyslog;
  - a resize-triggered failover is followed by reconciliation (§8).

## 12. Open questions for review

1. Should `setup.sh` with no flag and instances present mean `--all`, as
   proposed, or require an explicit flag the way `destruct.sh` does?
2. Is it acceptable for the rsyslog config to change shape on legacy sinks
   (§2)? It routes identically, but it is a diff on existing boxes. The
   alternative is keeping the legacy `if $inputname` form whenever only
   `default` exists.
3. Should Shape B cap the number of instances per sink (for example 4) until
   the capacity guidance in §9 has been load-tested?
