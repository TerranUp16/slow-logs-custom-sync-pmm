# TLS & Certificate Design

## Two TLS directions, two different trust anchors

DO's log forwarder and the sink's rsyslog listener authenticate **each
other** (mutual TLS), and the two directions deliberately use different
trust anchors:

| Direction | Who verifies | Against what | Where it's configured |
|---|---|---|---|
| DO verifies the **sink's server cert** | DO forwarder | DO's system CA bundle (publicly-trusted roots) | DO panel **CA Certificate** field = blank |
| rsyslog verifies **DO's client cert** | Sink (rsyslog) | Our private CA (`certs/ca.pem`, from `gen-certs.sh`) | rsyslog `CAFile` = `/etc/rsyslog.d/tls/ca.pem` |

The sink presents a **publicly-trusted Let's Encrypt** certificate issued for
`SINK_HOSTNAME` — not a self-signed or private-CA cert. Because it's publicly
trusted, DO's own **CA Certificate** field in its log-forwarding config is
left blank, and DO verifies the LE cert against its built-in system trust
store.

## Things we verified so you don't have to re-derive them

- **A private-CA or self-signed server cert is always rejected by DO**, with
  `certificate_unknown` — tested with both DNS and IP SANs, `keyCertSign`
  set, full chain vs. leaf-only, fresh clusters, and both the `ossl` and
  `gtls` rsyslog drivers. DO requires the sink's cert to chain to a public
  root; there's no way around this. Always use a hostname + a real Let's
  Encrypt cert.
- **DO does not clear the CA Certificate field once set.** Blanking it in
  the UI doesn't take — the old value persists server-side. To truly get a
  blank CA, create a fresh log-forwarding destination (delete + recreate, or
  use a new cluster). If a "blank CA" configuration isn't working, suspect a
  stale cached value first.
- After saving a log-forwarding config change, DO takes roughly 1–2 minutes
  to redeploy the forwarder before it reconnects — brief silence afterward
  is expected, not a failure.
- rsyslog's `ossl` (OpenSSL) driver is required, not `gtls` — `gtls` fails
  DO's handshake with `Decryption has failed`. `setup.sh` installs
  `rsyslog-openssl` and configures `defaultNetstreamDriver="ossl"`
  accordingly.
- No public domain available? `<IP-dashed>.sslip.io` (e.g.
  `142-93-154-42.sslip.io`) is a valid `SINK_HOSTNAME` for testing — it's
  wildcard DNS that resolves to the embedded IP, and certbot can issue a real
  cert for it via HTTP-01.

## Alternative certificate issuance: DNS-01

`setup.sh` defaults to certbot's **HTTP-01** challenge (`--standalone`),
which needs the sink to be **publicly reachable on port 80** with
`SINK_HOSTNAME` resolving to its public IP. Use **DNS-01** instead when:

- The sink is on a private/VPC network with no public IP or inbound port 80.
- Port 80 can't be opened (firewall/policy).
- You want a wildcard cert, or need to issue the cert before the Droplet
  exists.

DNS-01 proves domain control via a `_acme-challenge` TXT record and needs
**no inbound connectivity to the sink at all**. The sink still ends up
presenting the same kind of publicly-trusted cert; DO still validates it the
same way (CA field blank).

**Option 1 — DNS provider plugin (automated, renews unattended):**
```bash
apt-get install -y certbot python3-certbot-dns-digitalocean
printf 'dns_digitalocean_token = %s\n' "$DO_DNS_TOKEN" > /root/.secrets/do.ini
chmod 600 /root/.secrets/do.ini
certbot certonly \
  --dns-digitalocean --dns-digitalocean-credentials /root/.secrets/do.ini \
  --non-interactive --agree-tos -m "$LETSENCRYPT_EMAIL" -d "$SINK_HOSTNAME"
```
Swap `digitalocean` for `cloudflare`, `route53`, etc. and the matching
credentials file. Renewal is automatic via the certbot timer — no port 80
needed, ever.

**Option 2 — Manual DNS-01 (one-off, no plugin for your provider):**
```bash
certbot certonly --manual --preferred-challenges dns \
  --non-interactive --agree-tos -m "$LETSENCRYPT_EMAIL" -d "$SINK_HOSTNAME"
```
Does **not** auto-renew — you'll repeat the TXT-record step roughly every 60
days. Prefer a provider plugin for anything long-lived.

**Wiring it into `setup.sh`:** obtain the cert with either option *before*
running `setup.sh`, so it already exists at
`/etc/letsencrypt/live/$SINK_HOSTNAME/`. `setup.sh` detects an existing cert
and skips fresh issuance, then copies it into place and installs the same
renewal deploy hook — the rest of the pipeline is identical regardless of
which challenge type issued the cert.

---

See [../RUNBOOK.md](../RUNBOOK.md) Step 4 for where these settings get
applied, and [architecture.md](architecture.md) for the rest of the pipeline.
