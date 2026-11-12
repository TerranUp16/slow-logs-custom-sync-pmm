#!/usr/bin/env python3
"""PMM helpers for setup.sh / destruct.sh / diagnose.sh (stdlib only — the sink
has no venv). Called through thin wrappers in common.sh; not meant to be run
by hand, though `python3 pmm_helper.py --help` lists the subcommands.

Why a separate file: these decisions (does a service with exactly this name
exist? whose node is this?) need real JSON parsing, and are worth unit tests
(tests/test_pmm_helper.py) — neither of which is pleasant inline in bash.

Secrets never go through argv: the PMM token is read from $PMM_TOKEN.

Subcommands (exit status matters; see each function):
  service-id NAME              < `pmm-admin --json list`
  slowlog-agent-id NAME        < `pmm-admin --json list`
  slowlog-agent-status NAME    < `pmm-admin --json list`
  stale-services NAME ADDR:PORT  < `pmm-admin --json list`
  local-status                 < `pmm-admin --json status`
  node-owner NAME LOCAL_AGENT_ID      (queries PMM_SERVER with PMM_TOKEN)
  service-owner NAME LOCAL_NODE_ID    (queries PMM_SERVER with PMM_TOKEN)
  mint-token SA_NAME                  (PMM_SERVER, default admin:admin)
"""
import base64
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

SLOWLOG = "AGENT_TYPE_QAN_MYSQL_SLOWLOG_AGENT"


# ---------------------------------------------------------------------------
# Parsing `pmm-admin --json list` / `pmm-admin --json status` (pure functions)
# ---------------------------------------------------------------------------

def service_ids(listing, name):
    """IDs of services whose name is EXACTLY `name` (never a substring match:
    `prod-primary` must not match `prod-primary-ro`)."""
    return [s.get("service_id") for s in listing.get("service") or [] if s.get("service_name") == name]


def slowlog_agents(listing, name):
    ids = set(service_ids(listing, name))
    return [a for a in listing.get("agent") or []
            if a.get("agent_type") == SLOWLOG and a.get("service_id") in ids]


def stale_services(listing, name, address_port):
    """Names of MySQL services on this node that point at the same local proxy
    address (e.g. "127.0.0.1:25060") under a DIFFERENT name — i.e. this sink's
    own service under its previous PMM_SERVICE_NAME, left behind by a rename.
    The local proxy port belongs to exactly one endpoint on a sink, so a
    service on it can only be that endpoint's."""
    return [s.get("service_name") for s in listing.get("service") or []
            if s.get("service_type") == "SERVICE_TYPE_MYSQL_SERVICE"
            and s.get("address_port") == address_port and s.get("service_name") != name]


def local_status(status):
    """(agent_id, node_id, node_name, server_host, connected) for the local
    pmm-agent, from `pmm-admin --json status`. Empty strings when unknown."""
    s = status.get("pmm_agent_status") or {}
    url = s.get("server_url") or ""
    host = urllib.parse.urlsplit(url).hostname or ""
    return (s.get("agent_id") or "", s.get("node_id") or "", s.get("node_name") or "", host,
            "true" if s.get("connected") else "false")


def service_owner(services_resp, name, local_node_id):
    """Where is a service named `name` registered on the PMM Server?
    services_resp: GET /v1/inventory/services -> {"mysql": [...], "postgresql": [...], ...}
    Returns ("absent"|"here"|"elsewhere", [details for "elsewhere"])."""
    matches = [s for ss in services_resp.values() if isinstance(ss, list)
               for s in ss if s.get("service_name") == name]
    if not matches:
        return "absent", []
    if local_node_id and all(s.get("node_id") == local_node_id for s in matches):
        return "here", []
    return "elsewhere", [{"service_id": s.get("service_id"), "node_id": s.get("node_id"),
                          "address": s.get("address"), "port": s.get("port")}
                         for s in matches if s.get("node_id") != local_node_id]


# ---------------------------------------------------------------------------
# Node ownership (PMM inventory API)
# ---------------------------------------------------------------------------

def node_owner(nodes_resp, agents_resp, name, local_agent_id):
    """Decide whether the PMM node called `name` belongs to this machine.

    nodes_resp:  GET /v1/inventory/nodes   -> {"generic": [...], "container": [...], ...}
    agents_resp: GET /v1/inventory/agents?agent_type=AGENT_TYPE_PMM_AGENT -> {"pmm_agent": [...]}

    A node "belongs to this machine" iff a pmm-agent running on it has this
    machine's pmm-agent ID. Returns (verdict, details):
      "absent" — no node with that name
      "ours"   — exists, and this machine's pmm-agent runs on it
      "other"  — exists and something else owns it (or nothing does: an orphan
                 left by a deleted Droplet is still not provably ours)
    """
    matches = [n for ns in nodes_resp.values() if isinstance(ns, list)
               for n in ns if n.get("node_name") == name]
    if not matches:
        return "absent", []
    agents = [a for ags in agents_resp.values() if isinstance(ags, list) for a in ags]
    details = []
    for n in matches:
        on_node = [a for a in agents if a.get("runs_on_node_id") == n.get("node_id")]
        if local_agent_id and any(a.get("agent_id") == local_agent_id for a in on_node):
            return "ours", []
        details.append({
            "node_id": n.get("node_id"), "address": n.get("address"),
            "pmm_agents": [{"agent_id": a.get("agent_id"), "connected": bool(a.get("connected"))} for a in on_node],
        })
    return "other", details


def _ssl_ctx():
    # setup.sh registers with --server-insecure-tls (PMM's default self-signed,
    # IP-addressed cert), so the API calls make the same trade-off.
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _api(method, path, auth_header, body=None):
    url = "https://" + os.environ["PMM_SERVER"] + path
    req = urllib.request.Request(url, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": auth_header, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, context=_ssl_ctx(), timeout=15) as r:
        return json.load(r)


def cmd_node_owner(name, local_agent_id):
    """Exit 0 = absent, 1 = ours, 2 = someone else's (details on stdout as
    JSON), 3 = couldn't ask the PMM API (message on stderr)."""
    auth = "Bearer " + os.environ.get("PMM_TOKEN", "")
    try:
        nodes = _api("GET", "/v1/inventory/nodes", auth)
        agents = _api("GET", "/v1/inventory/agents?agent_type=AGENT_TYPE_PMM_AGENT", auth)
    except urllib.error.HTTPError as e:
        print(f"PMM API returned HTTP {e.code} for the inventory lookup"
              + (" — PMM_TOKEN is invalid or lacks the Admin role" if e.code in (401, 403) else ""),
              file=sys.stderr)
        return 3
    except (urllib.error.URLError, OSError, ValueError) as e:
        print(f"could not query the PMM inventory API at {os.environ.get('PMM_SERVER')}: {e}", file=sys.stderr)
        return 3
    verdict, details = node_owner(nodes, agents, name, local_agent_id)
    if verdict == "other":
        print(json.dumps(details))
    return {"absent": 0, "ours": 1, "other": 2}[verdict]


def cmd_service_owner(name, local_node_id):
    """Exit 0 = no such service, 1 = registered on local_node_id, 2 = registered
    on some other node (details on stdout as JSON), 3 = API error."""
    auth = "Bearer " + os.environ.get("PMM_TOKEN", "")
    try:
        services = _api("GET", "/v1/inventory/services", auth)
    except urllib.error.HTTPError as e:
        print(f"PMM API returned HTTP {e.code} for the service lookup"
              + (" — PMM_TOKEN is invalid or lacks the Admin role" if e.code in (401, 403) else ""),
              file=sys.stderr)
        return 3
    except (urllib.error.URLError, OSError, ValueError) as e:
        print(f"could not query the PMM inventory API at {os.environ.get('PMM_SERVER')}: {e}", file=sys.stderr)
        return 3
    verdict, details = service_owner(services, name, local_node_id)
    if verdict == "elsewhere":
        print(json.dumps(details))
    return {"absent": 0, "here": 1, "elsewhere": 2}[verdict]


def cmd_mint_token(sa_name):
    """Create (or reuse) an Admin service account named sa_name and mint a new
    token for it; print only the token. Uses the PMM default admin:admin unless
    PMM_ADMIN_PASSWORD is set. Exit 1 on any failure (reason on stderr)."""
    pw = os.environ.get("PMM_ADMIN_PASSWORD", "admin")
    auth = "Basic " + base64.b64encode(("admin:" + pw).encode()).decode()
    base = "/graph/api/serviceaccounts"
    try:
        found = _api("GET", base + "/search?query=" + urllib.parse.quote(sa_name), auth).get("serviceAccounts") or []
        sa = next((s for s in found if s.get("name") == sa_name), None)
        if sa is None:
            sa = _api("POST", base, auth, {"name": sa_name, "role": "Admin"})
        tok = _api("POST", f"{base}/{sa['id']}/tokens", auth,
                   {"name": f"{sa_name}-{os.urandom(3).hex()}"})
        key = tok["key"]
    except urllib.error.HTTPError as e:
        print(f"PMM API returned HTTP {e.code}"
              + (" (admin credentials rejected)" if e.code in (401, 403) else ""), file=sys.stderr)
        return 1
    except (urllib.error.URLError, OSError, ValueError, KeyError, TypeError) as e:
        print(f"unexpected response minting a token: {type(e).__name__}: {e}", file=sys.stderr)
        return 1
    sys.stdout.write(key)
    return 0


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__)
        return 0
    cmd, args = argv[1], argv[2:]
    if cmd in ("service-id", "slowlog-agent-id", "slowlog-agent-status", "local-status", "stale-services"):
        try:
            data = json.load(sys.stdin)
        except ValueError:
            data = {}
        if cmd == "service-id":
            ids = service_ids(data, args[0])
            print("\n".join(i for i in ids if i))
            return 0 if ids else 1
        if cmd == "slowlog-agent-id":
            ags = slowlog_agents(data, args[0])
            print("\n".join(a["agent_id"] for a in ags))
            return 0 if ags else 1
        if cmd == "stale-services":
            names = stale_services(data, args[0], args[1])
            print("\n".join(n for n in names if n))
            return 0
        if cmd == "slowlog-agent-status":
            ags = slowlog_agents(data, args[0])
            print("\n".join(a.get("status") or "UNKNOWN" for a in ags))
            return 0 if ags else 1
        print(" ".join(x or "-" for x in local_status(data)))
        return 0
    if cmd == "node-owner":
        return cmd_node_owner(args[0], args[1] if len(args) > 1 else "")
    if cmd == "service-owner":
        return cmd_service_owner(args[0], args[1] if len(args) > 1 else "")
    if cmd == "mint-token":
        return cmd_mint_token(args[0])
    print(f"unknown subcommand: {cmd}", file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
