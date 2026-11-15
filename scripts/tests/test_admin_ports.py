"""Regression checks for fail-closed, private Compose preflight output."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "check-admin-ports.py"
spec = importlib.util.spec_from_file_location("admin_ports", SCRIPT)
admin_ports = importlib.util.module_from_spec(spec)
spec.loader.exec_module(admin_ports)


class AdminPortsTest(unittest.TestCase):
    def check(self, model, code=0):
        output = io.StringIO()
        result = subprocess.CompletedProcess([], code, json.dumps(model), "private-secret")
        with patch.object(admin_ports.subprocess, "run", return_value=result) as run, \
                patch.object(admin_ports.sys, "argv", [str(SCRIPT), "docker-compose.db.yml"]), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            status = admin_ports.main()
        self.assertNotIn("private-secret", output.getvalue())
        self.assertIn("--profile", run.call_args.args[0])
        self.assertIn("docker-compose.db.yml", run.call_args.args[0])
        return status

    def model(self, host):
        return {"services": {name: {"ports": [{"host_ip": host, "published": "5433"}]}
                             for name in ("db", "pgadmin")}}

    def test_explicit_loopback_is_compatible(self):
        for host in ("127.0.0.1", "::1"):
            with self.subTest(host=host):
                self.assertEqual(self.check(self.model(host)), 0)

    def test_bare_wildcard_and_remote_bindings_fail_closed(self):
        for host in (None, "", "0.0.0.0", "::", "192.0.2.1"):
            with self.subTest(host=host):
                self.assertEqual(self.check(self.model(host)), 1)

    def test_one_unsafe_admin_port_rejects_even_with_safe_db(self):
        model = self.model("127.0.0.1")
        model["services"]["pgadmin"]["ports"].append({"published": "8082"})
        self.assertEqual(self.check(model), 1)

    def test_missing_services_ports_and_malformed_model_fail_closed(self):
        for model in ({}, {"services": {}}, {"services": None},
                      {"services": {"db": {"ports": []}}}, self.model([])):
            with self.subTest(model=model):
                self.assertEqual(self.check(model), 1)

    def test_render_failure_does_not_expose_diagnostics(self):
        self.assertEqual(self.check({"private-secret": "private-secret"}, 1), 1)

    @unittest.skipIf(os.name == "nt", "Deployment wrappers require Linux Bash")
    def test_deployment_wrappers_stop_before_docker_on_preflight_rejection(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            trace = temporary / "docker-called"
            for name, body in {"python3": "exit 1", "git": "exit 0",
                               "docker": f'touch "{trace}"; exit 0'}.items():
                executable = temporary / name
                executable.write_text("#!/bin/sh\n" + body + "\n")
                executable.chmod(0o755)
            for name in ("deploy-up.sh", "deploy-pull.sh"):
                result = subprocess.run(["bash", str(SCRIPT.parent / name)],
                                        env={**os.environ, "PATH": str(temporary) + ":" + os.environ["PATH"]},
                                        capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(trace.exists(), name)


if __name__ == "__main__":
    unittest.main()
