"""Unit tests for pmm_helper.py — the PMM-identity decisions setup.sh relies on.

Fixtures mirror the shapes returned by a live PMM 3.10 server
(`pmm-admin --json list`, `pmm-admin --json status`, /v1/inventory/*).
No network: only the pure functions and the CLI's stdin parsing are tested.
"""
import io
import json
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import pmm_helper as ph  # noqa: E402

LISTING = {
    "service": [
        {"service_type": "SERVICE_TYPE_MYSQL_SERVICE", "service_id": "svc-1", "service_name": "prod-primary",
         "address_port": "127.0.0.1:25060"},
        {"service_type": "SERVICE_TYPE_MYSQL_SERVICE", "service_id": "svc-2", "service_name": "prod-primary-ro",
         "address_port": "127.0.0.1:25061"},
    ],
    "agent": [
        {"agent_type": "AGENT_TYPE_PMM_AGENT", "agent_id": "pa-1", "service_id": "", "status": "CONNECTED"},
        {"agent_type": "AGENT_TYPE_MYSQLD_EXPORTER", "agent_id": "ex-1", "service_id": "svc-1", "status": "RUNNING"},
        {"agent_type": "AGENT_TYPE_QAN_MYSQL_SLOWLOG_AGENT", "agent_id": "sl-1", "service_id": "svc-1", "status": "RUNNING"},
        {"agent_type": "AGENT_TYPE_QAN_MYSQL_SLOWLOG_AGENT", "agent_id": "sl-2", "service_id": "svc-2", "status": "WAITING"},
    ],
}

STATUS = {"pmm_agent_status": {
    "agent_id": "pa-1", "node_id": "node-a", "node_name": "sink-a",
    "server_url": "https://10.0.0.15:443/", "connected": True}}

NODES = {
    "generic": [
        {"node_id": "node-a", "node_name": "sink-a", "address": "203.0.113.10"},
        {"node_id": "node-b", "node_name": "sink-b", "address": "203.0.113.11"},
        {"node_id": "node-orphan", "node_name": "sink-old", "address": "203.0.113.12"},
    ],
    "container": [{"node_id": "pmm-server", "node_name": "pmm-server", "address": "127.0.0.1"}],
}
AGENTS = {"pmm_agent": [
    {"agent_id": "pa-1", "runs_on_node_id": "node-a", "connected": True},
    {"agent_id": "pa-2", "runs_on_node_id": "node-b", "connected": True},
    {"agent_id": "pmm-server", "runs_on_node_id": "pmm-server", "connected": True},
]}
SERVICES = {"mysql": [
    {"service_id": "svc-1", "service_name": "prod-primary", "node_id": "node-a", "address": "127.0.0.1", "port": 25060},
    {"service_id": "svc-9", "service_name": "prod-replica", "node_id": "node-b", "address": "127.0.0.1", "port": 25060},
]}


class ListingTests(unittest.TestCase):
    def test_service_match_is_exact_not_substring(self):
        self.assertEqual(ph.service_ids(LISTING, "prod-primary"), ["svc-1"])
        self.assertEqual(ph.service_ids(LISTING, "prod"), [])
        self.assertEqual(ph.service_ids(LISTING, "prod-primary-ro"), ["svc-2"])

    def test_slowlog_agent_for_exact_service_only(self):
        self.assertEqual([a["agent_id"] for a in ph.slowlog_agents(LISTING, "prod-primary")], ["sl-1"])
        self.assertEqual(ph.slowlog_agents(LISTING, "missing"), [])

    def test_empty_or_partial_listing(self):
        self.assertEqual(ph.service_ids({}, "x"), [])
        self.assertEqual(ph.slowlog_agents({"service": None, "agent": None}, "x"), [])

    def test_stale_services_after_rename(self):
        self.assertEqual(ph.stale_services(LISTING, "prod-primary-renamed", "127.0.0.1:25060"), ["prod-primary"])
        self.assertEqual(ph.stale_services(LISTING, "prod-primary", "127.0.0.1:25060"), [])
        # a different endpoint's port is never "stale" for this one
        self.assertEqual(ph.stale_services(LISTING, "prod-primary", "127.0.0.1:25061"), ["prod-primary-ro"])
        self.assertEqual(ph.stale_services(LISTING, "x", "127.0.0.1:9999"), [])

    def test_local_status(self):
        self.assertEqual(ph.local_status(STATUS), ("pa-1", "node-a", "sink-a", "10.0.0.15", "true"))
        self.assertEqual(ph.local_status({}), ("", "", "", "", "false"))


class NodeOwnerTests(unittest.TestCase):
    def test_absent(self):
        self.assertEqual(ph.node_owner(NODES, AGENTS, "sink-new", "pa-1"), ("absent", []))

    def test_ours(self):
        self.assertEqual(ph.node_owner(NODES, AGENTS, "sink-a", "pa-1"), ("ours", []))

    def test_other_machine_with_same_name(self):
        verdict, details = ph.node_owner(NODES, AGENTS, "sink-b", "pa-1")
        self.assertEqual(verdict, "other")
        self.assertEqual(details[0]["node_id"], "node-b")
        self.assertEqual(details[0]["pmm_agents"], [{"agent_id": "pa-2", "connected": True}])

    def test_fresh_machine_never_owns_an_existing_node(self):
        # No local pmm-agent yet (fresh Droplet): an existing node by that name
        # can't be proven ours, so it must be treated as someone else's.
        self.assertEqual(ph.node_owner(NODES, AGENTS, "sink-a", "")[0], "other")

    def test_orphan_node_is_not_ours(self):
        verdict, details = ph.node_owner(NODES, AGENTS, "sink-old", "pa-1")
        self.assertEqual(verdict, "other")
        self.assertEqual(details[0]["pmm_agents"], [])


class ServiceOwnerTests(unittest.TestCase):
    def test_absent(self):
        self.assertEqual(ph.service_owner(SERVICES, "new-svc", "node-a"), ("absent", []))

    def test_on_this_node(self):
        self.assertEqual(ph.service_owner(SERVICES, "prod-primary", "node-a"), ("here", []))

    def test_on_another_node(self):
        verdict, details = ph.service_owner(SERVICES, "prod-replica", "node-a")
        self.assertEqual(verdict, "elsewhere")
        self.assertEqual(details[0]["node_id"], "node-b")

    def test_unknown_local_node_means_elsewhere(self):
        self.assertEqual(ph.service_owner(SERVICES, "prod-primary", "")[0], "elsewhere")


class CliTests(unittest.TestCase):
    def run_cli(self, argv, stdin_obj):
        out = io.StringIO()
        with mock.patch.object(sys, "stdin", io.StringIO(json.dumps(stdin_obj))), \
             mock.patch.object(sys, "stdout", out):
            rc = ph.main(["pmm_helper.py"] + argv)
        return rc, out.getvalue()

    def test_service_id_exit_codes(self):
        self.assertEqual(self.run_cli(["service-id", "prod-primary"], LISTING), (0, "svc-1\n"))
        self.assertEqual(self.run_cli(["service-id", "prod"], LISTING)[0], 1)

    def test_slowlog_agent_cli(self):
        self.assertEqual(self.run_cli(["slowlog-agent-id", "prod-primary"], LISTING), (0, "sl-1\n"))
        self.assertEqual(self.run_cli(["slowlog-agent-status", "prod-primary-ro"], LISTING), (0, "WAITING\n"))

    def test_local_status_cli_dashes_for_unknown(self):
        self.assertEqual(self.run_cli(["local-status"], {}), (0, "- - - - false\n"))
        self.assertEqual(self.run_cli(["local-status"], STATUS), (0, "pa-1 node-a sink-a 10.0.0.15 true\n"))

    def test_garbage_stdin_is_not_a_crash(self):
        out = io.StringIO()
        with mock.patch.object(sys, "stdin", io.StringIO("not json")), mock.patch.object(sys, "stdout", out):
            self.assertEqual(ph.main(["pmm_helper.py", "service-id", "x"]), 1)


if __name__ == "__main__":
    unittest.main()
