# Docs

Design notes and deep dives that don't belong in [RUNBOOK.md](../RUNBOOK.md)'s
step-by-step flow, but are worth having written down.

- **[architecture.md](architecture.md)** — why this pipeline exists, how it
  works end to end, and why the symlink trick works.
- **[tls-and-certificates.md](tls-and-certificates.md)** — the mutual-TLS
  design between DO and the sink, DO's certificate quirks, and the DNS-01
  alternative for private/VPC sinks.

For deployment steps, start at the main [README](../README.md) or
[RUNBOOK.md](../RUNBOOK.md).
