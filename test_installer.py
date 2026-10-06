import importlib.util
import io
import json
import subprocess
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import patch

import types

script = Path(__file__).with_name("remnawave-node-install.sh").read_text()
payload = script.split("<<'REMNA_ONECLICK_PYTHON'\n", 1)[1].rsplit("\nREMNA_ONECLICK_PYTHON\n", 1)[0]
m = types.ModuleType("installer")
exec(compile(payload, "<embedded-installer>", "exec"), m.__dict__)


class FakeAPI:
    def __init__(self, fail_host=False):
        self.calls = []
        self.inbounds = ["existing-inbound"]
        self.fail_host = fail_host

    def call(self, path, body=None, method=None):
        method = method or ("POST" if body is not None else "GET")
        self.calls.append((method, path, body))
        if method == "DELETE":
            return {}
        if path == "/config-profiles":
            return {"uuid": "profile-id", "inbounds": [{"uuid": "new-inbound", "tag": "ONECLICK_SS2022"}]}
        if path == "/nodes":
            return {"uuid": "node-id"}
        if path == "/hosts":
            if self.fail_host:
                raise m.InstallError("host creation denied")
            return {"uuid": "host-id"}
        if path == "/internal-squads/squad-id":
            return {"uuid": "squad-id", "inbounds": [{"uuid": x} for x in self.inbounds]}
        if path == "/internal-squads" and method == "PATCH":
            self.inbounds = body["inbounds"]
            return {}
        raise AssertionError(path)


class Tests(unittest.TestCase):
    def test_generated_script_self_test(self):
        result = subprocess.run(["bash", str(Path(__file__).with_name("remnawave-node-install.sh")), "--self-test"], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_api_resources_and_concurrent_squad_rollback(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(m, "BASE", Path(directory)), patch.object(m, "say"), patch.object(m, "run"):
            c = {"owner_id": "abcdefgh-1234", "name": "Node-Test", "management_address": "[2001:db8::10]",
                 "api_port": 2222, "country": "JP", "public_address": "entry.example.com", "public_port": 10081,
                 "squad_uuid": "squad-id"}
            Path(directory, "ss2022-profile.json").write_text(json.dumps({"config": "dummy"}))
            tx = m.Transaction()
            api = FakeAPI()
            m.create_panel(tx, c, api)
            self.assertEqual(api.inbounds, ["existing-inbound", "new-inbound"])
            node_request = next(body for method, path, body in api.calls if path == "/nodes")
            self.assertEqual(node_request["address"], "[2001:db8::10]")
            self.assertIsNone(node_request["proxyUrl"])
            host_request = next(body for method, path, body in api.calls if path == "/hosts")
            self.assertTrue(host_request["mapper"]["mihomo"][0]["value"])
            self.assertEqual(host_request["nodes"], ["node-id"])
            api.inbounds.append("concurrently-added-inbound")
            tx.rollback(announce=False)
            self.assertEqual(api.inbounds, ["existing-inbound", "concurrently-added-inbound"])
            self.assertEqual([path for method, path, _ in api.calls if method == "DELETE"],
                             ["/hosts/host-id", "/nodes/node-id", "/config-profiles/profile-id"])

    def test_failed_host_creation_removes_only_created_resources(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(m, "BASE", Path(directory)), patch.object(m, "say"), patch.object(m, "run"):
            c = {"owner_id": "abcdefgh-1234", "name": "Node-Test", "management_address": "192.0.2.20",
                 "api_port": 2222, "country": "XX", "public_address": "entry.example.com", "public_port": 2443}
            Path(directory, "ss2022-profile.json").write_text("{}")
            tx = m.Transaction()
            api = FakeAPI(fail_host=True)
            with self.assertRaises(m.InstallError):
                m.create_panel(tx, c, api)
            tx.rollback(announce=False)
            self.assertEqual([path for method, path, _ in api.calls if method == "DELETE"],
                             ["/nodes/node-id", "/config-profiles/profile-id"])
            self.assertEqual(api.inbounds, ["existing-inbound"])
            self.assertTrue((tx.backup / "panel-created.json").exists())

    def test_repeat_api_deployment_never_overwrites_panel(self):
        api = FakeAPI()
        with patch.object(m, "say"):
            m.create_panel(None, {"node_uuid": "node-id"}, api)
        self.assertEqual(api.calls, [])

    def test_api_errors_do_not_echo_token_or_response(self):
        api = m.API("https://panel.example.com", "PRIVATE_API_TOKEN")
        error = urllib.error.HTTPError("https://panel.example.com/api/keygen", 403,
                  "PRIVATE_SERVER_KEY", {}, io.BytesIO(b'{"secretKey":"PRIVATE_SERVER_KEY"}'))
        with patch.object(api.opener, "open", side_effect=error):
            with self.assertRaises(m.InstallError) as caught:
                api.call("/keygen")
        self.assertNotIn("PRIVATE_", str(caught.exception))
        self.assertIn("403", str(caught.exception))

    def test_port_conflicts_and_rerun_port_change_blocked(self):
        c = {"api_port": 2222, "dns_port": 6053, "ss_port": 2443, "smartdns": True, "mode": "1"}
        with patch.object(m, "command", return_value="tcp LISTEN 0 128 [::]:2222 [::]:*"):
            with self.assertRaises(m.InstallError):
                m.port_precheck(c, {})
        with patch.object(m, "command") as command:
            with self.assertRaises(m.InstallError):
                m.port_precheck(c, {**c, "ss_port": 10081})
            command.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
