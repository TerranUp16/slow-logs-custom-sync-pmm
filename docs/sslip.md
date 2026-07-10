# Using sslip.io for testing

## What it is

[sslip.io](https://sslip.io) is a free public DNS service that resolves
hostnames of the form `<IP-address-with-dashes>.sslip.io` to the IP address
embedded in the hostname itself — no account, no records to create, no
propagation delay. For example:

```
157-245-120-166.sslip.io  →  resolves to  →  157.245.120.166
```

Change the dashes back to dots and that's the A record. sslip.io runs this
as a wildcard: any dash-separated IPv4 (or IPv6) address you put in front of
`.sslip.io` resolves automatically, with no setup on sslip.io's side.

## Why it matters for this pipeline

`SINK_HOSTNAME` (in `.env`) has to be a **real, publicly-resolvable DNS
name** — not a raw IP — for two independent reasons:

1. **Certbot's HTTP-01 challenge** (used by `setup.sh` to get the sink's
   Let's Encrypt certificate) validates domain ownership by resolving a
   hostname and connecting to it on port 80. It won't issue a certificate
   for a bare IP address.
2. **DO's Log Forwarding "Endpoint" field** accepts a DNS name or an IP, but
   DO's forwarder verifies the sink's TLS certificate against the hostname
   it connects to — and Let's Encrypt only issues certs for hostnames, never
   raw IPs.

If you own a domain, just point an A record at the sink Droplet's IP and use
that as `SINK_HOSTNAME` — see Step 3 in [RUNBOOK.md](../RUNBOOK.md). If you
don't (a quick test, a throwaway Droplet, a demo environment), `sslip.io`
gives you a real, publicly-resolvable hostname for that IP with zero DNS
setup, so you can run through the whole pipeline without buying or
delegating a domain.

It is **not** a production recommendation — it's a convenience for testing
and demos. sslip.io is a third-party free service with no uptime SLA; for a
customer's production deployment, use a real domain you control.

## Step by step

1. **Provision the sink Droplet first** and note its public IPv4 address,
   e.g. `157.245.120.166`.
2. **Build the sslip.io hostname** by replacing the dots with dashes and
   appending `.sslip.io`:
   ```
   157.245.120.166  →  157-245-120-166.sslip.io
   ```
3. **Use that full string as `SINK_HOSTNAME`** in `.env` (Step 3 of
   [RUNBOOK.md](../RUNBOOK.md)) — exactly as you would a real domain name.
   Nothing else about the setup changes.
4. **Confirm it resolves** before moving on (optional sanity check):
   ```bash
   dig +short 157-245-120-166.sslip.io
   # should print: 157.245.120.166
   ```
5. Continue the runbook normally. `setup.sh` requests a Let's Encrypt cert
   for `157-245-120-166.sslip.io` via HTTP-01 — this works exactly like a
   real domain would, because as far as certbot and DO are concerned, it
   *is* one.

## Where this hostname shows up

Once you've built the `sslip.io` hostname, it's the same value in every one
of these places — there's no separate "sslip version" to keep track of:

| Where | Field | Value |
|---|---|---|
| `.env` | `SINK_HOSTNAME` | `157-245-120-166.sslip.io` |
| DO control panel → Log Forwarding | **Destination name** (label, optional) | `157-245-120-166.sslip.io` |
| DO control panel → Log Forwarding | **Endpoint** (required) | `157-245-120-166.sslip.io` |
| Let's Encrypt / certbot (run by `setup.sh`) | Certificate common name | `157-245-120-166.sslip.io` |
| rsyslog (configured by `setup.sh`) | TLS server cert presented on port 6514 | issued for `157-245-120-166.sslip.io` |

If the sink Droplet's IP ever changes (rebuild, resize, re-deploy to a new
Droplet — see RUNBOOK's "Re-deploying to a new sink Droplet"), the
`sslip.io` hostname changes with it, since the IP is embedded in the
hostname itself. Update `SINK_HOSTNAME` in `.env` and the DO **Endpoint**
field to the new `<new-dashed-IP>.sslip.io` string, and re-run `setup.sh` so
it requests a fresh Let's Encrypt cert for the new name.

---

See [../RUNBOOK.md](../RUNBOOK.md) Step 3 (`.env`) and Step 4 (Log
Forwarding) for where `SINK_HOSTNAME` is used, and
[tls-and-certificates.md](tls-and-certificates.md) for the full TLS design.
